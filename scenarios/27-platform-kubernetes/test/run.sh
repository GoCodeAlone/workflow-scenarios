#!/usr/bin/env bash
# Scenario 27: Platform Kubernetes.
#
# Demonstration-fidelity: this starts the real Workflow server from the
# scenario config and drives platform.kubernetes lifecycle steps through HTTP.
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18127}"

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
      && printf '%s' "$health" | jq -e '.status == "ok" and .scenario == "27-platform-kubernetes"' >/dev/null 2>&1 \
      && return 0
    sleep 0.25
  done
  return 1
}

echo ""
echo "=== Scenario 27: Platform Kubernetes ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if sed '/^[[:space:]]*#/d' "$SCRIPT_DIR/run.sh" | grep -Eq '(^|[;&|[:space:]])go[[:space:]]+test'; then
  fail "scenario test should not delegate proof to Go package tests"
else
  pass "scenario test exercises the Workflow app boundary"
fi
for step in step.k8s_plan step.k8s_apply step.k8s_status step.k8s_destroy; do
  if grep -q "type: $step" "$CONFIG"; then
    pass "Workflow config wires $step"
  else
    fail "Workflow config missing $step"
  fi
done

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

PLAN_BEFORE="$(curl -fsS -X POST "$BASE_URL/api/v1/clusters/plan")" \
  && pass "client planned cluster lifecycle through Workflow API" \
  || fail "cluster plan API failed"
if printf '%s' "$PLAN_BEFORE" | jq -e '.cluster == "production-cluster" and .provider == "kind" and (.actions[] | select(.type == "create"))' >/dev/null 2>&1; then
  pass "initial plan proposed creating the kind cluster"
else
  fail "initial plan did not propose create action: $PLAN_BEFORE"
fi

APPLIED="$(curl -fsS -X POST "$BASE_URL/api/v1/clusters/apply")" \
  && pass "client applied cluster lifecycle through Workflow API" \
  || fail "cluster apply API failed"
if printf '%s' "$APPLIED" | jq -e '.success == true and .cluster == "production-cluster" and .state.status == "running" and .state.endpoint == "https://127.0.0.1:6443"' >/dev/null 2>&1; then
  pass "apply response showed running in-memory kind cluster"
else
  fail "apply response did not show running cluster: $APPLIED"
fi

STATUS_RUNNING="$(curl -fsS "$BASE_URL/api/v1/clusters/status")" \
  && pass "client fetched running cluster status through Workflow API" \
  || fail "cluster status API failed"
if printf '%s' "$STATUS_RUNNING" | jq -e '.cluster == "production-cluster" and .status.status == "running" and .status.endpoint == "https://127.0.0.1:6443"' >/dev/null 2>&1; then
  pass "status response showed running cluster"
else
  fail "status response mismatch after apply: $STATUS_RUNNING"
fi

PLAN_AFTER="$(curl -fsS -X POST "$BASE_URL/api/v1/clusters/plan")" \
  && pass "client replanned running cluster through Workflow API" \
  || fail "cluster replan API failed"
if printf '%s' "$PLAN_AFTER" | jq -e '.cluster == "production-cluster" and (.actions[] | select(.type == "noop"))' >/dev/null 2>&1; then
  pass "post-apply plan changed to noop"
else
  fail "post-apply plan did not become noop: $PLAN_AFTER"
fi

DESTROYED="$(curl -fsS -X DELETE "$BASE_URL/api/v1/clusters")" \
  && pass "client destroyed cluster through Workflow API" \
  || fail "cluster destroy API failed"
if printf '%s' "$DESTROYED" | jq -e '.destroyed == true and .cluster == "production-cluster"' >/dev/null 2>&1; then
  pass "destroy response confirmed deletion request"
else
  fail "destroy response mismatch: $DESTROYED"
fi

STATUS_DELETED="$(curl -fsS "$BASE_URL/api/v1/clusters/status")" \
  && pass "client fetched deleted cluster status through Workflow API" \
  || fail "cluster status after destroy API failed"
if printf '%s' "$STATUS_DELETED" | jq -e '.cluster == "production-cluster" and .status.status == "deleted" and .status.endpoint == ""' >/dev/null 2>&1; then
  pass "status response showed deleted cluster"
else
  fail "status response mismatch after destroy: $STATUS_DELETED"
fi

finish
