#!/usr/bin/env bash
# Scenario 120 - Signal trust policy gate.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-signal subprocess from data/plugins, and drives
# participant-parametric HTTP routes that execute the HTTP-backed
# signal.trust_store, step.signal_trust_observe, step.signal_trust_reset,
# step.signal_trust_history, step.signal_trust_policy_check, encryption, and
# outbox enqueue.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.26.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
SENDER="${SENDER:-user-a}"
RECIPIENT="${RECIPIENT:-user-b}"
CHANGED_RECIPIENT="${CHANGED_RECIPIENT:-user-c}"
SECOND_SENDER="${SECOND_SENDER:-tenant-a}"
SECOND_RECIPIENT="${SECOND_RECIPIENT:-tenant-b}"
SPACE="${SPACE:-private-space-120}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18120}"
TRUST_BACKEND_URL="${TRUST_BACKEND_URL:-http://127.0.0.1:19120}"
SIGNAL_TRUST_HTTP_TOKEN="${SIGNAL_TRUST_HTTP_TOKEN:-scenario-120-token}"
MESSAGE_MARKER="${MESSAGE_MARKER:-signal-trust-policy-gate-secret-120}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG_TEMPLATE="$SCENARIO_DIR/config/app.yaml"

PASS=0
FAIL=0
SERVER_PID=""
BACKEND_PID=""
DATA_DIR=""
RUNTIME_CONFIG=""
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
cleanup() {
  stop_server
  stop_backend
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

base64_encode() {
  base64 | tr -d '\n'
}

plugin_repo_supports_trust_store() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.capabilities.moduleTypes | index("signal.identity_store")) and
    (.capabilities.moduleTypes | index("signal.trust_store")) and
    (.capabilities.moduleTypes | index("signal.envelope_store")) and
    (.capabilities.stepTypes | index("step.signal_session_prepare")) and
    (.capabilities.stepTypes | index("step.signal_trust_observe")) and
    (.capabilities.stepTypes | index("step.signal_trust_reset")) and
    (.capabilities.stepTypes | index("step.signal_trust_history")) and
    (.capabilities.stepTypes | index("step.signal_trust_policy_check")) and
    (.capabilities.stepTypes | index("step.signal_encrypt")) and
    (.capabilities.stepTypes | index("step.signal_outbox_enqueue"))
  ' "$repo/plugin.json" >/dev/null 2>&1
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

build_plugin() {
  local plugin_dir="$1"
  local plugin_repo
  if [ -n "${SIGNAL_PLUGIN_REPO:-}" ] && [ ! -d "$SIGNAL_PLUGIN_REPO" ]; then
    echo "SIGNAL_PLUGIN_REPO is set but is not a directory: $SIGNAL_PLUGIN_REPO" >&2
    return 1
  fi
  plugin_repo="$(find_repo "${SIGNAL_PLUGIN_REPO:-}" "$REPO_ROOT/../workflow-plugin-signal" "$REPO_ROOT/../../../workflow-plugin-signal")" || plugin_repo=""
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_trust_store "$plugin_repo"; then
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
  SIGNAL_TRUST_HTTP_TOKEN="$SIGNAL_TRUST_HTTP_TOKEN" "$SERVER_BIN" -config "$RUNTIME_CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  wait_for_server "$BASE_URL"
}

start_server_without_auth_env() {
  SERVER_LOG="$SCRIPT_DIR/artifacts/last-server-missing-auth.log"
  mkdir -p "$(dirname "$SERVER_LOG")"
  env -u SIGNAL_TRUST_HTTP_TOKEN "$SERVER_BIN" -config "$RUNTIME_CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
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

wait_for_backend() {
  local i
  for i in $(seq 1 80); do
    curl -fs "$TRUST_BACKEND_URL/healthz" >/dev/null 2>&1 && return 0
    if [ -n "$BACKEND_PID" ] && ! kill -0 "$BACKEND_PID" >/dev/null 2>&1; then
      return 1
    fi
    sleep 0.25
  done
  return 1
}

start_backend() {
  BACKEND_LOG="$SCRIPT_DIR/artifacts/last-trust-backend.log"
  mkdir -p "$(dirname "$BACKEND_LOG")"
  python3 "$SCRIPT_DIR/fake_trust_backend.py" \
    --listen "127.0.0.1:19120" \
    --state "$BACKEND_STATE" \
    --store-ref persistent_trust \
    --token "$SIGNAL_TRUST_HTTP_TOKEN" >"$BACKEND_LOG" 2>&1 &
  BACKEND_PID=$!
  wait_for_backend
}

stop_backend() {
  if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" >/dev/null 2>&1; then
    kill "$BACKEND_PID" >/dev/null 2>&1 || true
    wait "$BACKEND_PID" >/dev/null 2>&1 || true
  fi
  BACKEND_PID=""
}

prepare_bundle() {
  local participant="$1"
  curl -fsS -X POST "$BASE_URL/participants/$participant/session" -H 'Content-Type: application/json' -d '{}'
}

trusted_send_body() {
  local message_ref="$1"
  local plaintext_b64="$2"
  local local_bundle="$3"
  local remote_bundle="$4"
  jq -cn \
    --arg message_ref "$message_ref" \
    --arg plaintext "$plaintext_b64" \
    --argjson local_bundle "$local_bundle" \
    --argjson remote_bundle "$remote_bundle" \
    '{message_ref:$message_ref, plaintext:$plaintext, local_bundle:$local_bundle, remote_bundle:$remote_bundle}'
}

send_trusted() {
  local sender="$1"
  local recipient="$2"
  local message_ref="$3"
  local plaintext_b64="$4"
  local local_bundle="$5"
  local remote_bundle="$6"
  local body
  body="$(trusted_send_body "$message_ref" "$plaintext_b64" "$local_bundle" "$remote_bundle")" || return 1
  curl -fsS -X POST "$BASE_URL/spaces/$SPACE/participants/$sender/trusted-send/$recipient" \
    -H 'Content-Type: application/json' -d "$body"
}

reset_body() {
  local reason_ref="$1"
  local previous_record_ref="$2"
  local local_bundle="$3"
  local remote_bundle="$4"
  jq -cn \
    --arg reason_ref "$reason_ref" \
    --arg previous_record_ref "$previous_record_ref" \
    --argjson local_bundle "$local_bundle" \
    --argjson remote_bundle "$remote_bundle" \
    '{reason_ref:$reason_ref, previous_record_ref:$previous_record_ref, local_bundle:$local_bundle, remote_bundle:$remote_bundle}'
}

trust_check_body() {
  local reason_ref="$1"
  local local_bundle="$2"
  local remote_bundle="$3"
  jq -cn \
    --arg reason_ref "$reason_ref" \
    --argjson local_bundle "$local_bundle" \
    --argjson remote_bundle "$remote_bundle" \
    '{reason_ref:$reason_ref, local_bundle:$local_bundle, remote_bundle:$remote_bundle}'
}

policy_body() {
  local required_record_ref="$1"
  jq -cn --arg required_record_ref "$required_record_ref" '{required_record_ref:$required_record_ref}'
}

check_trust() {
  local sender="$1"
  local recipient="$2"
  local reason_ref="$3"
  local local_bundle="$4"
  local remote_bundle="$5"
  local body
  body="$(trust_check_body "$reason_ref" "$local_bundle" "$remote_bundle")" || return 1
  curl -fsS -X POST "$BASE_URL/spaces/$SPACE/participants/$sender/trust-check/$recipient" \
    -H 'Content-Type: application/json' -d "$body"
}

check_policy() {
  local sender="$1"
  local recipient="$2"
  local required_record_ref="$3"
  local body
  body="$(policy_body "$required_record_ref")" || return 1
  curl -fsS -X POST "$BASE_URL/spaces/$SPACE/participants/$sender/trust-policy/$recipient" \
    -H 'Content-Type: application/json' -d "$body"
}

report_policy() {
  local sender="$1"
  local recipient="$2"
  local required_record_ref="$3"
  local body
  body="$(policy_body "$required_record_ref")" || return 1
  curl -fsS -X POST "$BASE_URL/spaces/$SPACE/participants/$sender/trust-policy-report/$recipient" \
    -H 'Content-Type: application/json' -d "$body"
}

reset_trust() {
  local sender="$1"
  local recipient="$2"
  local reason_ref="$3"
  local previous_record_ref="$4"
  local local_bundle="$5"
  local remote_bundle="$6"
  local body
  body="$(reset_body "$reason_ref" "$previous_record_ref" "$local_bundle" "$remote_bundle")" || return 1
  curl -fsS -X POST "$BASE_URL/spaces/$SPACE/participants/$sender/trust-reset/$recipient" \
    -H 'Content-Type: application/json' -d "$body"
}

trust_history() {
  local sender="$1"
  local recipient="$2"
  curl -fsS -X POST "$BASE_URL/spaces/$SPACE/participants/$sender/trust-history/$recipient" \
    -H 'Content-Type: application/json' -d '{}'
}

backend_state() {
  curl -fsS "$TRUST_BACKEND_URL/control/state"
}

arm_backend_conflict() {
  curl -fsS -X POST "$TRUST_BACKEND_URL/control/conflict" >/dev/null
}

arm_backend_corrupt() {
  curl -fsS -X POST "$TRUST_BACKEND_URL/control/corrupt" >/dev/null
}

http_status() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local status
  if [ -n "$body" ]; then
    status="$(curl -sS -o /dev/null -w "%{http_code}" -X "$method" "$url" -H 'Content-Type: application/json' -d "$body" 2>/dev/null || true)"
  else
    status="$(curl -sS -o /dev/null -w "%{http_code}" -X "$method" "$url" 2>/dev/null || true)"
  fi
  case "$status" in
    [0-9][0-9][0-9]) printf '%s\n' "$status" ;;
    *) printf '000\n' ;;
  esac
}

echo ""
echo "=== Scenario 120 - Signal Trust Policy Gate ==="
echo ""

[ -f "$CONFIG_TEMPLATE" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if [ ! -f "$CONFIG_TEMPLATE" ]; then
  finish
  exit 1
fi
if grep -Eiq 'a[l]ice|b[o]b' "$CONFIG_TEMPLATE"; then
  fail "Workflow pipelines should not hard-code fixed demo participant names"
else
  pass "Workflow API is participant-parametric"
fi
for required in "backend: http" "type: signal.trust_store" "type: step.signal_trust_observe" "type: step.signal_trust_reset" "type: step.signal_trust_history" "type: step.signal_trust_policy_check" "type: step.signal_encrypt" "type: step.signal_outbox_enqueue"; do
  if grep -q "$required" "$CONFIG_TEMPLATE"; then
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
BACKEND_STATE="$DATA_DIR/trust/backend-state.json"
mkdir -p "$(dirname "$BACKEND_STATE")"
RUNTIME_CONFIG="$DATA_DIR/app.yaml"
sed \
  -e "s#__TRUST_BACKEND_URL__#$TRUST_BACKEND_URL#g" \
  "$CONFIG_TEMPLATE" >"$RUNTIME_CONFIG" || {
    fail "could not render runtime config"
    finish
    exit 1
  }
if build_plugin "$PLUGIN_DIR"; then
  pass "built workflow-plugin-signal external plugin"
else
  fail "could not build workflow-plugin-signal; set SIGNAL_PLUGIN_REPO"
  finish
  exit 1
fi

if start_backend; then
  pass "scenario fake HTTP trust backend started"
else
  fail "fake HTTP trust backend did not become ready; see $BACKEND_LOG"
  finish
  exit 1
fi

if start_server; then
  pass "workflow server started and loaded HTTP trust backend"
else
  fail "workflow server did not become ready; see $SERVER_LOG"
  finish
  exit 1
fi

SENDER_SESSION="$(prepare_bundle "$SENDER")" \
  && pass "sender published a local bundle via Workflow API" \
  || fail "sender session prepare API failed"
RECIPIENT_SESSION="$(prepare_bundle "$RECIPIENT")" \
  && pass "recipient published a remote bundle via Workflow API" \
  || fail "recipient session prepare API failed"
CHANGED_SESSION="$(prepare_bundle "$CHANGED_RECIPIENT")" \
  && pass "changed-key fixture published a bundle via Workflow API" \
  || fail "changed-key fixture session prepare API failed"
SECOND_SENDER_SESSION="$(prepare_bundle "$SECOND_SENDER")" \
  && pass "second sender published a local bundle via Workflow API" \
  || fail "second sender session prepare API failed"
SECOND_RECIPIENT_SESSION="$(prepare_bundle "$SECOND_RECIPIENT")" \
  && pass "second recipient published a remote bundle via Workflow API" \
  || fail "second recipient session prepare API failed"
SENDER_BUNDLE="$(printf '%s' "$SENDER_SESSION" | jq -c '.bundle // empty' 2>/dev/null)"
RECIPIENT_BUNDLE="$(printf '%s' "$RECIPIENT_SESSION" | jq -c '.bundle // empty' 2>/dev/null)"
CHANGED_BUNDLE="$(printf '%s' "$CHANGED_SESSION" | jq -c '.bundle // empty' 2>/dev/null)"
SECOND_SENDER_BUNDLE="$(printf '%s' "$SECOND_SENDER_SESSION" | jq -c '.bundle // empty' 2>/dev/null)"
SECOND_RECIPIENT_BUNDLE="$(printf '%s' "$SECOND_RECIPIENT_SESSION" | jq -c '.bundle // empty' 2>/dev/null)"
if [ -n "$SENDER_BUNDLE" ] && [ "$SENDER_BUNDLE" != "null" ] &&
   [ -n "$RECIPIENT_BUNDLE" ] && [ "$RECIPIENT_BUNDLE" != "null" ] &&
   [ -n "$CHANGED_BUNDLE" ] && [ "$CHANGED_BUNDLE" != "null" ] &&
   [ -n "$SECOND_SENDER_BUNDLE" ] && [ "$SECOND_SENDER_BUNDLE" != "null" ] &&
   [ -n "$SECOND_RECIPIENT_BUNDLE" ] && [ "$SECOND_RECIPIENT_BUNDLE" != "null" ]; then
  pass "all participant bundles contain public Signal material"
else
  fail "missing bundle material"
fi

PLAINTEXT_ONE="$(printf '%s' "{\"marker\":\"$MESSAGE_MARKER\",\"round\":\"first\",\"space\":\"$SPACE\"}" | base64_encode)"
FIRST_RESPONSE="$(send_trusted "$SENDER" "$RECIPIENT" "message-first" "$PLAINTEXT_ONE" "$SENDER_BUNDLE" "$RECIPIENT_BUNDLE")" \
  && pass "first trusted send executed through Workflow API" \
  || fail "first trusted send API failed"
FIRST_STATUS="$(printf '%s' "$FIRST_RESPONSE" | jq -r '.trust.status // empty' 2>/dev/null)"
FIRST_RECORD="$(printf '%s' "$FIRST_RESPONSE" | jq -r '.trust.record_ref // empty' 2>/dev/null)"
FIRST_POLICY_ALLOWED="$(printf '%s' "$FIRST_RESPONSE" | jq -r '.policy.allowed // empty' 2>/dev/null)"
FIRST_POLICY_REASON="$(printf '%s' "$FIRST_RESPONSE" | jq -r '.policy.reason // empty' 2>/dev/null)"
FIRST_POLICY_RECORD="$(printf '%s' "$FIRST_RESPONSE" | jq -r '.policy.record_ref // empty' 2>/dev/null)"
FIRST_ENVELOPE_REF="$(printf '%s' "$FIRST_RESPONSE" | jq -r '.envelope_ref // empty' 2>/dev/null)"
FIRST_CIPHERTEXT="$(printf '%s' "$FIRST_RESPONSE" | jq -r '.envelope.ciphertext // empty' 2>/dev/null)"
if [ "$FIRST_STATUS" = "new_trust" ] && [ -n "$FIRST_RECORD" ] && [ -n "$FIRST_ENVELOPE_REF" ] && [ -n "$FIRST_CIPHERTEXT" ]; then
  pass "first trusted send created trust and queued encrypted envelope"
else
  fail "first trusted send response missing trust/envelope evidence: $FIRST_RESPONSE"
fi
if [ "$FIRST_POLICY_ALLOWED" = "true" ] && [ "$FIRST_POLICY_REASON" = "new_trust" ] && [ "$FIRST_POLICY_RECORD" = "$FIRST_RECORD" ]; then
  pass "trusted-send route gated first send through trust policy"
else
  fail "first trusted send missing policy-gate evidence: $FIRST_RESPONSE"
fi
if printf '%s' "$FIRST_RESPONSE" | grep -Fq "$MESSAGE_MARKER"; then
  fail "first trusted send response exposed plaintext marker"
else
  pass "first trusted send response does not expose plaintext marker"
fi
FIRST_POLICY_RESPONSE="$(check_policy "$SENDER" "$RECIPIENT" "$FIRST_RECORD")" \
  && pass "policy gate allowed first-pair trusted record through Workflow API" \
  || fail "policy gate rejected first trusted record"
if printf '%s' "$FIRST_POLICY_RESPONSE" | jq -e --arg record "$FIRST_RECORD" '.policy.allowed == true and .policy.reason == "new_trust" and .policy.record_ref == $record' >/dev/null 2>&1; then
  pass "policy gate returned new_trust metadata for first record"
else
  fail "policy gate first record response was unexpected: $FIRST_POLICY_RESPONSE"
fi
if jq -e '.generation_ref == "generation-1" and .puts == 1 and .snapshot.schema_version == 1 and (.snapshot.checksum | length > 20) and (.snapshot.state.records | length == 1)' "$BACKEND_STATE" >/dev/null 2>&1; then
  pass "HTTP trust backend persisted schema, checksum, generation, and one record"
else
  fail "HTTP trust backend missing expected persisted metadata"
fi

PLAINTEXT_TWO="$(printf '%s' "{\"marker\":\"$MESSAGE_MARKER\",\"round\":\"repeat\",\"space\":\"$SPACE\"}" | base64_encode)"
REPEAT_RESPONSE="$(send_trusted "$SENDER" "$RECIPIENT" "message-repeat" "$PLAINTEXT_TWO" "$SENDER_BUNDLE" "$RECIPIENT_BUNDLE")" \
  && pass "repeat trusted send executed before reset" \
  || fail "repeat trusted send API failed"
REPEAT_STATUS="$(printf '%s' "$REPEAT_RESPONSE" | jq -r '.trust.status // empty' 2>/dev/null)"
REPEAT_RECORD="$(printf '%s' "$REPEAT_RESPONSE" | jq -r '.trust.record_ref // empty' 2>/dev/null)"
REPEAT_POLICY_ALLOWED="$(printf '%s' "$REPEAT_RESPONSE" | jq -r '.policy.allowed // empty' 2>/dev/null)"
REPEAT_POLICY_REASON="$(printf '%s' "$REPEAT_RESPONSE" | jq -r '.policy.reason // empty' 2>/dev/null)"
if [ "$REPEAT_STATUS" = "trusted" ] && [ "$REPEAT_RECORD" = "$FIRST_RECORD" ] &&
   [ "$REPEAT_POLICY_ALLOWED" = "true" ] && [ "$REPEAT_POLICY_REASON" = "trusted" ]; then
  pass "existing trust record returned trusted and passed policy before reset"
else
  fail "repeat trust evidence did not match initial record: $REPEAT_RESPONSE"
fi

SECOND_PLAINTEXT="$(printf '%s' "{\"marker\":\"$MESSAGE_MARKER\",\"round\":\"second-pair\",\"space\":\"$SPACE\"}" | base64_encode)"
SECOND_RESPONSE="$(send_trusted "$SECOND_SENDER" "$SECOND_RECIPIENT" "message-second-pair" "$SECOND_PLAINTEXT" "$SECOND_SENDER_BUNDLE" "$SECOND_RECIPIENT_BUNDLE")" \
  && pass "second participant pair executed trusted send through same Workflow route" \
  || fail "second participant pair trusted send API failed"
SECOND_STATUS="$(printf '%s' "$SECOND_RESPONSE" | jq -r '.trust.status // empty' 2>/dev/null)"
SECOND_RECORD="$(printf '%s' "$SECOND_RESPONSE" | jq -r '.trust.record_ref // empty' 2>/dev/null)"
SECOND_POLICY_ALLOWED="$(printf '%s' "$SECOND_RESPONSE" | jq -r '.policy.allowed // empty' 2>/dev/null)"
SECOND_POLICY_REASON="$(printf '%s' "$SECOND_RESPONSE" | jq -r '.policy.reason // empty' 2>/dev/null)"
if [ "$SECOND_STATUS" = "new_trust" ] && [ -n "$SECOND_RECORD" ] &&
   [ "$SECOND_POLICY_ALLOWED" = "true" ] && [ "$SECOND_POLICY_REASON" = "new_trust" ]; then
  pass "second pair created an independent trust record and passed policy"
else
  fail "second pair response missing independent trust evidence: $SECOND_RESPONSE"
fi
SECOND_HISTORY="$(trust_history "$SECOND_SENDER" "$SECOND_RECIPIENT")" \
  && pass "second participant pair queried history through same Workflow route" \
  || fail "second participant pair history API failed"
if printf '%s' "$SECOND_HISTORY" | jq -e --arg trust_ref "space://$SPACE/$SECOND_SENDER/$SECOND_RECIPIENT" '.history.count == 1 and .history.events[0].trust_ref == $trust_ref and .history.events[0].status == "new_trust"' >/dev/null 2>&1; then
  pass "second pair history is scoped to its URL-derived trust_ref"
else
  fail "second pair history was not scoped correctly: $SECOND_HISTORY"
fi

CHANGED_BODY="$(trusted_send_body "message-changed" "$PLAINTEXT_TWO" "$SENDER_BUNDLE" "$CHANGED_BUNDLE")" || CHANGED_BODY=""
CHANGED_STATUS="$(http_status POST "$BASE_URL/spaces/$SPACE/participants/$SENDER/trusted-send/$RECIPIENT" "$CHANGED_BODY")"
case "$CHANGED_STATUS" in
  4*|5*) pass "changed remote identity key was rejected before send" ;;
  *) fail "changed remote identity key returned HTTP $CHANGED_STATUS" ;;
esac
POLICY_DENY_BODY="$(policy_body "$FIRST_RECORD")" || POLICY_DENY_BODY=""
POLICY_DENY_STATUS="$(http_status POST "$BASE_URL/spaces/$SPACE/participants/$SENDER/trust-policy/$RECIPIENT" "$POLICY_DENY_BODY")"
case "$POLICY_DENY_STATUS" in
  4*|5*) pass "enforcing policy gate denied changed last trust status" ;;
  *) fail "enforcing policy gate returned HTTP $POLICY_DENY_STATUS after changed key" ;;
esac
POLICY_REPORT_RESPONSE="$(report_policy "$SENDER" "$RECIPIENT" "$FIRST_RECORD")" \
  && pass "report-only policy returned changed-key denial metadata" \
  || fail "report-only policy route failed after changed key"
if printf '%s' "$POLICY_REPORT_RESPONSE" | jq -e --arg record "$FIRST_RECORD" '(.policy.allowed // false) == false and .policy.reason == "last_status_denied" and .policy.last_status == "changed" and .policy.record_ref == $record' >/dev/null 2>&1; then
  pass "report-only policy captured changed last status without allowing send"
else
  fail "report-only changed policy response was unexpected: $POLICY_REPORT_RESPONSE"
fi
MISMATCH_POLICY_RESPONSE="$(report_policy "$SENDER" "$RECIPIENT" "signal-trust://not-current")" \
  && pass "report-only policy returned record mismatch metadata" \
  || fail "report-only policy route failed for record mismatch"
if printf '%s' "$MISMATCH_POLICY_RESPONSE" | jq -e '(.policy.allowed // false) == false and .policy.reason == "record_mismatch"' >/dev/null 2>&1; then
  pass "policy gate denies stale required_record_ref"
else
  fail "policy record mismatch response was unexpected: $MISMATCH_POLICY_RESPONSE"
fi
MISSING_POLICY_RESPONSE="$(report_policy "$SENDER" "missing-recipient" "")" \
  && pass "report-only policy returned missing-trust metadata" \
  || fail "report-only policy route failed for missing trust"
if printf '%s' "$MISSING_POLICY_RESPONSE" | jq -e '(.policy.allowed // false) == false and .policy.reason == "missing"' >/dev/null 2>&1; then
  pass "policy gate reports missing trust for URL-derived unknown pair"
else
  fail "policy missing response was unexpected: $MISSING_POLICY_RESPONSE"
fi
if printf '%s' "$POLICY_REPORT_RESPONSE$MISMATCH_POLICY_RESPONSE$MISSING_POLICY_RESPONSE" | grep -Fq "$MESSAGE_MARKER" ||
   printf '%s' "$POLICY_REPORT_RESPONSE$MISMATCH_POLICY_RESPONSE$MISSING_POLICY_RESPONSE" | grep -Eq 'display|scannable|private_key|plaintext|Authorization|scenario-120-token'; then
  fail "policy responses exposed key material, plaintext, auth, or raw fingerprint evidence"
else
  pass "policy responses expose only trust decision metadata"
fi

RECOVERY_RESPONSE="$(send_trusted "$SENDER" "$RECIPIENT" "message-changed" "$PLAINTEXT_TWO" "$SENDER_BUNDLE" "$RECIPIENT_BUNDLE")" \
  && pass "original trusted key reused changed message_ref after rejection" \
  || fail "original trusted key could not reuse changed message_ref after rejection"
RECOVERY_ENVELOPE_REF="$(printf '%s' "$RECOVERY_RESPONSE" | jq -r '.envelope_ref // empty' 2>/dev/null)"
if [ -n "$RECOVERY_ENVELOPE_REF" ] && [ "$RECOVERY_ENVELOPE_REF" != "$FIRST_ENVELOPE_REF" ]; then
  pass "changed-key rejection did not consume the outbox idempotency slot"
else
  fail "changed-key rejection appears to have consumed or reused an outbox slot: $RECOVERY_RESPONSE"
fi
if [ "$(jq -r '.snapshot.state.records | length' "$BACKEND_STATE" 2>/dev/null)" = "2" ]; then
  pass "changed-key rejection did not mutate trust records"
else
  fail "changed-key rejection mutated trust records"
fi

MISSING_REASON_BODY="$(reset_body "" "$FIRST_RECORD" "$SENDER_BUNDLE" "$CHANGED_BUNDLE")" || MISSING_REASON_BODY=""
MISSING_REASON_STATUS="$(http_status POST "$BASE_URL/spaces/$SPACE/participants/$SENDER/trust-reset/$RECIPIENT" "$MISSING_REASON_BODY")"
case "$MISSING_REASON_STATUS" in
  4*|5*) pass "trust reset without reason_ref was rejected" ;;
  *) fail "trust reset without reason_ref returned HTTP $MISSING_REASON_STATUS" ;;
esac

STALE_RESET_BODY="$(reset_body "approval://$SPACE/stale-reset" "signal-trust://stale-record" "$SENDER_BUNDLE" "$CHANGED_BUNDLE")" || STALE_RESET_BODY=""
STALE_RESET_STATUS="$(http_status POST "$BASE_URL/spaces/$SPACE/participants/$SENDER/trust-reset/$RECIPIENT" "$STALE_RESET_BODY")"
case "$STALE_RESET_STATUS" in
  4*|5*) pass "trust reset with stale previous_record_ref was rejected" ;;
  *) fail "trust reset with stale previous_record_ref returned HTTP $STALE_RESET_STATUS" ;;
esac
if [ "$(jq -r '.snapshot.state.records | length' "$BACKEND_STATE" 2>/dev/null)" = "2" ]; then
  pass "failed reset attempts did not mutate trust records"
else
  fail "failed reset attempts mutated trust records"
fi

RESET_REASON="approval://$SPACE/message-changed/rotate"
RESET_RESPONSE="$(reset_trust "$SENDER" "$RECIPIENT" "$RESET_REASON" "$FIRST_RECORD" "$SENDER_BUNDLE" "$CHANGED_BUNDLE")" \
  && pass "approved trust reset executed through Workflow API" \
  || fail "approved trust reset API failed"
RESET_STATUS="$(printf '%s' "$RESET_RESPONSE" | jq -r '.reset.status // empty' 2>/dev/null)"
RESET_RECORD="$(printf '%s' "$RESET_RESPONSE" | jq -r '.reset.record_ref // empty' 2>/dev/null)"
RESET_PREVIOUS="$(printf '%s' "$RESET_RESPONSE" | jq -r '.reset.previous_record_ref // empty' 2>/dev/null)"
RESET_ROTATED="$(printf '%s' "$RESET_RESPONSE" | jq -r '.reset.rotated // empty' 2>/dev/null)"
RESET_REASON_OUT="$(printf '%s' "$RESET_RESPONSE" | jq -r '.reset.reason_ref // empty' 2>/dev/null)"
if [ "$RESET_STATUS" = "reset" ] && [ "$RESET_PREVIOUS" = "$FIRST_RECORD" ] &&
   [ "$RESET_ROTATED" = "true" ] && [ "$RESET_REASON_OUT" = "$RESET_REASON" ] &&
   [ -n "$RESET_RECORD" ] && [ "$RESET_RECORD" != "$FIRST_RECORD" ]; then
  pass "approved reset rotated trust record with CAS and reason evidence"
else
  fail "approved reset response missing rotation evidence: $RESET_RESPONSE"
fi
if printf '%s' "$RESET_RESPONSE" | grep -Eq 'display|scannable_hex'; then
  fail "trust reset response exposed raw display or scannable fingerprint evidence"
else
  pass "trust reset response returned refs and hashes without raw fingerprint evidence"
fi
RESET_POLICY_RESPONSE="$(check_policy "$SENDER" "$RECIPIENT" "$RESET_RECORD")" \
  && pass "policy gate allowed reset trust record before next send" \
  || fail "policy gate rejected reset trust record"
if printf '%s' "$RESET_POLICY_RESPONSE" | jq -e --arg record "$RESET_RECORD" '.policy.allowed == true and .policy.reason == "reset" and .policy.record_ref == $record' >/dev/null 2>&1; then
  pass "policy gate returned reset metadata for rotated record"
else
  fail "policy reset response was unexpected: $RESET_POLICY_RESPONSE"
fi

AFTER_RESET_RESPONSE="$(check_trust "$SENDER" "$RECIPIENT" "request://$SPACE/after-reset" "$SENDER_BUNDLE" "$CHANGED_BUNDLE")" \
  && pass "new remote key was trusted after reset" \
  || fail "new remote key trust check failed after reset"
AFTER_RESET_STATUS="$(printf '%s' "$AFTER_RESET_RESPONSE" | jq -r '.trust.status // empty' 2>/dev/null)"
AFTER_RESET_RECORD="$(printf '%s' "$AFTER_RESET_RESPONSE" | jq -r '.trust.record_ref // empty' 2>/dev/null)"
if [ "$AFTER_RESET_STATUS" = "trusted" ] && [ "$AFTER_RESET_RECORD" = "$RESET_RECORD" ]; then
  pass "new key observe returned trusted with rotated record"
else
  fail "new key trust evidence did not match rotated record: $AFTER_RESET_RESPONSE"
fi
AFTER_RESET_POLICY_RESPONSE="$(check_policy "$SENDER" "$RECIPIENT" "$RESET_RECORD")" \
  && pass "policy gate allowed trusted rotated record after observe" \
  || fail "policy gate rejected trusted rotated record after observe"
if printf '%s' "$AFTER_RESET_POLICY_RESPONSE" | jq -e --arg record "$RESET_RECORD" '.policy.allowed == true and .policy.reason == "trusted" and .policy.record_ref == $record' >/dev/null 2>&1; then
  pass "policy gate returned trusted metadata after reset observe"
else
  fail "policy after reset observe response was unexpected: $AFTER_RESET_POLICY_RESPONSE"
fi

OLD_BODY="$(trust_check_body "request://$SPACE/old-after-reset" "$SENDER_BUNDLE" "$RECIPIENT_BUNDLE")" || OLD_BODY=""
OLD_STATUS="$(http_status POST "$BASE_URL/spaces/$SPACE/participants/$SENDER/trust-check/$RECIPIENT" "$OLD_BODY")"
case "$OLD_STATUS" in
  4*|5*) pass "old remote identity key was rejected after reset" ;;
  *) fail "old remote identity key returned HTTP $OLD_STATUS after reset" ;;
esac
OLD_POLICY_REPORT="$(report_policy "$SENDER" "$RECIPIENT" "$RESET_RECORD")" \
  && pass "report-only policy reflected old-key rejection after reset" \
  || fail "report-only policy failed after old-key rejection"
if printf '%s' "$OLD_POLICY_REPORT" | jq -e --arg record "$RESET_RECORD" '(.policy.allowed // false) == false and .policy.reason == "last_status_denied" and .policy.last_status == "changed" and .policy.record_ref == $record' >/dev/null 2>&1; then
  pass "policy gate denied old-key changed event while retaining rotated record"
else
  fail "policy old-key denial response was unexpected: $OLD_POLICY_REPORT"
fi
if [ "$(jq -r '.snapshot.state.records | length' "$BACKEND_STATE" 2>/dev/null)" = "2" ] &&
   jq -e --arg current "$RESET_RECORD" '.snapshot.state.records[] | select(.record_ref == $current)' "$BACKEND_STATE" >/dev/null 2>&1; then
  pass "HTTP trust backend snapshot contains the rotated first-pair record and second pair"
else
  fail "HTTP trust backend snapshot does not contain the rotated first-pair record"
fi

HISTORY_RESPONSE="$(trust_history "$SENDER" "$RECIPIENT")" \
  && pass "trust history queried through Workflow API before restart" \
  || fail "trust history API failed before restart"
HISTORY_STATUSES="$(printf '%s' "$HISTORY_RESPONSE" | jq -r '.history.events[].status' 2>/dev/null | paste -sd, -)"
case "$HISTORY_STATUSES" in
  *new_trust*trusted*changed*reset*trusted*changed*) pass "history recorded new, trusted, changed, reset, and old-key rejection events" ;;
  *) fail "history did not record expected first-pair decisions: $HISTORY_STATUSES" ;;
esac
if printf '%s' "$HISTORY_RESPONSE" | jq -e --arg reason "$RESET_REASON" --arg previous "$FIRST_RECORD" --arg current "$RESET_RECORD" '
  .history.events[]
  | select(.status == "reset" and .reason_ref == $reason and .previous_record_ref == $previous and .record_ref == $current)
' >/dev/null 2>&1; then
  pass "history recorded reset reason and previous/new refs"
else
  fail "history missing reset reason or record refs: $HISTORY_RESPONSE"
fi
SENDER_KEY="$(printf '%s' "$SENDER_BUNDLE" | jq -r '.identity_key')"
OLD_KEY="$(printf '%s' "$RECIPIENT_BUNDLE" | jq -r '.identity_key')"
NEW_KEY="$(printf '%s' "$CHANGED_BUNDLE" | jq -r '.identity_key')"
if printf '%s' "$HISTORY_RESPONSE" | grep -Fq "$SENDER_KEY" ||
   printf '%s' "$HISTORY_RESPONSE" | grep -Fq "$OLD_KEY" ||
   printf '%s' "$HISTORY_RESPONSE" | grep -Fq "$NEW_KEY" ||
   printf '%s' "$HISTORY_RESPONSE" | grep -Fq "$MESSAGE_MARKER" ||
   printf '%s' "$HISTORY_RESPONSE" | grep -Eq 'display|scannable|private_key|plaintext|Authorization|scenario-120-token'; then
  fail "history response exposed key material, plaintext, auth, or raw fingerprint evidence"
else
  pass "history response is redacted to decision metadata"
fi
if jq -e --arg reason "$RESET_REASON" --arg previous "$FIRST_RECORD" --arg current "$RESET_RECORD" '
  .snapshot.state.events[]
  | select(.status == "reset" and .reason_ref == $reason and .previous_record_ref == $previous and .record_ref == $current)
' "$BACKEND_STATE" >/dev/null 2>&1; then
  pass "fake HTTP backend durably stored redacted reset event"
else
  fail "fake HTTP backend missing durable reset event"
fi

stop_server
if start_server; then
  pass "workflow server restarted from HTTP trust backend"
else
  fail "workflow server did not restart after reset; see $SERVER_LOG"
  finish
  exit 1
fi

POST_RESTART_RESPONSE="$(send_trusted "$SENDER" "$RECIPIENT" "message-post-restart" "$PLAINTEXT_TWO" "$SENDER_BUNDLE" "$CHANGED_BUNDLE")" \
  && pass "new remote key remained trusted after restart" \
  || fail "new remote key failed after restart"
POST_RESTART_STATUS="$(printf '%s' "$POST_RESTART_RESPONSE" | jq -r '.trust.status // empty' 2>/dev/null)"
POST_RESTART_RECORD="$(printf '%s' "$POST_RESTART_RESPONSE" | jq -r '.trust.record_ref // empty' 2>/dev/null)"
POST_RESTART_POLICY_ALLOWED="$(printf '%s' "$POST_RESTART_RESPONSE" | jq -r '.policy.allowed // empty' 2>/dev/null)"
POST_RESTART_POLICY_REASON="$(printf '%s' "$POST_RESTART_RESPONSE" | jq -r '.policy.reason // empty' 2>/dev/null)"
if [ "$POST_RESTART_STATUS" = "trusted" ] && [ "$POST_RESTART_RECORD" = "$RESET_RECORD" ] &&
   [ "$POST_RESTART_POLICY_ALLOWED" = "true" ] && [ "$POST_RESTART_POLICY_REASON" = "trusted" ]; then
  pass "restart preserved rotated trust record and trusted-send policy gate"
else
  fail "post-restart trust evidence did not match rotated record: $POST_RESTART_RESPONSE"
fi

POST_RESTART_HISTORY="$(trust_history "$SENDER" "$RECIPIENT")" \
  && pass "trust history remained queryable after restart" \
  || fail "trust history failed after restart"
if printf '%s' "$POST_RESTART_HISTORY" | jq -e --arg current "$RESET_RECORD" '.history.events[] | select(.status == "trusted" and .record_ref == $current)' >/dev/null 2>&1; then
  pass "post-restart history includes trusted decision from reloaded HTTP state"
else
  fail "post-restart history missing trusted decision: $POST_RESTART_HISTORY"
fi

BEFORE_CONFLICT_GENERATION="$(jq -r '.generation_ref' "$BACKEND_STATE" 2>/dev/null)"
BEFORE_CONFLICT_RECORD="$(jq -r --arg trust_ref "space://$SPACE/$SENDER/$RECIPIENT" '.snapshot.state.records[$trust_ref].record_ref' "$BACKEND_STATE" 2>/dev/null)"
arm_backend_conflict
CONFLICT_BODY="$(reset_body "approval://$SPACE/conflict" "$RESET_RECORD" "$SENDER_BUNDLE" "$RECIPIENT_BUNDLE")" || CONFLICT_BODY=""
CONFLICT_STATUS="$(http_status POST "$BASE_URL/spaces/$SPACE/participants/$SENDER/trust-reset/$RECIPIENT" "$CONFLICT_BODY")"
case "$CONFLICT_STATUS" in
  4*|5*) pass "HTTP backend generation conflict failed the Workflow request" ;;
  *) fail "HTTP backend generation conflict returned HTTP $CONFLICT_STATUS" ;;
esac
if [ "$(jq -r '.generation_ref' "$BACKEND_STATE" 2>/dev/null)" = "$BEFORE_CONFLICT_GENERATION" ] &&
   [ "$(jq -r --arg trust_ref "space://$SPACE/$SENDER/$RECIPIENT" '.snapshot.state.records[$trust_ref].record_ref' "$BACKEND_STATE" 2>/dev/null)" = "$BEFORE_CONFLICT_RECORD" ]; then
  pass "generation conflict left durable HTTP trust state unchanged"
else
  fail "generation conflict mutated durable HTTP trust state"
fi

stop_server
if start_server; then
  pass "workflow server recovered from durable HTTP state after conflict"
else
  fail "workflow server did not recover after conflict; see $SERVER_LOG"
  finish
  exit 1
fi

stop_server
if start_server_without_auth_env; then
  fail "workflow server started despite missing HTTP trust backend auth env"
  stop_server
else
  pass "HTTP trust backend auth env is required during app startup"
fi

OLD_TOKEN="$SIGNAL_TRUST_HTTP_TOKEN"
SIGNAL_TRUST_HTTP_TOKEN="wrong-token"
if start_server; then
  fail "workflow server started despite invalid HTTP trust backend auth"
  stop_server
else
  pass "HTTP trust backend rejected invalid auth during app startup"
fi
SIGNAL_TRUST_HTTP_TOKEN="$OLD_TOKEN"

arm_backend_corrupt
if start_server; then
  fail "workflow server started despite corrupt HTTP trust snapshot"
  stop_server
else
  pass "corrupt HTTP trust snapshot failed closed during app startup"
fi

finish
