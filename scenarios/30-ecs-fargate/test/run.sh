#!/usr/bin/env bash
# Scenario 30: ECS Fargate external AWS plugin.
#
# Demonstration-fidelity: this starts the real Workflow server from the
# scenario config, installs workflow-plugin-aws as an external plugin, and
# drives ECS-style IaC lifecycle steps through HTTP without live AWS access.
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18130}"

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
      && printf '%s' "$health" | jq -e '.status == "ok" and .scenario == "30-ecs-fargate"' >/dev/null 2>&1 \
      && return 0
    sleep 0.25
  done
  return 1
}

echo ""
echo "=== Scenario 30: ECS Fargate External AWS Plugin ==="
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
for item in "type: iac.provider" "plugin: workflow-plugin-aws" "mode: mock" "type: infra.container_service" "type: step.iac_provider_plan" "type: step.iac_provider_apply" "type: step.iac_provider_list" "type: step.iac_provider_destroy" "resources:" "- staging-ecs"; do
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

PLAN="$(curl -fsS -X POST "$BASE_URL/api/v1/services/plan")" \
  && pass "client planned ECS service through Workflow API" \
  || fail "ECS plan API failed"
if printf '%s' "$PLAN" | jq -e '.provider == "aws-provider" and (.desired_hash | type == "string" and length > 0) and (.plan.actions[] | select(.action == "create" and .resource.name == "staging-ecs" and .resource.type == "infra.container_service" and .resource.config.image == "public.ecr.aws/nginx/nginx:latest" and .resource.config.replicas == 2))' >/dev/null 2>&1; then
  pass "plan response proposed creating the ECS service"
else
  fail "plan response mismatch: $PLAN"
fi

APPLIED="$(curl -fsS -X POST "$BASE_URL/api/v1/services/apply")" \
  && pass "client applied ECS service through Workflow API" \
  || fail "ECS apply API failed"
if printf '%s' "$APPLIED" | jq -e '.provider == "aws-provider" and .action_count == 1 and (.desired_hash | type == "string" and length > 0) and (.apply_result.resources[] | select(.name == "staging-ecs" and .type == "infra.container_service" and .status == "running" and .outputs.image == "public.ecr.aws/nginx/nginx:latest" and .outputs.replicas == 2))' >/dev/null 2>&1; then
  pass "apply response showed running mock ECS service"
else
  fail "apply response mismatch: $APPLIED"
fi

STATUS_RUNNING="$(curl -fsS "$BASE_URL/api/v1/services/status")" \
  && pass "client fetched ECS status through Workflow API" \
  || fail "ECS status API failed"
if printf '%s' "$STATUS_RUNNING" | jq -e '.provider == "aws-provider" and .count == 1 and (.resources[] | select(.name == "staging-ecs" and .type == "infra.container_service" and .status == "running" and .outputs.image == "public.ecr.aws/nginx/nginx:latest"))' >/dev/null 2>&1; then
  pass "status response showed running mock service"
else
  fail "status response mismatch after apply: $STATUS_RUNNING"
fi

DESTROYED="$(curl -fsS -X DELETE "$BASE_URL/api/v1/services")" \
  && pass "client destroyed ECS service through Workflow API" \
  || fail "ECS destroy API failed"
if printf '%s' "$DESTROYED" | jq -e '.provider == "aws-provider" and (.destroyed | index("staging-ecs")) and (.destroy_errors | length == 0)' >/dev/null 2>&1; then
  pass "destroy response confirmed ECS teardown"
else
  fail "destroy response mismatch: $DESTROYED"
fi

STATUS_DESTROYED="$(curl -fsS "$BASE_URL/api/v1/services/status")" \
  && pass "client fetched destroyed ECS status through Workflow API" \
  || fail "ECS status after destroy API failed"
if printf '%s' "$STATUS_DESTROYED" | jq -e '.provider == "aws-provider" and .count == 1 and (.resources[] | select(.name == "staging-ecs" and .type == "infra.container_service" and .status == "unknown"))' >/dev/null 2>&1; then
  pass "status response showed absent live service after destroy"
else
  fail "status response mismatch after destroy: $STATUS_DESTROYED"
fi

finish
