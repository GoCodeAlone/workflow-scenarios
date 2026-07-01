#!/usr/bin/env bash
# Scenario 32: Platform DNS through a real Workflow app boundary.
#
# Demonstration-fidelity: this starts workflow-server from the scenario config
# and drives DNS plan/apply/status through HTTP. The DNS provider uses the
# platform.dns mock backend as the disclosed local dependency seam; Workflow
# engine, HTTP routing, pipeline steps, and DNS module code paths are real.
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18132}"

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

wait_for_server() {
  local url="$1"
  local i
  local health
  for ((i = 1; i <= 80; i++)); do
    if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      return 1
    fi
    health="$(curl -fs "$url/healthz" 2>/dev/null)" \
      && printf '%s' "$health" | jq -e '.status == "ok" and .scenario == "32-platform-dns"' >/dev/null 2>&1 \
      && return 0
    sleep 0.25
  done
  return 1
}

post_json() {
  local path="$1"
  local payload="${2:-{}}"
  curl -fsS -X POST -H 'Content-Type: application/json' -d "$payload" "$BASE_URL$path"
}

get_json() {
  local path="$1"
  curl -fsS "$BASE_URL$path"
}

echo ""
echo "=== Scenario 32: Platform DNS Workflow App ==="
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
for item in "type: platform.dns" "provider: mock" "type: step.dns_plan" "type: step.dns_apply" "type: step.dns_status" "body_from: steps.plan" "body_from: steps.apply" "body_from: steps.status"; do
  if grep -Fq -- "$item" "$CONFIG"; then
    pass "Workflow config wires $item"
  else
    fail "Workflow config missing $item"
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

ZONE_NAME="example.com"
API_RECORD="api.example.com"
WWW_RECORD="www.example.com"
TXT_RECORD="example.com"

if PLAN="$(post_json /api/v1/dns/plan '{}')"; then
  pass "client planned DNS changes through Workflow API"
  if printf '%s' "$PLAN" | jq -e --arg zone "$ZONE_NAME" --arg api "$API_RECORD" --arg www "$WWW_RECORD" --arg txt "$TXT_RECORD" '.zone == "prod-dns" and (.changes | length == 4) and (.plan.zone.name == $zone) and (.records | length == 3) and (.records[] | select(.name == $api and .type == "A" and .value == "10.0.1.50")) and (.records[] | select(.name == $www and .type == "CNAME" and .value == "cdn.example.com")) and (.records[] | select(.name == $txt and .type == "TXT"))' >/dev/null 2>&1; then
    pass "plan response proposed configured zone and records"
  else
    fail "plan response mismatch: $PLAN"
  fi
else
  fail "dns plan API failed"
fi

if APPLIED="$(post_json /api/v1/dns/apply '{}')"; then
  pass "client applied DNS changes through Workflow API"
  if printf '%s' "$APPLIED" | jq -e --arg zone "$ZONE_NAME" --arg api "$API_RECORD" --arg www "$WWW_RECORD" --arg txt "$TXT_RECORD" '.zone == "prod-dns" and .status == "active" and .zoneName == $zone and (.zoneId | startswith("mock-zone-")) and (.records | length == 3) and (.records[] | select(.name == $api and .type == "A")) and (.records[] | select(.name == $www and .type == "CNAME")) and (.records[] | select(.name == $txt and .type == "TXT"))' >/dev/null 2>&1; then
    pass "apply response showed active mock DNS zone and records"
  else
    fail "apply response mismatch: $APPLIED"
  fi
else
  fail "dns apply API failed"
fi

if STATUS="$(get_json /api/v1/dns/status)"; then
  pass "client fetched DNS status through Workflow API"
  if printf '%s' "$STATUS" | jq -e --arg zone "$ZONE_NAME" '.zone == "prod-dns" and .status == "active" and .state.zoneName == $zone and (.state.records | length == 3)' >/dev/null 2>&1; then
    pass "status response showed active DNS state"
  else
    fail "status response mismatch: $STATUS"
  fi
else
  fail "dns status API failed"
fi

if PLAN_AFTER_APPLY="$(post_json /api/v1/dns/plan '{}')"; then
  pass "client re-planned DNS after apply through Workflow API"
  if printf '%s' "$PLAN_AFTER_APPLY" | jq -e '.changes == ["no changes"]' >/dev/null 2>&1; then
    pass "second plan reported no changes after apply"
  else
    fail "post-apply plan mismatch: $PLAN_AFTER_APPLY"
  fi
else
  fail "dns re-plan API failed"
fi

if finish; then
  echo ""
  echo "RESULT: ALL TESTS PASSED ($PASS/$PASS)"
  exit 0
else
  echo ""
  echo "RESULT: SOME TESTS FAILED ($PASS passed, $FAIL failed)"
  exit 1
fi
