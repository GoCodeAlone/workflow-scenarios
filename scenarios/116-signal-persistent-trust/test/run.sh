#!/usr/bin/env bash
# Scenario 116 - Signal persistent trust.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-signal subprocess from data/plugins, and drives
# participant-parametric HTTP routes that execute signal.trust_store and
# step.signal_trust_observe before encryption and outbox enqueue.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.22.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
SENDER="${SENDER:-user-a}"
RECIPIENT="${RECIPIENT:-user-b}"
CHANGED_RECIPIENT="${CHANGED_RECIPIENT:-user-c}"
SPACE="${SPACE:-private-space-116}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18116}"
MESSAGE_MARKER="${MESSAGE_MARKER:-signal-persistent-trust-secret-116}"

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
echo "=== Scenario 116 - Signal Persistent Trust ==="
echo ""

[ -f "$CONFIG_TEMPLATE" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if [ ! -f "$CONFIG_TEMPLATE" ]; then
  finish
  exit 1
fi
if grep -Eiq 'alice|bob' "$CONFIG_TEMPLATE"; then
  fail "Workflow pipelines should not hard-code Alice/Bob participant names"
else
  pass "Workflow API is participant-parametric"
fi
for required in "type: signal.trust_store" "type: step.signal_trust_observe" "type: step.signal_encrypt" "type: step.signal_outbox_enqueue"; do
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

PLAINTEXT_ONE="$(printf '%s' "{\"marker\":\"$MESSAGE_MARKER\",\"round\":\"first\",\"space\":\"$SPACE\"}" | base64_encode)"
FIRST_RESPONSE="$(send_trusted "$SENDER" "$RECIPIENT" "message-first" "$PLAINTEXT_ONE" "$SENDER_BUNDLE" "$RECIPIENT_BUNDLE")" \
  && pass "first trusted send executed through Workflow API" \
  || fail "first trusted send API failed"
FIRST_STATUS="$(printf '%s' "$FIRST_RESPONSE" | jq -r '.trust.status // empty' 2>/dev/null)"
FIRST_RECORD="$(printf '%s' "$FIRST_RESPONSE" | jq -r '.trust.record_ref // empty' 2>/dev/null)"
FIRST_ENVELOPE_REF="$(printf '%s' "$FIRST_RESPONSE" | jq -r '.envelope_ref // empty' 2>/dev/null)"
FIRST_CIPHERTEXT="$(printf '%s' "$FIRST_RESPONSE" | jq -r '.envelope.ciphertext // empty' 2>/dev/null)"
if [ "$FIRST_STATUS" = "new_trust" ] && [ -n "$FIRST_RECORD" ] && [ -n "$FIRST_ENVELOPE_REF" ] && [ -n "$FIRST_CIPHERTEXT" ]; then
  pass "first trusted send created trust and queued encrypted envelope"
else
  fail "first trusted send response missing trust/envelope evidence: $FIRST_RESPONSE"
fi
if printf '%s' "$FIRST_RESPONSE" | grep -Fq "$MESSAGE_MARKER"; then
  fail "first trusted send response exposed plaintext marker"
else
  pass "first trusted send response does not expose plaintext marker"
fi
if jq -e '.schema_version == 1 and (.checksum | length > 20) and (.state.records | length == 1)' "$TRUST_PATH" >/dev/null 2>&1; then
  pass "trust store snapshot persisted schema, checksum, and one record"
else
  fail "trust store snapshot missing expected persisted metadata"
fi

stop_server
if start_server; then
  pass "workflow server restarted with the same trust store"
else
  fail "workflow server did not restart; see $SERVER_LOG"
  finish
  exit 1
fi

PLAINTEXT_TWO="$(printf '%s' "{\"marker\":\"$MESSAGE_MARKER\",\"round\":\"repeat\",\"space\":\"$SPACE\"}" | base64_encode)"
REPEAT_RESPONSE="$(send_trusted "$SENDER" "$RECIPIENT" "message-repeat" "$PLAINTEXT_TWO" "$SENDER_BUNDLE" "$RECIPIENT_BUNDLE")" \
  && pass "repeat trusted send executed after restart" \
  || fail "repeat trusted send API failed"
REPEAT_STATUS="$(printf '%s' "$REPEAT_RESPONSE" | jq -r '.trust.status // empty' 2>/dev/null)"
REPEAT_RECORD="$(printf '%s' "$REPEAT_RESPONSE" | jq -r '.trust.record_ref // empty' 2>/dev/null)"
if [ "$REPEAT_STATUS" = "trusted" ] && [ "$REPEAT_RECORD" = "$FIRST_RECORD" ]; then
  pass "restart preserved trust record and returned trusted"
else
  fail "repeat trust evidence did not match persisted record: $REPEAT_RESPONSE"
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
if [ -n "$RECOVERY_ENVELOPE_REF" ] && [ "$RECOVERY_ENVELOPE_REF" != "$FIRST_ENVELOPE_REF" ]; then
  pass "changed-key rejection did not consume the outbox idempotency slot"
else
  fail "changed-key rejection appears to have consumed or reused an outbox slot: $RECOVERY_RESPONSE"
fi
if [ "$(jq -r '.state.records | length' "$TRUST_PATH" 2>/dev/null)" = "1" ]; then
  pass "changed-key rejection did not mutate trust records"
else
  fail "changed-key rejection mutated trust records"
fi
AUDIT_STATUSES="$(jq -r '.status' "$AUDIT_PATH" 2>/dev/null | paste -sd, -)"
case "$AUDIT_STATUSES" in
  *new_trust*trusted*changed*) pass "audit log recorded new_trust, trusted, and changed decisions" ;;
  *) fail "audit log did not record expected trust decisions: $AUDIT_STATUSES" ;;
esac

finish
