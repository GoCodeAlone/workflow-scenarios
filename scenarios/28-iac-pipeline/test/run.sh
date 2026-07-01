#!/usr/bin/env bash
# Scenario 28: IaC Pipeline.
#
# Demonstration-fidelity: this starts the real Workflow server from the
# scenario config and drives IaC lifecycle steps through HTTP.
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18128}"

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
  (cd "$workflow_repo" && GOWORK=off go build -o bin/workflow-server ./cmd/server) >/dev/null 2>&1 || return 1
  printf '%s\n' "$workflow_repo/bin/workflow-server"
}

wait_for_server() {
  local url="$1"
  local i
  local health
  for i in $(seq 1 80); do
    if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      return 1
    fi
    health="$(curl -fs "$url/healthz" 2>/dev/null)" \
      && printf '%s' "$health" | jq -e '.status == "ok" and .scenario == "28-iac-pipeline"' >/dev/null 2>&1 \
      && return 0
    sleep 0.25
  done
  return 1
}

echo ""
echo "=== Scenario 28: IaC Pipeline ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if sed '/^[[:space:]]*#/d' "$SCRIPT_DIR/run.sh" | grep -Eq '(^|[;&|[:space:]])go[[:space:]]+test'; then
  fail "scenario test should not delegate proof to Go package tests"
else
  pass "scenario test exercises the Workflow app boundary"
fi
for step in step.iac_plan step.iac_apply step.iac_status step.iac_drift_detect step.iac_destroy; do
  if grep -q "type: $step" "$CONFIG"; then
    pass "Workflow config wires $step"
  else
    fail "Workflow config missing $step"
  fi
done
if grep -q 'directory: ${WORKFLOW_SCENARIO_IAC_STATE_DIR}' "$CONFIG"; then
  pass "Workflow config parameterizes filesystem state directory"
else
  fail "Workflow config should parameterize filesystem state directory"
fi

SERVER_BIN="$(resolve_server)"
if [ "$?" -eq 0 ]; then
  pass "workflow server binary is available"
else
  fail "workflow server unavailable; set WORKFLOW_SERVER or WORKFLOW_REPO"
  finish
  exit 1
fi

if ! DATA_DIR="$(mktemp -d)"; then
  fail "could not create temporary data directory"
  finish
  exit 1
fi
export WORKFLOW_SCENARIO_IAC_STATE_DIR="$DATA_DIR/iac-state"

SERVER_LOG="$SCRIPT_DIR/artifacts/last-server.log"
mkdir -p "$(dirname "$SERVER_LOG")"
"$SERVER_BIN" -config "$CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

if wait_for_server "$BASE_URL"; then
  pass "workflow server started and served /healthz"
else
  fail "workflow server did not become ready; see $SERVER_LOG"
  finish
  exit 1
fi

PLAN="$(curl -fsS -X POST "$BASE_URL/api/v1/iac/plan")" \
  && pass "client planned IaC lifecycle through Workflow API" \
  || fail "IaC plan API failed"
if printf '%s' "$PLAN" | jq -e '.resource_id == "production-cluster" and .provider == "kind" and .status == "planned" and (.actions[] | select(.type == "create"))' >/dev/null 2>&1; then
  pass "plan response recorded planned kind cluster create"
else
  fail "plan response mismatch: $PLAN"
fi
if [ -f "$WORKFLOW_SCENARIO_IAC_STATE_DIR/production-cluster.json" ]; then
  pass "plan persisted IaC state to filesystem backend"
else
  fail "plan did not persist IaC state file"
fi

APPLIED="$(curl -fsS -X POST "$BASE_URL/api/v1/iac/apply")" \
  && pass "client applied IaC lifecycle through Workflow API" \
  || fail "IaC apply API failed"
if printf '%s' "$APPLIED" | jq -e '.success == true and .resource_id == "production-cluster" and .status == "active" and .state.status == "running" and .outputs.status == "running"' >/dev/null 2>&1; then
  pass "apply response showed active IaC and running platform state"
else
  fail "apply response mismatch: $APPLIED"
fi
if jq -e '.status == "active" and .outputs.status == "running"' "$WORKFLOW_SCENARIO_IAC_STATE_DIR/production-cluster.json" >/dev/null 2>&1; then
  pass "apply updated persisted IaC state to active"
else
  fail "persisted state mismatch after apply"
fi

STATUS_ACTIVE="$(curl -fsS "$BASE_URL/api/v1/iac/status")" \
  && pass "client fetched IaC status through Workflow API" \
  || fail "IaC status API failed"
if printf '%s' "$STATUS_ACTIVE" | jq -e '.resource_id == "production-cluster" and .stored_status == "active" and .live_status.status == "running" and .state.status == "active"' >/dev/null 2>&1; then
  pass "status response joined live running state with active stored state"
else
  fail "status response mismatch after apply: $STATUS_ACTIVE"
fi

DRIFT="$(curl -fsS -X POST "$BASE_URL/api/v1/iac/drift")" \
  && pass "client detected IaC drift through Workflow API" \
  || fail "IaC drift API failed"
if printf '%s' "$DRIFT" | jq -e '.resource_id == "production-cluster" and .stored_status == "active" and .drifted == true and (.diffs | length > 0)' >/dev/null 2>&1; then
  pass "drift response reported authored config drift against stored state"
else
  fail "drift response mismatch: $DRIFT"
fi

DESTROYED="$(curl -fsS -X DELETE "$BASE_URL/api/v1/iac")" \
  && pass "client destroyed IaC resource through Workflow API" \
  || fail "IaC destroy API failed"
if printf '%s' "$DESTROYED" | jq -e '.destroyed == true and .resource_id == "production-cluster" and .status == "destroyed"' >/dev/null 2>&1; then
  pass "destroy response confirmed IaC teardown"
else
  fail "destroy response mismatch: $DESTROYED"
fi
if jq -e '.status == "destroyed"' "$WORKFLOW_SCENARIO_IAC_STATE_DIR/production-cluster.json" >/dev/null 2>&1; then
  pass "destroy updated persisted IaC state to destroyed"
else
  fail "persisted state mismatch after destroy"
fi

STATUS_DESTROYED="$(curl -fsS "$BASE_URL/api/v1/iac/status")" \
  && pass "client fetched destroyed IaC status through Workflow API" \
  || fail "IaC status after destroy API failed"
if printf '%s' "$STATUS_DESTROYED" | jq -e '.resource_id == "production-cluster" and .stored_status == "destroyed" and .live_status.status == "deleted" and .state.status == "destroyed"' >/dev/null 2>&1; then
  pass "status response showed destroyed stored state and deleted live state"
else
  fail "status response mismatch after destroy: $STATUS_DESTROYED"
fi

finish
