#!/usr/bin/env bash
# Scenario 31: Platform networking through a real Workflow app boundary.
#
# Demonstration-fidelity: this starts workflow-server from the scenario config,
# installs workflow-plugin-aws as an external plugin, and drives network
# plan/apply/status/destroy through HTTP. The AWS plugin runs in explicit mock
# mode as the external cloud dependency seam; Workflow and the plugin code paths
# are the real artifacts under test.
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18131}"

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
    health="$(curl -fs "$url/healthz" 2>/dev/null)" \
      && printf '%s' "$health" | jq -e '.status == "ok" and .scenario == "31-platform-networking"' >/dev/null 2>&1 \
      && return 0
    sleep 0.25
  done
  return 1
}

post_json() {
  local path="$1"
  local payload="$2"
  curl -fsS -X POST -H 'Content-Type: application/json' -d "$payload" "$BASE_URL$path"
}

echo ""
echo "=== Scenario 31: Platform Networking Workflow App ==="
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
for item in "type: iac.provider" "plugin: workflow-plugin-aws" "mode: mock" "type: step.request_parse" "type: step.iac_provider_plan" "specs_from: steps.parse-request.body.specs" "type: step.iac_provider_apply" "desired_hash_from: steps.parse-request.body.desired_hash" "type: step.iac_provider_list" "type: step.iac_provider_destroy" "refs_from: steps.parse-request.body.refs"; do
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

VPC_NAME="${NETWORK_VPC_NAME:-prod-vpc}"
WEB_FIREWALL_NAME="${NETWORK_WEB_FIREWALL_NAME:-web-firewall}"
DB_FIREWALL_NAME="${NETWORK_DB_FIREWALL_NAME:-db-firewall}"
NETWORK_SPECS="$(jq -n \
  --arg vpc "$VPC_NAME" \
  --arg web "$WEB_FIREWALL_NAME" \
  --arg db "$DB_FIREWALL_NAME" \
  '[
    {
      name: $vpc,
      type: "infra.vpc",
      config: {
        cidr: "10.20.0.0/16",
        subnets: [
          {name: "public-a", cidr: "10.20.1.0/24", az: "us-east-1a", public: true},
          {name: "private-a", cidr: "10.20.10.0/24", az: "us-east-1a", public: false}
        ],
        nat_gateway: true
      }
    },
    {
      name: $web,
      type: "infra.firewall",
      config: {
        vpc_id: $vpc,
        ingress_rules: [
          {protocol: "tcp", from_port: 443, to_port: 443, cidr: "0.0.0.0/0"}
        ]
      }
    },
    {
      name: $db,
      type: "infra.firewall",
      config: {
        vpc_id: $vpc,
        ingress_rules: [
          {protocol: "tcp", from_port: 5432, to_port: 5432, cidr: "10.20.0.0/16"}
        ]
      }
    }
  ]')"
NETWORK_REFS="$(jq -n \
  --arg vpc "$VPC_NAME" \
  --arg web "$WEB_FIREWALL_NAME" \
  --arg db "$DB_FIREWALL_NAME" \
  '[
    {name: $vpc, type: "infra.vpc"},
    {name: $web, type: "infra.firewall"},
    {name: $db, type: "infra.firewall"}
  ]')"
PLAN_PAYLOAD="$(jq -n --argjson specs "$NETWORK_SPECS" '{specs: $specs}')"
PLAN=""
DESIRED_HASH=""

if PLAN="$(post_json /api/v1/networks/plan "$PLAN_PAYLOAD")"; then
  pass "client planned caller-supplied network specs through Workflow API"
  if printf '%s' "$PLAN" | jq -e --arg vpc "$VPC_NAME" --arg web "$WEB_FIREWALL_NAME" --arg db "$DB_FIREWALL_NAME" '.provider == "aws-provider" and (.desired_hash | type == "string" and length > 0) and (.plan.actions | length == 3) and (.plan.actions[] | select(.action == "create" and .resource.name == $vpc and .resource.type == "infra.vpc")) and (.plan.actions[] | select(.action == "create" and .resource.name == $web and .resource.type == "infra.firewall")) and (.plan.actions[] | select(.action == "create" and .resource.name == $db and .resource.type == "infra.firewall"))' >/dev/null 2>&1; then
    pass "plan response proposed VPC and firewall resources from request specs"
  else
    fail "plan response mismatch: $PLAN"
  fi
else
  fail "network plan API failed"
fi

if [ -n "$PLAN" ]; then
  DESIRED_HASH="$(printf '%s' "$PLAN" | jq -r '.desired_hash // empty')"
fi
if [ -n "$DESIRED_HASH" ]; then
  APPLY_PAYLOAD="$(jq -n --argjson specs "$NETWORK_SPECS" --arg desired_hash "$DESIRED_HASH" '{specs: $specs, desired_hash: $desired_hash}')"
  if APPLIED="$(post_json /api/v1/networks/apply "$APPLY_PAYLOAD")"; then
    pass "client applied network specs with returned desired_hash"
    if printf '%s' "$APPLIED" | jq -e --arg vpc "$VPC_NAME" --arg web "$WEB_FIREWALL_NAME" --arg db "$DB_FIREWALL_NAME" '.provider == "aws-provider" and .action_count == 3 and (.desired_hash | type == "string" and length > 0) and (.apply_result.resources[] | select(.name == $vpc and .type == "infra.vpc" and .status == "running" and .outputs.cidr == "10.20.0.0/16")) and (.apply_result.resources[] | select(.name == $web and .type == "infra.firewall" and .status == "running")) and (.apply_result.resources[] | select(.name == $db and .type == "infra.firewall" and .status == "running"))' >/dev/null 2>&1; then
      pass "apply response showed running mock VPC and firewalls"
    else
      fail "apply response mismatch: $APPLIED"
    fi
  else
    fail "network apply API failed"
  fi
else
  fail "network apply skipped because plan did not return desired_hash"
fi

STATUS_PAYLOAD="$(jq -n --argjson refs "$NETWORK_REFS" '{refs: $refs}')"
if STATUS_RUNNING="$(post_json /api/v1/networks/status "$STATUS_PAYLOAD")"; then
  pass "client fetched network status with caller-supplied refs"
  if printf '%s' "$STATUS_RUNNING" | jq -e --arg vpc "$VPC_NAME" --arg web "$WEB_FIREWALL_NAME" --arg db "$DB_FIREWALL_NAME" '.provider == "aws-provider" and .count == 3 and (.resources[] | select(.name == $vpc and .type == "infra.vpc" and .status == "running" and .outputs.cidr == "10.20.0.0/16")) and (.resources[] | select(.name == $web and .type == "infra.firewall" and .status == "running")) and (.resources[] | select(.name == $db and .type == "infra.firewall" and .status == "running"))' >/dev/null 2>&1; then
    pass "status response showed running request-selected network resources"
  else
    fail "status response mismatch after apply: $STATUS_RUNNING"
  fi
else
  fail "network status API failed"
fi

if DESTROYED="$(post_json /api/v1/networks/destroy "$STATUS_PAYLOAD")"; then
  pass "client destroyed network resources with caller-supplied refs"
  if printf '%s' "$DESTROYED" | jq -e --arg vpc "$VPC_NAME" --arg web "$WEB_FIREWALL_NAME" --arg db "$DB_FIREWALL_NAME" '.provider == "aws-provider" and (.destroyed | index($vpc)) and (.destroyed | index($web)) and (.destroyed | index($db)) and (.destroy_errors | length == 0)' >/dev/null 2>&1; then
    pass "destroy response confirmed mock network teardown"
  else
    fail "destroy response mismatch: $DESTROYED"
  fi
else
  fail "network destroy API failed"
fi

if STATUS_DESTROYED="$(post_json /api/v1/networks/status "$STATUS_PAYLOAD")"; then
  pass "client fetched network status after destroy"
  if printf '%s' "$STATUS_DESTROYED" | jq -e --arg vpc "$VPC_NAME" --arg web "$WEB_FIREWALL_NAME" --arg db "$DB_FIREWALL_NAME" '.provider == "aws-provider" and .count == 3 and (.resources[] | select(.name == $vpc and .status == "unknown")) and (.resources[] | select(.name == $web and .status == "unknown")) and (.resources[] | select(.name == $db and .status == "unknown"))' >/dev/null 2>&1; then
    pass "status response showed resources absent after destroy"
  else
    fail "status response mismatch after destroy: $STATUS_DESTROYED"
  fi
else
  fail "network status after destroy API failed"
fi

finish
