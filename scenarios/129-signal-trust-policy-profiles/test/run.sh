#!/usr/bin/env bash
# Scenario 129 - Signal trust policy profiles.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-signal subprocess from data/plugins, and drives
# participant-parametric HTTP routes that execute signal.trust_store,
# step.signal_trust_observe, step.signal_trust_policy_check, and
# step.signal_trust_reset before encryption and outbox enqueue.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.32.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
SENDER="${SENDER:-user-a}"
RECIPIENT="${RECIPIENT:-user-b}"
CHANGED_RECIPIENT="${CHANGED_RECIPIENT:-user-c}"
SPACE="${SPACE:-private-space-129}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18129}"
MESSAGE_MARKER="${MESSAGE_MARKER:-signal-trust-policy-profiles-secret-129}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG_TEMPLATE="$SCENARIO_DIR/config/app.yaml"

PASS=0
FAIL=0
SERVER_PID=""
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
    (.capabilities.stepTypes | index("step.signal_trust_policy_check")) and
    (.capabilities.stepTypes | index("step.signal_trust_reset")) and
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
  plugin_repo="$(find_repo "${SIGNAL_PLUGIN_REPO:-}")" || plugin_repo=""
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
  "$SERVER_BIN" -config "$RUNTIME_CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
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
  local policy_profile="$2"
  jq -cn \
    --arg required_record_ref "$required_record_ref" \
    --arg policy_profile "$policy_profile" \
    '{required_record_ref:$required_record_ref, policy_profile:$policy_profile}'
}

observe_trust() {
  local sender="$1"
  local recipient="$2"
  local reason_ref="$3"
  local local_bundle="$4"
  local remote_bundle="$5"
  local body
  body="$(trust_check_body "$reason_ref" "$local_bundle" "$remote_bundle")" || return 1
  curl -fsS -X POST "$BASE_URL/spaces/$SPACE/participants/$sender/trust-observe/$recipient" \
    -H 'Content-Type: application/json' -d "$body"
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

check_policy_profile() {
  local sender="$1"
  local recipient="$2"
  local required_record_ref="$3"
  local policy_profile="$4"
  local body
  body="$(policy_body "$required_record_ref" "$policy_profile")" || return 1
  curl -fsS -X POST "$BASE_URL/spaces/$SPACE/participants/$sender/trust-policy-profile/$recipient" \
    -H 'Content-Type: application/json' -d "$body"
}

report_policy_profile() {
  local sender="$1"
  local recipient="$2"
  local required_record_ref="$3"
  local policy_profile="$4"
  local body
  body="$(policy_body "$required_record_ref" "$policy_profile")" || return 1
  curl -fsS -X POST "$BASE_URL/spaces/$SPACE/participants/$sender/trust-policy-profile-report/$recipient" \
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

http_status() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -o /dev/null -w "%{http_code}" -X "$method" "$url" -H 'Content-Type: application/json' -d "$body" 2>/dev/null || echo "000"
  else
    curl -sS -o /dev/null -w "%{http_code}" -X "$method" "$url" 2>/dev/null || echo "000"
  fi
}

echo ""
echo "=== Scenario 129 - Signal Trust Policy Profiles ==="
echo ""

[ -f "$CONFIG_TEMPLATE" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if [ ! -f "$CONFIG_TEMPLATE" ]; then
  finish
  exit 1
fi
DEMO_NAME_ONE="$(printf 'al%s' 'ice')"
DEMO_NAME_TWO="$(printf 'bo%s' 'b')"
if grep -Fiq "$DEMO_NAME_ONE" "$CONFIG_TEMPLATE" || grep -Fiq "$DEMO_NAME_TWO" "$CONFIG_TEMPLATE"; then
  fail "Workflow pipelines should not hard-code named demo participants"
else
  pass "Workflow API is participant-parametric"
fi
for required in "type: signal.trust_store" "type: step.signal_trust_observe" "type: step.signal_trust_policy_check" "type: step.signal_trust_reset" "type: step.signal_encrypt" "type: step.signal_outbox_enqueue"; do
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
TRUST_PATH="$DATA_DIR/trust/store.json"
AUDIT_PATH="$DATA_DIR/trust/audit.jsonl"
mkdir -p "$(dirname "$TRUST_PATH")"
RUNTIME_CONFIG="$DATA_DIR/app.yaml"
sed \
  -e "s#__TRUST_STORE_PATH__#$TRUST_PATH#g" \
  -e "s#__TRUST_AUDIT_PATH__#$AUDIT_PATH#g" \
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

if start_server; then
  pass "workflow server started and served /healthz"
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
SENDER_BUNDLE="$(printf '%s' "$SENDER_SESSION" | jq -c '.bundle // empty' 2>/dev/null)"
RECIPIENT_BUNDLE="$(printf '%s' "$RECIPIENT_SESSION" | jq -c '.bundle // empty' 2>/dev/null)"
CHANGED_BUNDLE="$(printf '%s' "$CHANGED_SESSION" | jq -c '.bundle // empty' 2>/dev/null)"
if [ -n "$SENDER_BUNDLE" ] && [ "$SENDER_BUNDLE" != "null" ] &&
   [ -n "$RECIPIENT_BUNDLE" ] && [ "$RECIPIENT_BUNDLE" != "null" ] &&
   [ -n "$CHANGED_BUNDLE" ] && [ "$CHANGED_BUNDLE" != "null" ]; then
  pass "all participant bundles contain public Signal material"
else
  fail "missing bundle material"
fi

FIRST_RESPONSE="$(observe_trust "$SENDER" "$RECIPIENT" "request://$SPACE/first-observe" "$SENDER_BUNDLE" "$RECIPIENT_BUNDLE")" \
  && pass "first trust observation executed through Workflow API" \
  || fail "first trust observation API failed"
FIRST_STATUS="$(printf '%s' "$FIRST_RESPONSE" | jq -r '.trust.status // empty' 2>/dev/null)"
FIRST_RECORD="$(printf '%s' "$FIRST_RESPONSE" | jq -r '.trust.record_ref // empty' 2>/dev/null)"
if [ "$FIRST_STATUS" = "new_trust" ] && [ -n "$FIRST_RECORD" ]; then
  pass "first observation created a new trust record"
else
  fail "first observation response missing new_trust evidence: $FIRST_RESPONSE"
fi
if jq -e '.schema_version == 1 and (.checksum | length > 20) and (.state.records | length == 1)' "$TRUST_PATH" >/dev/null 2>&1; then
  pass "trust store snapshot persisted schema, checksum, and one record"
else
  fail "trust store snapshot missing expected persisted metadata"
fi

ESTABLISHED_NEW_BODY="$(policy_body "$FIRST_RECORD" established_only)" || ESTABLISHED_NEW_BODY=""
ESTABLISHED_NEW_STATUS="$(http_status POST "$BASE_URL/spaces/$SPACE/participants/$SENDER/trust-policy-profile/$RECIPIENT" "$ESTABLISHED_NEW_BODY")"
case "$ESTABLISHED_NEW_STATUS" in
  4*|5*) pass "established_only denied first new_trust record" ;;
  *) fail "established_only new_trust policy returned HTTP $ESTABLISHED_NEW_STATUS" ;;
esac

FRESH_REPORT="$(report_policy_profile "$SENDER" "$RECIPIENT" "$FIRST_RECORD" fresh_30d)" \
  && pass "fresh_30d report-only policy executed through Workflow API" \
  || fail "fresh_30d report-only policy failed"
FRESH_ALLOWED="$(printf '%s' "$FRESH_REPORT" | jq -r '.policy.allowed // empty' 2>/dev/null)"
FRESH_PROFILE="$(printf '%s' "$FRESH_REPORT" | jq -r '.policy.policy_profile // empty' 2>/dev/null)"
if [ "$FRESH_ALLOWED" = "true" ] && [ "$FRESH_PROFILE" = "fresh_30d" ]; then
  pass "fresh_30d profile allowed the fresh first-observed record"
else
  fail "fresh_30d profile did not report expected decision: $FRESH_REPORT"
fi

UNKNOWN_BODY="$(policy_body "$FIRST_RECORD" unsupported_profile)" || UNKNOWN_BODY=""
UNKNOWN_STATUS="$(http_status POST "$BASE_URL/spaces/$SPACE/participants/$SENDER/trust-policy-profile/$RECIPIENT" "$UNKNOWN_BODY")"
case "$UNKNOWN_STATUS" in
  4*|5*) pass "unsupported trust policy profile failed closed" ;;
  *) fail "unsupported trust policy profile returned HTTP $UNKNOWN_STATUS" ;;
esac

PLAINTEXT_TWO="$(printf '%s' "{\"marker\":\"$MESSAGE_MARKER\",\"round\":\"repeat\",\"space\":\"$SPACE\"}" | base64_encode)"
REPEAT_RESPONSE="$(check_trust "$SENDER" "$RECIPIENT" "request://$SPACE/repeat-observe" "$SENDER_BUNDLE" "$RECIPIENT_BUNDLE")" \
  && pass "repeat trust observation executed before reset" \
  || fail "repeat trust observation API failed"
REPEAT_STATUS="$(printf '%s' "$REPEAT_RESPONSE" | jq -r '.trust.status // empty' 2>/dev/null)"
REPEAT_RECORD="$(printf '%s' "$REPEAT_RESPONSE" | jq -r '.trust.record_ref // empty' 2>/dev/null)"
if [ "$REPEAT_STATUS" = "trusted" ] && [ "$REPEAT_RECORD" = "$FIRST_RECORD" ]; then
  pass "existing trust record returned trusted before reset"
else
  fail "repeat trust evidence did not match initial record: $REPEAT_RESPONSE"
fi

ESTABLISHED_RESPONSE="$(check_policy_profile "$SENDER" "$RECIPIENT" "$FIRST_RECORD" established_only)" \
  && pass "established_only allowed the repeated trusted record" \
  || fail "established_only policy failed for repeated trusted record"
ESTABLISHED_ALLOWED="$(printf '%s' "$ESTABLISHED_RESPONSE" | jq -r '.policy.allowed // empty' 2>/dev/null)"
ESTABLISHED_PROFILE="$(printf '%s' "$ESTABLISHED_RESPONSE" | jq -r '.policy.policy_profile // empty' 2>/dev/null)"
if [ "$ESTABLISHED_ALLOWED" = "true" ] && [ "$ESTABLISHED_PROFILE" = "established_only" ]; then
  pass "established_only profile appeared in allowed output"
else
  fail "established_only allowed output missing profile evidence: $ESTABLISHED_RESPONSE"
fi

SEND_RESPONSE="$(send_trusted "$SENDER" "$RECIPIENT" "message-repeat" "$PLAINTEXT_TWO" "$SENDER_BUNDLE" "$RECIPIENT_BUNDLE")" \
  && pass "trusted send passed established_only gate and encrypted through Workflow API" \
  || fail "trusted send failed established_only gate"
SEND_STATUS="$(printf '%s' "$SEND_RESPONSE" | jq -r '.trust.status // empty' 2>/dev/null)"
SEND_POLICY_ALLOWED="$(printf '%s' "$SEND_RESPONSE" | jq -r '.policy.allowed // empty' 2>/dev/null)"
SEND_POLICY_PROFILE="$(printf '%s' "$SEND_RESPONSE" | jq -r '.policy.policy_profile // empty' 2>/dev/null)"
SEND_ENVELOPE_REF="$(printf '%s' "$SEND_RESPONSE" | jq -r '.envelope_ref // empty' 2>/dev/null)"
SEND_CIPHERTEXT="$(printf '%s' "$SEND_RESPONSE" | jq -r '.envelope.ciphertext // empty' 2>/dev/null)"
if [ "$SEND_STATUS" = "trusted" ] && [ "$SEND_POLICY_ALLOWED" = "true" ] &&
   [ "$SEND_POLICY_PROFILE" = "established_only" ] && [ -n "$SEND_ENVELOPE_REF" ] &&
   [ -n "$SEND_CIPHERTEXT" ]; then
  pass "send response contains trust, policy, and encrypted envelope evidence"
else
  fail "send response missing policy/envelope evidence: $SEND_RESPONSE"
fi
if printf '%s' "$SEND_RESPONSE" | grep -Eq "$MESSAGE_MARKER|custody://"; then
  fail "trusted send response exposed plaintext marker or custody ref"
else
  pass "trusted send response does not expose plaintext marker or custody ref"
fi

CHANGED_BODY="$(trusted_send_body "message-changed" "$PLAINTEXT_TWO" "$SENDER_BUNDLE" "$CHANGED_BUNDLE")" || CHANGED_BODY=""
CHANGED_STATUS="$(http_status POST "$BASE_URL/spaces/$SPACE/participants/$SENDER/trusted-send/$RECIPIENT" "$CHANGED_BODY")"
case "$CHANGED_STATUS" in
  4*|5*) pass "changed remote identity key was rejected before send" ;;
  *) fail "changed remote identity key returned HTTP $CHANGED_STATUS" ;;
esac

RECOVERY_RESPONSE="$(send_trusted "$SENDER" "$RECIPIENT" "message-changed" "$PLAINTEXT_TWO" "$SENDER_BUNDLE" "$RECIPIENT_BUNDLE")" \
  && pass "original trusted key reused changed message_ref after rejection" \
  || fail "original trusted key could not reuse changed message_ref after rejection"
RECOVERY_ENVELOPE_REF="$(printf '%s' "$RECOVERY_RESPONSE" | jq -r '.envelope_ref // empty' 2>/dev/null)"
if [ -n "$RECOVERY_ENVELOPE_REF" ] && [ "$RECOVERY_ENVELOPE_REF" != "$SEND_ENVELOPE_REF" ]; then
  pass "changed-key rejection did not consume the outbox idempotency slot"
else
  fail "changed-key rejection appears to have consumed or reused an outbox slot: $RECOVERY_RESPONSE"
fi
if [ "$(jq -r '.state.records | length' "$TRUST_PATH" 2>/dev/null)" = "1" ]; then
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
if [ "$(jq -r '.state.records | length' "$TRUST_PATH" 2>/dev/null)" = "1" ]; then
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

RESET_ONLY_RESPONSE="$(check_policy_profile "$SENDER" "$RECIPIENT" "$RESET_RECORD" reset_only)" \
  && pass "reset_only policy allowed approved reset record" \
  || fail "reset_only policy failed for approved reset record"
RESET_ONLY_ALLOWED="$(printf '%s' "$RESET_ONLY_RESPONSE" | jq -r '.policy.allowed // empty' 2>/dev/null)"
RESET_ONLY_PROFILE="$(printf '%s' "$RESET_ONLY_RESPONSE" | jq -r '.policy.policy_profile // empty' 2>/dev/null)"
if [ "$RESET_ONLY_ALLOWED" = "true" ] && [ "$RESET_ONLY_PROFILE" = "reset_only" ]; then
  pass "reset_only profile appeared in allowed output"
else
  fail "reset_only allowed output missing profile evidence: $RESET_ONLY_RESPONSE"
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

OLD_BODY="$(trust_check_body "request://$SPACE/old-after-reset" "$SENDER_BUNDLE" "$RECIPIENT_BUNDLE")" || OLD_BODY=""
OLD_STATUS="$(http_status POST "$BASE_URL/spaces/$SPACE/participants/$SENDER/trust-check/$RECIPIENT" "$OLD_BODY")"
case "$OLD_STATUS" in
  4*|5*) pass "old remote identity key was rejected after reset" ;;
  *) fail "old remote identity key returned HTTP $OLD_STATUS after reset" ;;
esac
if [ "$(jq -r '.state.records | length' "$TRUST_PATH" 2>/dev/null)" = "1" ] &&
   [ "$(jq -r '.state.records[] .record_ref' "$TRUST_PATH" 2>/dev/null)" = "$RESET_RECORD" ]; then
  pass "trust store snapshot contains only the rotated record"
else
  fail "trust store snapshot does not contain the rotated record"
fi

stop_server
if start_server; then
  pass "workflow server restarted with the reset trust store"
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
if [ "$POST_RESTART_STATUS" = "trusted" ] && [ "$POST_RESTART_RECORD" = "$RESET_RECORD" ]; then
  pass "restart preserved rotated trust record"
else
  fail "post-restart trust evidence did not match rotated record: $POST_RESTART_RESPONSE"
fi

AUDIT_STATUSES="$(jq -r '.status' "$AUDIT_PATH" 2>/dev/null | paste -sd, -)"
case "$AUDIT_STATUSES" in
  *new_trust*trusted*changed*reset*trusted*) pass "audit log recorded new_trust, trusted, changed, reset, and post-reset decisions" ;;
  *) fail "audit log did not record expected trust decisions: $AUDIT_STATUSES" ;;
esac
if jq -e --arg reason "$RESET_REASON" --arg previous "$FIRST_RECORD" --arg current "$RESET_RECORD" '
  select(.status == "reset" and .reason_ref == $reason and .previous_record_ref == $previous and .record_ref == $current)
' "$AUDIT_PATH" >/dev/null 2>&1; then
  pass "audit log recorded reset reason and previous/new refs"
else
  fail "audit log missing reset reason or record refs"
fi
SENDER_KEY="$(printf '%s' "$SENDER_BUNDLE" | jq -r '.identity_key')"
OLD_KEY="$(printf '%s' "$RECIPIENT_BUNDLE" | jq -r '.identity_key')"
NEW_KEY="$(printf '%s' "$CHANGED_BUNDLE" | jq -r '.identity_key')"
if grep -Fq "$SENDER_KEY" "$AUDIT_PATH" || grep -Fq "$OLD_KEY" "$AUDIT_PATH" ||
   grep -Fq "$NEW_KEY" "$AUDIT_PATH" || grep -Fq "$MESSAGE_MARKER" "$AUDIT_PATH"; then
  fail "audit log exposed identity key material or plaintext marker"
else
  pass "audit log contains reset metadata without private key material or plaintext"
fi
if grep -Fq "$MESSAGE_MARKER" "$TRUST_PATH" || grep -Fq "custody://" "$TRUST_PATH" ||
   grep -Fq "$MESSAGE_MARKER" "$AUDIT_PATH" || grep -Fq "custody://" "$AUDIT_PATH"; then
  fail "trust state exposed plaintext marker or custody refs"
else
  pass "trust state avoids plaintext marker and custody refs"
fi

finish
