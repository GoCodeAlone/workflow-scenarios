#!/usr/bin/env bash
# Scenario 35: multi-cloud accounts through a real Workflow app boundary.
#
# Demonstration-fidelity: this starts workflow-server from the scenario config,
# discovers configured accounts through the app API, then validates caller-
# selected accounts by provider. It must not delegate proof to Go package tests.
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18135}"
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
      && printf '%s' "$health" | jq -e '.status == "ok" and .scenario == "35-multi-cloud-accounts"' >/dev/null 2>&1 \
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

account_for_provider() {
  local accounts="$1"
  local provider="$2"
  printf '%s' "$accounts" | jq -r --arg provider "$provider" '.accounts[] | select(.provider == $provider) | .name' | head -n 1
}

assert_no_secrets() {
  local label="$1"
  local json="$2"
  if printf '%s' "$json" | grep -Eiq 'secretKey|accessKey|client_secret|private_key|token'; then
    fail "$label response exposed credential-looking material: $json"
  else
    pass "$label response did not expose credential material"
  fi
}

assert_account_response() {
  local label="$1"
  local json="$2"
  local account="$3"
  local provider="$4"
  local region="$5"
  if printf '%s' "$json" | jq -e --arg account "$account" --arg provider "$provider" --arg region "$region" \
    '.account == $account and .provider == $provider and .region == $region and .valid == true' >/dev/null 2>&1; then
    pass "$label response matched selected $provider account"
  else
    fail "$label response mismatch for $provider/$account: $json"
  fi

  case "$provider" in
    gcp)
      printf '%s' "$json" | jq -e '.project_id == "my-gcp-project"' >/dev/null 2>&1 \
        && pass "$label response included GCP project metadata" \
        || fail "$label response missing GCP project metadata: $json"
      ;;
    azure)
      printf '%s' "$json" | jq -e '.subscription_id == "00000000-0000-0000-0000-000000000001" and .tenant_id == "11111111-1111-1111-1111-111111111111"' >/dev/null 2>&1 \
        && pass "$label response included Azure tenant/subscription metadata" \
        || fail "$label response missing Azure metadata: $json"
      ;;
  esac
  assert_no_secrets "$label" "$json"
}

validate_account() {
  local label="$1"
  local account="$2"
  local provider="$3"
  local region="$4"
  local payload
  local validated
  local fetched
  payload="$(jq -cn --arg account "$account" '{account: $account}')"

  if validated="$(post_json /api/v1/cloud/validate "$payload")"; then
    pass "$label validate API accepted caller-selected account"
    assert_account_response "$label validate" "$validated" "$account" "$provider" "$region"
  else
    fail "$label validate API failed for $account"
  fi

  if fetched="$(get_json "/api/v1/cloud/accounts/$account")"; then
    pass "$label get API accepted path-selected account"
    assert_account_response "$label get" "$fetched" "$account" "$provider" "$region"
  else
    fail "$label get API failed for $account"
  fi
}

echo ""
echo "=== Scenario 35: Multi-Cloud Accounts Workflow App ==="
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
for item in "type: step.request_parse" "account_from: account" "path_params: [account]" "account_from: steps.parse_path.path_params.account" "type: step.cloud_validate"; do
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

if accounts="$(get_json /api/v1/cloud/accounts)"; then
  pass "client listed configured cloud accounts through Workflow API"
else
  fail "list cloud accounts API failed"
  finish
  exit 1
fi
if printf '%s' "$accounts" | jq -e '.count == 3 and ([.accounts[].provider] | sort == ["azure","gcp","mock"])' >/dev/null 2>&1; then
  pass "list response advertised mock, GCP, and Azure account providers"
else
  fail "list response missing expected providers: $accounts"
fi
assert_no_secrets "list accounts" "$accounts"

mock_account="${MOCK_ACCOUNT:-$(account_for_provider "$accounts" mock)}"
gcp_account="${GCP_ACCOUNT:-$(account_for_provider "$accounts" gcp)}"
azure_account="${AZURE_ACCOUNT:-$(account_for_provider "$accounts" azure)}"

if [ -n "$mock_account" ] && [ -n "$gcp_account" ] && [ -n "$azure_account" ]; then
  pass "client selected accounts by provider from API response"
else
  fail "could not select one account for each provider from: $accounts"
fi

validate_account "mock" "$mock_account" mock us-east-1
validate_account "gcp" "$gcp_account" gcp us-central1
validate_account "azure" "$azure_account" azure eastus

if finish; then
  echo ""
  echo "RESULT: ALL TESTS PASSED ($PASS/$PASS)"
  exit 0
else
  echo ""
  echo "RESULT: SOME TESTS FAILED ($PASS passed, $FAIL failed)"
  exit 1
fi
