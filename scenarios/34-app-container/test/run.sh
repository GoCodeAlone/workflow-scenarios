#!/usr/bin/env bash
# Scenario 34: app.container through a real Workflow app boundary.
#
# Demonstration-fidelity: this starts workflow-server from the scenario config,
# sends caller-provided deployment specs over HTTP, and verifies deploy/status/
# rollback behavior through Workflow's app.container pipeline steps. It must not
# delegate proof to Go package tests.
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18134}"
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

wait_for_server() {
  local url="$1"
  local i
  local health
  for ((i = 1; i <= 80; i++)); do
    if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      return 1
    fi
    health="$(curl --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -fs "$url/healthz" 2>/dev/null)" \
      && printf '%s' "$health" | jq -e '.status == "ok" and .scenario == "34-app-container"' >/dev/null 2>&1 \
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

get_json() {
  local path="$1"
  curl --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -fsS "$BASE_URL$path"
}

deploy_spec() {
  local label="$1"
  local image="$2"
  local replicas="$3"
  local log_level="$4"
  jq -n --arg image "$image" --argjson replicas "$replicas" --arg label "$label" --arg log_level "$log_level" '{
    spec: {
      image: $image,
      replicas: $replicas,
      ports: [8080],
      cpu: "500m",
      memory: "256Mi",
      health_path: "/healthz",
      health_port: 8080,
      env: {
        APP_ENV: "scenario",
        RELEASE_LABEL: $label,
        LOG_LEVEL: $log_level
      }
    }
  }'
}

assert_deploy_response() {
  local label="$1"
  local json="$2"
  local image="$3"
  local replicas="$4"
  if printf '%s' "$json" | jq -e --arg image "$image" --argjson replicas "$replicas" '.app == "webapp" and .status == "active" and .image == $image and .replicas == $replicas and (.endpoint | type == "string" and length > 0)' >/dev/null 2>&1; then
    pass "$label deployment response used caller-supplied spec"
  else
    fail "$label deployment response mismatch: $json"
  fi
}

assert_status_response() {
  local label="$1"
  local json="$2"
  local image="$3"
  local replicas="$4"
  local status="${5:-active}"
  if printf '%s' "$json" | jq -e --arg image "$image" --argjson replicas "$replicas" --arg status "$status" '.app == "webapp" and .status == $status and .image == $image and .replicas == $replicas' >/dev/null 2>&1; then
    pass "$label status response reflected current deployment"
  else
    fail "$label status response mismatch: $json"
  fi
}

echo ""
echo "=== Scenario 34: App Container Workflow App ==="
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
for item in "type: step.request_parse" "type: step.app_deploy" "spec_from: steps.parse-request.body.spec" "type: step.app_status" "type: step.app_rollback"; do
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

INITIAL_IMAGE="${INITIAL_IMAGE:-ghcr.io/gocodealone/customer-portal:v1}"
NEXT_IMAGE="${NEXT_IMAGE:-ghcr.io/gocodealone/customer-portal:v2}"
INITIAL_REPLICAS="${INITIAL_REPLICAS:-2}"
NEXT_REPLICAS="${NEXT_REPLICAS:-4}"

initial_payload="$(deploy_spec "initial" "$INITIAL_IMAGE" "$INITIAL_REPLICAS" "info")"
if initial_deploy="$(post_json /api/v1/app/deploy "$initial_payload")"; then
  pass "initial deploy accepted caller-supplied spec"
  assert_deploy_response "initial" "$initial_deploy" "$INITIAL_IMAGE" "$INITIAL_REPLICAS"
else
  fail "initial deploy API failed"
fi

if initial_status="$(get_json /api/v1/app/status)"; then
  pass "initial status API returned current deployment"
  assert_status_response "initial" "$initial_status" "$INITIAL_IMAGE" "$INITIAL_REPLICAS"
else
  fail "initial status API failed"
fi

next_payload="$(deploy_spec "next" "$NEXT_IMAGE" "$NEXT_REPLICAS" "debug")"
if next_deploy="$(post_json /api/v1/app/deploy "$next_payload")"; then
  pass "next deploy accepted caller-supplied spec"
  assert_deploy_response "next" "$next_deploy" "$NEXT_IMAGE" "$NEXT_REPLICAS"
else
  fail "next deploy API failed"
fi

if next_status="$(get_json /api/v1/app/status)"; then
  pass "next status API returned current deployment"
  assert_status_response "next" "$next_status" "$NEXT_IMAGE" "$NEXT_REPLICAS"
else
  fail "next status API failed"
fi

if rollback="$(post_json /api/v1/app/rollback '{}')"; then
  pass "rollback API reverted the previous deployment"
  if printf '%s' "$rollback" | jq -e --arg image "$INITIAL_IMAGE" --argjson replicas "$INITIAL_REPLICAS" '.app == "webapp" and .rolled_back == true and .status == "rolled_back" and .image == $image and .result.replicas == $replicas' >/dev/null 2>&1; then
    pass "rollback response restored initial runtime image"
  else
    fail "rollback response mismatch: $rollback"
  fi
else
  fail "rollback API failed"
fi

if rollback_status="$(get_json /api/v1/app/status)"; then
  pass "post-rollback status API returned current deployment"
  assert_status_response "post-rollback" "$rollback_status" "$INITIAL_IMAGE" "$INITIAL_REPLICAS" "rolled_back"
else
  fail "post-rollback status API failed"
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
