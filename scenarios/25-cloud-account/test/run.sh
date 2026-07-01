#!/usr/bin/env bash
# Scenario 25: Cloud Account.
#
# Demonstration-fidelity: this starts the real Workflow server from the
# scenario config and validates configured cloud accounts through HTTP APIs.
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18125}"
ACCOUNT_UNDER_TEST="${ACCOUNT_UNDER_TEST:-aws-staging}"
EXPECTED_PROVIDER="${EXPECTED_PROVIDER:-mock}"
EXPECTED_REGION="${EXPECTED_REGION:-us-west-2}"

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
  for i in $(seq 1 80); do
    curl -fs "$url/healthz" >/dev/null 2>&1 && return 0
    if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      return 1
    fi
    sleep 0.25
  done
  return 1
}

echo ""
echo "=== Scenario 25: Cloud Account ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if sed '/^[[:space:]]*#/d' "$SCRIPT_DIR/run.sh" | grep -Eq '(^|[;&|[:space:]])go[[:space:]]+test'; then
  fail "scenario test should not delegate proof to Go package tests"
else
  pass "scenario test exercises the Workflow app boundary"
fi
if grep -A8 'name: validate' "$CONFIG" | grep -q 'account_from: account'; then
  pass "validation pipeline selects account from client request"
else
  fail "validation pipeline should use account_from"
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

LISTED="$(curl -fsS "$BASE_URL/api/cloud/accounts")" \
  && pass "client listed configured cloud accounts through Workflow API" \
  || fail "list cloud accounts API failed"
if printf '%s' "$LISTED" | jq -e --arg account "$ACCOUNT_UNDER_TEST" '.count >= 3 and (.accounts[] | select(.name == $account))' >/dev/null 2>&1; then
  pass "list response included the account under test"
else
  fail "list response missing account under test: $LISTED"
fi
if printf '%s' "$LISTED" | jq -e 'all(.accounts[]; (has("secretKey") or has("accessKey") or has("token")) | not)' >/dev/null 2>&1; then
  pass "list response did not expose credential material"
else
  fail "list response exposed credential-looking keys: $LISTED"
fi

VALIDATE_BODY="$(jq -cn --arg account "$ACCOUNT_UNDER_TEST" '{account:$account}')"
VALIDATED="$(curl -fsS -X POST "$BASE_URL/api/cloud/validate" -H 'Content-Type: application/json' -d "$VALIDATE_BODY")" \
  && pass "client validated selected account through Workflow API" \
  || fail "validate cloud account API failed"
if printf '%s' "$VALIDATED" | jq -e \
  --arg account "$ACCOUNT_UNDER_TEST" \
  --arg provider "$EXPECTED_PROVIDER" \
  --arg region "$EXPECTED_REGION" \
  '.account == $account and .valid == true and .provider == $provider and .region == $region' >/dev/null 2>&1; then
  pass "validate response matched selected account provider and region"
else
  fail "validate response mismatch: $VALIDATED"
fi
if printf '%s' "$VALIDATED" | jq -e 'has("secretKey") or has("accessKey") or has("token")' >/dev/null 2>&1; then
  fail "validate response exposed credential-looking keys: $VALIDATED"
else
  pass "validate response did not expose credential material"
fi

FETCHED="$(curl -fsS "$BASE_URL/api/cloud/accounts/$ACCOUNT_UNDER_TEST")" \
  && pass "client fetched selected account through Workflow API" \
  || fail "get cloud account API failed"
if printf '%s' "$FETCHED" | jq -e \
  --arg account "$ACCOUNT_UNDER_TEST" \
  --arg provider "$EXPECTED_PROVIDER" \
  --arg region "$EXPECTED_REGION" \
  '.account == $account and .valid == true and .provider == $provider and .region == $region' >/dev/null 2>&1; then
  pass "get response matched selected account provider and region"
else
  fail "get response mismatch: $FETCHED"
fi

finish
