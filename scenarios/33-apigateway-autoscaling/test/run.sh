#!/usr/bin/env bash
# Scenario 33: API gateway + autoscaling through a real Workflow app boundary.
#
# Demonstration-fidelity: this starts workflow-server from the scenario config,
# installs workflow-plugin-aws as an external plugin, and drives API Gateway and
# Application Auto Scaling resources through HTTP. The AWS plugin runs in mock
# mode as the disclosed cloud dependency seam; Workflow and plugin code paths
# are the real artifacts under test.
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18133}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-2}"
CURL_MAX_TIME="${CURL_MAX_TIME:-10}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG="$SCENARIO_DIR/config/app.yaml"

PASS=0
FAIL=0
SERVER_PID=""
DATA_DIR=""
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  [ -n "$DATA_DIR" ] && rm -rf "$DATA_DIR"
}
trap cleanup EXIT

find_repo() {
  local env_value="$1"
  shift
  if [ -n "$env_value" ]; then
    [ -d "$env_value" ] && printf '%s\n' "$env_value" && return 0
    return 1
  fi
  local candidate
  for candidate in "$@"; do
    if [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_server() {
  if [ -n "${WORKFLOW_SERVER:-}" ]; then
    [ -x "$WORKFLOW_SERVER" ] && printf '%s\n' "$WORKFLOW_SERVER" && return 0
    return 1
  fi

  local workflow_repo
  workflow_repo="$(find_repo "${WORKFLOW_REPO:-${WORKFLOW_DIR:-}}" "$REPO_ROOT/../workflow" "$REPO_ROOT/../../../workflow")" || return 1
  mkdir -p "$workflow_repo/bin" || return 1
  (cd "$workflow_repo" && GOWORK=off go build -o bin/workflow-server ./cmd/server) || return 1
  printf '%s\n' "$workflow_repo/bin/workflow-server"
}

resolve_aws_plugin_repo() {
  find_repo "${WORKFLOW_PLUGIN_AWS_REPO:-${AWS_PLUGIN_REPO:-}}" \
    "$REPO_ROOT/../workflow-plugin-aws" \
    "$REPO_ROOT/../../../workflow-plugin-aws"
}

install_aws_plugin() {
  local data_dir="$1"
  local plugin_repo="$2"
  local plugin_dir="$data_dir/plugins/workflow-plugin-aws"
  mkdir -p "$plugin_dir" || return 1
  (cd "$plugin_repo" && GOWORK=off go build -o "$plugin_dir/workflow-plugin-aws" ./cmd/workflow-plugin-aws) || return 1
  cp "$plugin_repo/plugin.json" "$plugin_dir/plugin.json" || return 1
  cp "$plugin_repo/plugin.contracts.json" "$plugin_dir/plugin.contracts.json" || return 1
}

wait_for_server() {
  local url="$1"
  local i
  local health
  for ((i = 1; i <= 80; i++)); do
    if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      return 1
    fi
    health="$(curl --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -fs "$url/healthz" 2>/dev/null)" \
      && printf '%s' "$health" | jq -e '.status == "ok" and .scenario == "33-apigateway-autoscaling"' >/dev/null 2>&1 \
      && return 0
    sleep 0.25
  done
  return 1
}

post_json() {
  local path="$1"
  local payload="$2"
  curl --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -fsS -X POST -H 'Content-Type: application/json' -d "$payload" "$BASE_URL$path"
}

plan_apply_status_destroy() {
  local label="$1"
  local base_path="$2"
  local resource_name="$3"
  local resource_type="$4"
  local specs="$5"
  local plan_expr="$6"
  local apply_expr="$7"

  local refs payload plan desired_hash applied status destroyed status_after
  refs="$(jq -n --arg name "$resource_name" --arg type "$resource_type" '[{name: $name, type: $type}]')"
  payload="$(jq -n --argjson specs "$specs" '{specs: $specs}')"

  if plan="$(post_json "$base_path/plan" "$payload")"; then
    pass "$label planned caller-supplied spec through Workflow API"
    if printf '%s' "$plan" | jq -e --arg name "$resource_name" --arg type "$resource_type" "$plan_expr" >/dev/null 2>&1; then
      pass "$label plan proposed expected resource"
    else
      fail "$label plan response mismatch: $plan"
    fi
  else
    fail "$label plan API failed"
  fi

  desired_hash=""
  if [ -n "${plan:-}" ]; then
    desired_hash="$(printf '%s' "$plan" | jq -r '.desired_hash // empty')"
  fi
  if [ -n "$desired_hash" ]; then
    payload="$(jq -n --argjson specs "$specs" --arg desired_hash "$desired_hash" '{specs: $specs, desired_hash: $desired_hash}')"
    if applied="$(post_json "$base_path/apply" "$payload")"; then
      pass "$label applied spec with returned desired_hash"
      if printf '%s' "$applied" | jq -e --arg name "$resource_name" --arg type "$resource_type" "$apply_expr" >/dev/null 2>&1; then
        pass "$label apply response showed running mock resource"
      else
        fail "$label apply response mismatch: $applied"
      fi
    else
      fail "$label apply API failed"
    fi
  else
    fail "$label apply skipped because plan did not return desired_hash"
  fi

  payload="$(jq -n --argjson refs "$refs" '{refs: $refs}')"
  if status="$(post_json "$base_path/status" "$payload")"; then
    pass "$label fetched status with caller-supplied refs"
    if printf '%s' "$status" | jq -e --arg name "$resource_name" --arg type "$resource_type" '.provider == "aws-provider" and .count == 1 and (.resources[] | select(.name == $name and .type == $type and .status == "running"))' >/dev/null 2>&1; then
      pass "$label status response showed running resource"
    else
      fail "$label status response mismatch: $status"
    fi
  else
    fail "$label status API failed"
  fi

  if destroyed="$(post_json "$base_path/destroy" "$payload")"; then
    pass "$label destroyed resource with caller-supplied refs"
    if printf '%s' "$destroyed" | jq -e --arg name "$resource_name" '.provider == "aws-provider" and (.destroyed | index($name)) and (.destroy_errors | length == 0)' >/dev/null 2>&1; then
      pass "$label destroy response confirmed teardown"
    else
      fail "$label destroy response mismatch: $destroyed"
    fi
  else
    fail "$label destroy API failed"
  fi

  if status_after="$(post_json "$base_path/status" "$payload")"; then
    pass "$label fetched status after destroy"
    if printf '%s' "$status_after" | jq -e --arg name "$resource_name" --arg type "$resource_type" '.provider == "aws-provider" and .count == 1 and (.resources[] | select(.name == $name and .type == $type and .status == "unknown"))' >/dev/null 2>&1; then
      pass "$label status response showed resource absent after destroy"
    else
      fail "$label post-destroy status mismatch: $status_after"
    fi
  else
    fail "$label post-destroy status API failed"
  fi
}

echo ""
echo "=== Scenario 33: API Gateway Autoscaling Workflow App ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
for cmd in curl jq go; do
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "required command $cmd is available"
  else
    fail "required command $cmd is missing"
  fi
done
if [ "$FAIL" -ne 0 ]; then
  finish
  exit 1
fi
if sed '/^[[:space:]]*#/d' "$SCRIPT_DIR/run.sh" | grep -Eq '(^|[;&|[:space:]])go[[:space:]]+test'; then
  fail "scenario test should not delegate proof to Go package tests"
else
  pass "scenario test exercises the Workflow app boundary"
fi
for item in "type: iac.provider" "plugin: workflow-plugin-aws" "mode: mock" "type: step.request_parse" "type: step.iac_provider_plan" "type: step.iac_provider_apply" "type: step.iac_provider_list" "type: step.iac_provider_destroy" "specs_from: steps.parse-request.body.specs" "refs_from: steps.parse-request.body.refs"; do
  if grep -Fq -- "$item" "$CONFIG"; then
    pass "Workflow config wires $item"
  else
    fail "Workflow config missing $item"
  fi
done
if grep -Fq "credentials: env" "$CONFIG" || grep -Fq "AWS_ACCESS_KEY_ID" "$CONFIG"; then
  fail "Workflow config should not require live AWS credentials"
else
  pass "Workflow config uses AWS plugin mock mode without live credentials"
fi

SERVER_BIN="$(resolve_server)"
if [ "$?" -eq 0 ]; then
  pass "workflow server binary is available"
else
  fail "workflow server unavailable; set WORKFLOW_SERVER or WORKFLOW_REPO"
  finish
  exit 1
fi

AWS_PLUGIN_REPO_PATH="$(resolve_aws_plugin_repo)"
if [ "$?" -eq 0 ]; then
  pass "workflow-plugin-aws source is available"
else
  fail "workflow-plugin-aws source unavailable; set WORKFLOW_PLUGIN_AWS_REPO"
  finish
  exit 1
fi

if ! DATA_DIR="$(mktemp -d)"; then
  fail "could not create temporary data directory"
  finish
  exit 1
fi
if install_aws_plugin "$DATA_DIR" "$AWS_PLUGIN_REPO_PATH"; then
  pass "installed workflow-plugin-aws as external plugin"
else
  fail "could not build/install workflow-plugin-aws"
  finish
  exit 1
fi

SERVER_LOG="$SCRIPT_DIR/artifacts/last-server.log"
if ! mkdir -p "$(dirname "$SERVER_LOG")"; then
  fail "could not create server log directory"
  finish
  exit 1
fi
"$SERVER_BIN" -config "$CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
sleep 0.1
if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
  fail "workflow server process exited immediately; see $SERVER_LOG"
  finish
  exit 1
fi

if wait_for_server "$BASE_URL"; then
  pass "workflow server started and served /healthz"
else
  fail "workflow server did not become ready; see $SERVER_LOG"
  finish
  exit 1
fi

GATEWAY_NAME="${GATEWAY_NAME:-customer-api}"
SCALING_NAME="${SCALING_NAME:-customer-service-scaling}"
GATEWAY_SPECS="$(jq -n --arg name "$GATEWAY_NAME" '[
  {
    name: $name,
    type: "infra.api_gateway",
    config: {
      protocol: "HTTP",
      description: "customer-facing Workflow API",
      routes: [
        {path: "/api/v1/users", method: "ANY", target: "http://users-service:8080"},
        {path: "/api/v1/orders", method: "ANY", target: "http://orders-service:8080"}
      ],
      cors: {allow_origins: ["*"], allow_methods: ["GET", "POST", "PUT", "DELETE"]}
    }
  }
]')"
SCALING_SPECS="$(jq -n --arg name "$SCALING_NAME" '[
  {
    name: $name,
    type: "infra.autoscaling_group",
    config: {
      service_namespace: "ecs",
      resource_id: "service/production/customer-api",
      scalable_dimension: "ecs:service:DesiredCount",
      min_capacity: 2,
      max_capacity: 20,
      policies: [
        {
          policy_name: "cpu-target",
          policy_type: "TargetTrackingScaling",
          target_value: 70,
          predefined_metric_type: "ECSServiceAverageCPUUtilization"
        }
      ]
    }
  }
]')"

plan_apply_status_destroy \
  "api gateway" \
  "/api/v1/gateway" \
  "$GATEWAY_NAME" \
  "infra.api_gateway" \
  "$GATEWAY_SPECS" \
  '.provider == "aws-provider" and (.desired_hash | type == "string" and length > 0) and (.plan.actions | length == 1) and (.plan.actions[] | select(.action == "create" and .resource.name == $name and .resource.type == $type and .resource.config.protocol == "HTTP"))' \
  '.provider == "aws-provider" and .action_count == 1 and (.apply_result.resources[] | select(.name == $name and .type == $type and .status == "running" and .outputs.protocol == "HTTP"))'

plan_apply_status_destroy \
  "autoscaling" \
  "/api/v1/scaling" \
  "$SCALING_NAME" \
  "infra.autoscaling_group" \
  "$SCALING_SPECS" \
  '.provider == "aws-provider" and (.desired_hash | type == "string" and length > 0) and (.plan.actions | length == 1) and (.plan.actions[] | select(.action == "create" and .resource.name == $name and .resource.type == $type and .resource.config.min_capacity == 2 and .resource.config.max_capacity == 20))' \
  '.provider == "aws-provider" and .action_count == 1 and (.apply_result.resources[] | select(.name == $name and .type == $type and .status == "running" and .outputs.min_capacity == 2 and .outputs.max_capacity == 20))'

if finish; then
  echo ""
  echo "RESULT: ALL TESTS PASSED ($PASS/$PASS)"
  exit 0
else
  echo ""
  echo "RESULT: SOME TESTS FAILED ($PASS passed, $FAIL failed)"
  exit 1
fi
