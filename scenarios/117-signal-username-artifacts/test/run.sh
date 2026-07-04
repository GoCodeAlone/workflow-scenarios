#!/usr/bin/env bash
# Scenario 117 - Signal username artifacts.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-signal subprocess from data/plugins, and drives
# account-parametric HTTP routes that execute step.signal_username_artifact_prepare
# and step.signal_service_test_username_reserve.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.23.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
ACCOUNT_A="${ACCOUNT_A:-account-a}"
ACCOUNT_B="${ACCOUNT_B:-account-b}"
USERNAME_A="${USERNAME_A:-caller_a.42}"
USERNAME_B="${USERNAME_B:-caller_b.42}"
EXPECTED_USERNAME_A_HASH="${EXPECTED_USERNAME_A_HASH:-f47a70b107084b26ae5c03a5d3eda64c7d5a20e99d1470c623e9829b864bc562}"
CANDIDATE_NICKNAME="${CANDIDATE_NICKNAME:-private_team}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18117}"

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
  stop_server
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

plugin_repo_supports_username_artifacts() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.capabilities.moduleTypes | index("signal.account_ref")) and
    (.capabilities.moduleTypes | index("signal.key_custody")) and
    (.capabilities.stepTypes | index("step.signal_username_artifact_prepare")) and
    (.capabilities.stepTypes | index("step.signal_service_test_username_reserve"))
  ' "$repo/plugin.json" >/dev/null 2>&1
}

resolve_server() {
  if [ -n "${WORKFLOW_SERVER:-}" ]; then
    [ -x "$WORKFLOW_SERVER" ] && printf '%s\n' "$WORKFLOW_SERVER" && return 0
    return 1
  fi

  local workflow_repo
  workflow_repo="$(find_repo "${WORKFLOW_REPO:-${WORKFLOW_DIR:-}}" "$REPO_ROOT/../workflow" "$REPO_ROOT/../../workflow" "$REPO_ROOT/../../../workflow")" || return 1
  mkdir -p "$workflow_repo/bin" || return 1
  (cd "$workflow_repo" && GOWORK=off go build -o bin/workflow-server ./cmd/server) >/dev/null 2>&1 || return 1
  printf '%s\n' "$workflow_repo/bin/workflow-server"
}

build_plugin() {
  local plugin_dir="$1"
  local plugin_repo
  if [ -n "${SIGNAL_PLUGIN_REPO:-}" ] && [ ! -d "$SIGNAL_PLUGIN_REPO" ]; then
    echo "SIGNAL_PLUGIN_REPO is set but is not a directory: $SIGNAL_PLUGIN_REPO" >&2
    return 1
  fi
  plugin_repo="$(find_repo "${SIGNAL_PLUGIN_REPO:-}" "$REPO_ROOT/../workflow-plugin-signal" "$REPO_ROOT/../../workflow-plugin-signal" "$REPO_ROOT/../../../workflow-plugin-signal")" || plugin_repo=""
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_username_artifacts "$plugin_repo"; then
    plugin_repo="$DATA_DIR/repos/workflow-plugin-signal"
    mkdir -p "$(dirname "$plugin_repo")" || return 1
    if git ls-remote --exit-code --tags https://github.com/GoCodeAlone/workflow-plugin-signal.git "refs/tags/$SIGNAL_PLUGIN_REF" >/dev/null 2>&1; then
      git clone --quiet --depth 1 https://github.com/GoCodeAlone/workflow-plugin-signal.git "$plugin_repo" || return 1
      git -C "$plugin_repo" fetch --quiet --depth 1 origin "refs/tags/$SIGNAL_PLUGIN_REF:refs/tags/$SIGNAL_PLUGIN_REF" || return 1
      git -C "$plugin_repo" -c advice.detachedHead=false checkout --quiet "$SIGNAL_PLUGIN_REF^{commit}" || return 1
    else
      git clone --quiet --depth 1 --branch "$SIGNAL_PLUGIN_REF" \
        https://github.com/GoCodeAlone/workflow-plugin-signal.git "$plugin_repo" || return 1
    fi
  fi

  mkdir -p "$plugin_dir/$PLUGIN_NAME" || return 1
  cp "$plugin_repo/plugin.json" "$plugin_dir/$PLUGIN_NAME/plugin.json" || return 1
  (cd "$plugin_repo" && GOWORK=off go build \
    -ldflags "-X github.com/GoCodeAlone/workflow-plugin-signal/internal.Version=${PLUGIN_VERSION}" \
    -o "$plugin_dir/$PLUGIN_NAME/$PLUGIN_NAME" ./cmd/workflow-plugin-signal) >/dev/null 2>&1 || return 1
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

start_server() {
  SERVER_LOG="$SCRIPT_DIR/artifacts/last-server.log"
  mkdir -p "$(dirname "$SERVER_LOG")"
  "$SERVER_BIN" -config "$CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  wait_for_server "$BASE_URL"
}

stop_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  SERVER_PID=""
}

json_post() {
  local url="$1"
  local body="$2"
  curl -fsS -X POST "$url" -H 'Content-Type: application/json' -d "$body"
}

http_status() {
  local url="$1"
  local body="$2"
  curl -sS -o /dev/null -w "%{http_code}" -X POST "$url" -H 'Content-Type: application/json' -d "$body" 2>/dev/null || echo "000"
}

artifact_body() {
  local request_ref="$1"
  local username="$2"
  jq -cn --arg request_ref "$request_ref" --arg username "$username" \
    '{request_ref:$request_ref, username:$username}'
}

candidate_body() {
  local request_ref="$1"
  local nickname="$2"
  local count="$3"
  jq -cn --arg request_ref "$request_ref" --arg nickname "$nickname" --argjson count "$count" \
    '{request_ref:$request_ref, candidate_nickname:$nickname, candidate_count:$count}'
}

reserve_username_body() {
  local request_ref="$1"
  local username="$2"
  jq -cn --arg request_ref "$request_ref" --arg username "$username" \
    '{request_ref:$request_ref, username:$username}'
}

reserve_hash_body() {
  local request_ref="$1"
  local hash_hex="$2"
  jq -cn --arg request_ref "$request_ref" --arg hash_hex "$hash_hex" \
    '{request_ref:$request_ref, username_hash_hex:$hash_hex}'
}

echo ""
echo "=== Scenario 117 - Signal Username Artifacts ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if [ ! -f "$CONFIG" ]; then
  finish
  exit 1
fi
if grep -Eiq 'alice|bob' "$CONFIG"; then
  fail "Workflow pipelines should not hard-code Alice/Bob participant names"
else
  pass "Workflow API is account-parametric"
fi
for required in \
  "type: signal.account_ref" \
  "type: signal.key_custody" \
  "type: step.signal_username_artifact_prepare" \
  "type: step.signal_service_test_username_reserve"
do
  if grep -q "$required" "$CONFIG"; then
    pass "Workflow app config exercises $required"
  else
    fail "Workflow app config missing $required"
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
PLUGIN_DIR="$DATA_DIR/plugins"
if build_plugin "$PLUGIN_DIR"; then
  pass "built workflow-plugin-signal external plugin with username artifacts"
else
  fail "could not build workflow-plugin-signal; set SIGNAL_PLUGIN_REPO"
  finish
  exit 1
fi

if start_server; then
  pass "workflow server started and served /healthz"
else
  fail "workflow server did not become ready; see $SERVER_LOG"
  finish
  exit 1
fi

ARTIFACT_A="$(json_post "$BASE_URL/accounts/$ACCOUNT_A/username-artifacts" "$(artifact_body "artifact-a" "$USERNAME_A")")" \
  && pass "account A prepared exact username artifact through Workflow API" \
  || fail "account A exact username artifact API failed"
HASH_A="$(printf '%s' "$ARTIFACT_A" | jq -r '.artifact.username_hash_hex // empty' 2>/dev/null)"
if [ "$HASH_A" = "$EXPECTED_USERNAME_A_HASH" ]; then
  pass "exact username hash matches upstream-derived compatibility vector"
else
  fail "exact username hash mismatch: got $HASH_A want $EXPECTED_USERNAME_A_HASH"
fi
if printf '%s' "$ARTIFACT_A" | jq -e --arg username "$USERNAME_A" '
  .artifact.username == $username and
  (.artifact.username_hash_hex | test("^[0-9a-f]{64}$")) and
  .artifact.proof_status == "deferred" and
  .artifact.proof_required_for_confirm == true and
  .artifact.algorithm == "signal-username-ristretto-v1" and
  .artifact.upstream_tag == "v0.96.4"
' >/dev/null 2>&1; then
  pass "exact artifact exposes hash metadata and explicit proof deferral"
else
  fail "exact artifact response missing hash/proof metadata: $ARTIFACT_A"
fi

ARTIFACT_A_REPEAT="$(json_post "$BASE_URL/accounts/$ACCOUNT_A/username-artifacts" "$(artifact_body "artifact-a-repeat" "$USERNAME_A")")" \
  && pass "repeat exact username artifact API succeeded" \
  || fail "repeat exact username artifact API failed"
HASH_A_REPEAT="$(printf '%s' "$ARTIFACT_A_REPEAT" | jq -r '.artifact.username_hash_hex // empty' 2>/dev/null)"
if [ "$HASH_A_REPEAT" = "$HASH_A" ]; then
  pass "exact username hash is deterministic across calls"
else
  fail "repeat exact username hash changed: $HASH_A_REPEAT"
fi

ARTIFACT_B="$(json_post "$BASE_URL/accounts/$ACCOUNT_B/username-artifacts" "$(artifact_body "artifact-b" "$USERNAME_B")")" \
  && pass "account B prepared a different username artifact through same Workflow API" \
  || fail "account B exact username artifact API failed"
HASH_B="$(printf '%s' "$ARTIFACT_B" | jq -r '.artifact.username_hash_hex // empty' 2>/dev/null)"
if [ -n "$HASH_B" ] && [ "$HASH_B" != "$HASH_A" ]; then
  pass "second caller-supplied username produced a different hash without YAML changes"
else
  fail "second username hash did not differ from first: $HASH_B"
fi

CANDIDATES_ONE="$(json_post "$BASE_URL/accounts/$ACCOUNT_A/username-artifacts" "$(candidate_body "candidate-one" "$CANDIDATE_NICKNAME" 3)")" \
  && pass "nickname candidate artifact API succeeded" \
  || fail "nickname candidate artifact API failed"
CANDIDATES_TWO="$(json_post "$BASE_URL/accounts/$ACCOUNT_A/username-artifacts" "$(candidate_body "candidate-two" "$CANDIDATE_NICKNAME" 3)")" \
  && pass "repeat nickname candidate artifact API succeeded" \
  || fail "repeat nickname candidate artifact API failed"
CANDIDATE_HASHES_ONE="$(printf '%s' "$CANDIDATES_ONE" | jq -c '[.artifact.candidates[].username_hash_hex]' 2>/dev/null)"
if printf '%s' "$CANDIDATES_ONE" | jq -e '
  (.artifact.candidates | length) == 3 and
  all(.artifact.candidates[]; (.username_hash_hex | test("^[0-9a-f]{64}$"))) and
  .artifact.proof_status == "deferred"
' >/dev/null 2>&1; then
  pass "nickname candidate artifact produced three hash candidates"
else
  fail "nickname candidate artifact missing valid hash candidates: $CANDIDATES_ONE"
fi
if printf '%s' "$CANDIDATES_TWO" | jq -e '
  (.artifact.candidates | length) == 3 and
  all(.artifact.candidates[]; (.username_hash_hex | test("^[0-9a-f]{64}$")))
' >/dev/null 2>&1; then
  pass "repeat nickname candidate artifact produced valid hash candidates"
else
  fail "repeat nickname candidate artifact missing hash candidates: $CANDIDATES_TWO"
fi
CANDIDATE_USERNAME="$(printf '%s' "$CANDIDATES_ONE" | jq -r '.artifact.candidates[0].username // empty' 2>/dev/null)"
CANDIDATE_HASH="$(printf '%s' "$CANDIDATES_ONE" | jq -r '.artifact.candidates[0].username_hash_hex // empty' 2>/dev/null)"
CANDIDATE_CONFIRM="$(json_post "$BASE_URL/accounts/$ACCOUNT_A/username-artifacts" "$(artifact_body "candidate-confirm" "$CANDIDATE_USERNAME")")" \
  && pass "candidate username was re-prepared through exact artifact API" \
  || fail "candidate username exact artifact API failed"
CANDIDATE_CONFIRM_HASH="$(printf '%s' "$CANDIDATE_CONFIRM" | jq -r '.artifact.username_hash_hex // empty' 2>/dev/null)"
if [ -n "$CANDIDATE_HASH" ] && [ "$CANDIDATE_CONFIRM_HASH" = "$CANDIDATE_HASH" ]; then
  pass "candidate hash matches exact hash for returned candidate username"
else
  fail "candidate hash did not match exact hash: candidate=$CANDIDATE_HASH exact=$CANDIDATE_CONFIRM_HASH hashes=$CANDIDATE_HASHES_ONE"
fi

RESERVE_A="$(json_post "$BASE_URL/accounts/$ACCOUNT_A/username-reservations/from-username" "$(reserve_username_body "reserve-a" "$USERNAME_A")")" \
  && pass "hash-only reserve from prepared artifact executed through Workflow API" \
  || fail "hash-only reserve from prepared artifact API failed"
RESERVE_A_HASH="$(printf '%s' "$RESERVE_A" | jq -r '.reserve.reserved_username_hash_hex // empty' 2>/dev/null)"
if printf '%s' "$RESERVE_A" | jq -e --arg account "$ACCOUNT_A" --arg hash "$HASH_A" '
  .reserve.account_ref == $account and
  .reserve.status == "accepted" and
  .reserve.request_id == "reserve-a" and
  .reserve.reserved_username_hash_hex == $hash and
  .reserve.username_hash_count == 1
' >/dev/null 2>&1; then
  pass "fake service reserve selected the prepared username hash"
else
  fail "fake service reserve did not return expected hash metadata: $RESERVE_A"
fi
if printf '%s' "$RESERVE_A" | jq -c '.reserve' 2>/dev/null | grep -Fq "$USERNAME_A"; then
  fail "reserve metadata exposed plaintext username"
else
  pass "reserve metadata omits plaintext username on hash path"
fi
if [ "$RESERVE_A_HASH" = "$HASH_A" ]; then
  pass "reserve hash output matches artifact hash"
else
  fail "reserve hash output mismatch: $RESERVE_A_HASH vs $HASH_A"
fi

DIRECT_RESERVE_B="$(json_post "$BASE_URL/accounts/$ACCOUNT_B/username-reservations/hash" "$(reserve_hash_body "direct-b" "$HASH_B")")" \
  && pass "direct caller-supplied hash reserve executed through Workflow API" \
  || fail "direct caller-supplied hash reserve API failed"
if printf '%s' "$DIRECT_RESERVE_B" | jq -e --arg account "$ACCOUNT_B" --arg hash "$HASH_B" '
  .reserve.account_ref == $account and
  .reserve.status == "accepted" and
  .reserve.request_id == "direct-b" and
  .reserve.reserved_username_hash_hex == $hash and
  .reserve.username_hash_count == 1
' >/dev/null 2>&1; then
  pass "direct hash reserve returns only hash metadata"
else
  fail "direct hash reserve missing expected metadata: $DIRECT_RESERVE_B"
fi

BAD_REF="bad-hash-then-recover"
BAD_STATUS="$(http_status "$BASE_URL/accounts/$ACCOUNT_A/username-reservations/hash" "$(reserve_hash_body "$BAD_REF" "not-a-hex-hash")")"
case "$BAD_STATUS" in
  4*|5*) pass "malformed hash request failed before reserve acceptance" ;;
  *) fail "malformed hash request returned HTTP $BAD_STATUS" ;;
esac
BAD_RECOVERY="$(json_post "$BASE_URL/accounts/$ACCOUNT_A/username-reservations/hash" "$(reserve_hash_body "$BAD_REF" "$HASH_A")")" \
  && pass "valid hash reused malformed request_ref after rejection" \
  || fail "valid hash could not reuse malformed request_ref"
if printf '%s' "$BAD_RECOVERY" | jq -e --arg hash "$HASH_A" '.reserve.status == "accepted" and .reserve.request_id == "bad-hash-then-recover" and .reserve.reserved_username_hash_hex == $hash' >/dev/null 2>&1; then
  pass "malformed hash rejection did not consume idempotency slot"
else
  fail "malformed hash recovery missing accepted evidence: $BAD_RECOVERY"
fi

MISSING_REF="missing-hash-then-recover"
MISSING_BODY="$(jq -cn --arg request_ref "$MISSING_REF" '{request_ref:$request_ref}')"
MISSING_STATUS="$(http_status "$BASE_URL/accounts/$ACCOUNT_A/username-reservations/hash" "$MISSING_BODY")"
case "$MISSING_STATUS" in
  4*|5*) pass "missing hash request failed before reserve acceptance" ;;
  *) fail "missing hash request returned HTTP $MISSING_STATUS" ;;
esac
MISSING_RECOVERY="$(json_post "$BASE_URL/accounts/$ACCOUNT_A/username-reservations/hash" "$(reserve_hash_body "$MISSING_REF" "$HASH_A")")" \
  && pass "valid hash reused missing-hash request_ref after rejection" \
  || fail "valid hash could not reuse missing-hash request_ref"
if printf '%s' "$MISSING_RECOVERY" | jq -e --arg hash "$HASH_A" '.reserve.status == "accepted" and .reserve.request_id == "missing-hash-then-recover" and .reserve.reserved_username_hash_hex == $hash' >/dev/null 2>&1; then
  pass "missing hash rejection did not consume idempotency slot"
else
  fail "missing hash recovery missing accepted evidence: $MISSING_RECOVERY"
fi

finish
