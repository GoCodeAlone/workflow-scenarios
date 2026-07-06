#!/usr/bin/env bash
# Scenario 137 - Signal transport receipts.
#
# Demonstration-fidelity: this starts the real Workflow server, builds/loads real
# workflow-plugin-signal and workflow-plugin-eventbus subprocesses from a
# scenario-local plugin directory, starts a scenario-owned embedded NATS/JetStream
# fixture, and drives sender, worker, and recipient clients through
# participant-parametric Workflow API routes.
set -uo pipefail
export LC_ALL=C
export LANG=C

SIGNAL_PLUGIN_NAME="workflow-plugin-signal"
EVENTBUS_PLUGIN_NAME="workflow-plugin-eventbus"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.35.1}"
EVENTBUS_PLUGIN_REF="${EVENTBUS_PLUGIN_REF:-v0.3.8}"
if [ -z "${SIGNAL_PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) SIGNAL_PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) SIGNAL_PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
if [ -z "${EVENTBUS_PLUGIN_VERSION:-}" ]; then
  case "$EVENTBUS_PLUGIN_REF" in
    v[0-9]*) EVENTBUS_PLUGIN_VERSION="${EVENTBUS_PLUGIN_REF#v}" ;;
    *) EVENTBUS_PLUGIN_VERSION="$EVENTBUS_PLUGIN_REF" ;;
  esac
fi

export SIGNAL_TRANSPORT_HMAC="${SIGNAL_TRANSPORT_HMAC:-scenario-137-hmac-secret}"
SENDER="${SENDER:-user-a}"
RECIPIENT="${RECIPIENT:-user-b}"
WORKER="${WORKER:-signal-transport-worker}"
SPACE="${SPACE:-private-space-137}"
PLAINTEXT_B64="${PLAINTEXT_B64:-c2lnbmFsIHRyYW5zcG9ydCByZWNlaXB0cyBwcm9vZiAxMzc=}"
MESSAGE_REF="${MESSAGE_REF:-scenario-137-envelope-1}"
TRANSPORT_REF="${TRANSPORT_REF:-transport://scenario/137/eventbus}"
SUBJECT_REF="${SUBJECT_REF:-subject://$SPACE}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18137}"
NATS_ADDR="${NATS_ADDR:-127.0.0.1:19137}"
NATS_HEALTH_ADDR="${NATS_HEALTH_ADDR:-127.0.0.1:19138}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG="$SCENARIO_DIR/config/app.yaml"
BODY_FILE="${TMPDIR:-/tmp}/scenario-137-http-body-$$"

PASS=0
FAIL=0
SERVER_PID=""
NATS_PID=""
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
  if [ -n "$NATS_PID" ] && kill -0 "$NATS_PID" >/dev/null 2>&1; then
    kill "$NATS_PID" >/dev/null 2>&1 || true
    wait "$NATS_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$BODY_FILE"
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

signal_repo_supports_eventbus_transport() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.capabilities.moduleTypes | index("signal.envelope_store")) and
    (.capabilities.stepTypes | index("step.signal_session_prepare")) and
    (.capabilities.stepTypes | index("step.signal_encrypt")) and
    (.capabilities.stepTypes | index("step.signal_outbox_enqueue")) and
    (.capabilities.stepTypes | index("step.signal_outbox_handoff")) and
    (.capabilities.stepTypes | index("step.signal_transport_admit")) and
    (.capabilities.stepTypes | index("step.signal_transport_receipt_issue")) and
    (.capabilities.stepTypes | index("step.signal_transport_receipt_verify")) and
    (.capabilities.stepTypes | index("step.signal_outbox_ack")) and
    (.capabilities.stepTypes | index("step.signal_inbox_decrypt"))
  ' "$repo/plugin.json" >/dev/null 2>&1
}

eventbus_repo_supports_transport() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.capabilities.moduleTypes | index("eventbus.broker")) and
    (.capabilities.moduleTypes | index("eventbus.stream")) and
    (.capabilities.moduleTypes | index("eventbus.consumer")) and
    (.capabilities.stepTypes | index("step.eventbus.publish")) and
    (.capabilities.stepTypes | index("step.eventbus.consume")) and
    (.capabilities.stepTypes | index("step.eventbus.ack"))
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

clone_or_checkout_plugin() {
  local repo_url="$1"
  local ref="$2"
  local target="$3"
  mkdir -p "$(dirname "$target")" || return 1
  if git ls-remote --exit-code --tags "$repo_url" "refs/tags/$ref" >/dev/null 2>&1; then
    git clone --quiet --depth 1 "$repo_url" "$target" || return 1
    git -C "$target" fetch --quiet --depth 1 origin "refs/tags/$ref:refs/tags/$ref" || return 1
    git -C "$target" -c advice.detachedHead=false checkout --quiet "$ref^{commit}" || return 1
  else
    git clone --quiet --depth 1 --branch "$ref" "$repo_url" "$target" || return 1
  fi
}

build_signal_plugin() {
  local plugin_dir="$1"
  local plugin_repo
  if [ -n "${SIGNAL_PLUGIN_REPO:-}" ] && [ ! -d "$SIGNAL_PLUGIN_REPO" ]; then
    echo "SIGNAL_PLUGIN_REPO is set but is not a directory: $SIGNAL_PLUGIN_REPO" >&2
    return 1
  fi
  plugin_repo="$(find_repo "${SIGNAL_PLUGIN_REPO:-}")" || plugin_repo=""
  if [ -z "$plugin_repo" ] || ! signal_repo_supports_eventbus_transport "$plugin_repo"; then
    plugin_repo="$DATA_DIR/repos/workflow-plugin-signal"
    clone_or_checkout_plugin https://github.com/GoCodeAlone/workflow-plugin-signal.git "$SIGNAL_PLUGIN_REF" "$plugin_repo" || return 1
  fi

  mkdir -p "$plugin_dir/$SIGNAL_PLUGIN_NAME" || return 1
  cp "$plugin_repo/plugin.json" "$plugin_dir/$SIGNAL_PLUGIN_NAME/plugin.json" || return 1
  (cd "$plugin_repo" && GOWORK=off go build \
    -ldflags "-X github.com/GoCodeAlone/workflow-plugin-signal/internal.Version=${SIGNAL_PLUGIN_VERSION}" \
    -o "$plugin_dir/$SIGNAL_PLUGIN_NAME/$SIGNAL_PLUGIN_NAME" ./cmd/workflow-plugin-signal) >/dev/null 2>&1 || return 1
}

build_eventbus_plugin() {
  local plugin_dir="$1"
  local plugin_repo
  if [ -n "${EVENTBUS_PLUGIN_REPO:-}" ] && [ ! -d "$EVENTBUS_PLUGIN_REPO" ]; then
    echo "EVENTBUS_PLUGIN_REPO is set but is not a directory: $EVENTBUS_PLUGIN_REPO" >&2
    return 1
  fi
  plugin_repo="$(find_repo "${EVENTBUS_PLUGIN_REPO:-}")" || plugin_repo=""
  if [ -z "$plugin_repo" ] || ! eventbus_repo_supports_transport "$plugin_repo"; then
    plugin_repo="$DATA_DIR/repos/workflow-plugin-eventbus"
    clone_or_checkout_plugin https://github.com/GoCodeAlone/workflow-plugin-eventbus.git "$EVENTBUS_PLUGIN_REF" "$plugin_repo" || return 1
  fi

  mkdir -p "$plugin_dir/$EVENTBUS_PLUGIN_NAME" || return 1
  cp "$plugin_repo/plugin.json" "$plugin_dir/$EVENTBUS_PLUGIN_NAME/plugin.json" || return 1
  (cd "$plugin_repo" && GOWORK=off go build \
    -ldflags "-X main.Version=${EVENTBUS_PLUGIN_VERSION}" \
    -o "$plugin_dir/$EVENTBUS_PLUGIN_NAME/$EVENTBUS_PLUGIN_NAME" ./cmd/workflow-plugin-eventbus) >/dev/null 2>&1 || return 1
}

wait_for_http() {
  local url="$1"
  local pid="$2"
  local i
  for i in $(seq 1 80); do
    curl -fs "$url" >/dev/null 2>&1 && return 0
    if [ -n "$pid" ] && ! kill -0 "$pid" >/dev/null 2>&1; then
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
  wait_for_http "$BASE_URL/healthz" "$SERVER_PID"
}

start_nats() {
  NATS_LOG="$SCRIPT_DIR/artifacts/last-nats.log"
  NATS_BIN="$DATA_DIR/scenario-nats"
  NATS_STORE="$DATA_DIR/nats-store"
  mkdir -p "$(dirname "$NATS_LOG")" "$NATS_STORE"
  (cd "$SCENARIO_DIR/fixture" && GOWORK=off go build -o "$NATS_BIN" .) >/dev/null 2>&1 || return 1
  "$NATS_BIN" --addr "$NATS_ADDR" --health-addr "$NATS_HEALTH_ADDR" --store "$NATS_STORE" >"$NATS_LOG" 2>&1 &
  NATS_PID=$!
  wait_for_http "http://$NATS_HEALTH_ADDR/healthz" "$NATS_PID"
}

post_json() {
  local path="$1"
  local body="$2"
  curl -fsS -X POST "$BASE_URL$path" -H 'Content-Type: application/json' -d "$body"
}

post_status() {
  local path="$1"
  local body="$2"
  curl -sS -o "$BODY_FILE" -w "%{http_code}" \
    -X POST "$BASE_URL$path" -H 'Content-Type: application/json' -d "$body"
}

assert_no_marker() {
  local label="$1"
  local value="$2"
  local marker="$3"
  if printf '%s' "$value" | grep -Fq "$marker"; then
    fail "$label leaked marker $marker"
  else
    pass "$label did not leak marker $marker"
  fi
}

echo ""
echo "=== Scenario 137 - Signal Transport Receipts ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if grep -Eiq 'ali''ce|bo''b' "$CONFIG"; then
  fail "Workflow pipelines should not bake fixed demo participant names"
else
  pass "Workflow API is participant-parametric"
fi
for step_type in step.signal_outbox_enqueue step.signal_outbox_handoff step.eventbus.publish step.eventbus.consume step.signal_transport_admit step.signal_transport_receipt_issue step.signal_transport_receipt_verify step.signal_outbox_ack step.eventbus.ack step.signal_inbox_decrypt; do
  if grep -q "type: $step_type" "$CONFIG"; then
    pass "Workflow app config exercises $step_type"
  else
    fail "Workflow app config does not exercise $step_type"
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
if build_signal_plugin "$PLUGIN_DIR"; then
  pass "built workflow-plugin-signal v$SIGNAL_PLUGIN_VERSION external plugin"
else
  fail "could not build workflow-plugin-signal v$SIGNAL_PLUGIN_VERSION; set SIGNAL_PLUGIN_REPO"
  finish
  exit 1
fi
if build_eventbus_plugin "$PLUGIN_DIR"; then
  pass "built workflow-plugin-eventbus v$EVENTBUS_PLUGIN_VERSION external plugin"
else
  fail "could not build workflow-plugin-eventbus v$EVENTBUS_PLUGIN_VERSION; set EVENTBUS_PLUGIN_REPO"
  finish
  exit 1
fi

if start_nats; then
  pass "scenario-owned embedded NATS/JetStream fixture started"
else
  fail "embedded NATS fixture did not become ready; see $NATS_LOG"
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

SESSION_RECIPIENT="$(post_json "/participants/$RECIPIENT/session" '{}')" \
  && pass "recipient published a pre-key bundle via Workflow API" \
  || fail "recipient session prepare API failed"
RECIPIENT_BUNDLE="$(printf '%s' "$SESSION_RECIPIENT" | jq -c '.bundle // empty' 2>/dev/null)"
[ -n "$RECIPIENT_BUNDLE" ] && [ "$RECIPIENT_BUNDLE" != "null" ] && pass "recipient response contained a bundle" || fail "recipient response did not contain a bundle: $SESSION_RECIPIENT"

SESSION_SENDER="$(post_json "/participants/$SENDER/session" '{}')" \
  && pass "sender published a pre-key bundle via Workflow API" \
  || fail "sender session prepare API failed"
SENDER_BUNDLE="$(printf '%s' "$SESSION_SENDER" | jq -c '.bundle // empty' 2>/dev/null)"
[ -n "$SENDER_BUNDLE" ] && [ "$SENDER_BUNDLE" != "null" ] && pass "sender response contained a bundle" || fail "sender response did not contain a bundle: $SESSION_SENDER"

SEND_BODY="$(jq -cn --arg plaintext "$PLAINTEXT_B64" --arg message_ref "$MESSAGE_REF" --argjson remote_bundle "$RECIPIENT_BUNDLE" \
  '{plaintext:$plaintext,message_ref:$message_ref,remote_bundle:$remote_bundle}')"
SENT="$(post_json "/spaces/$SPACE/participants/$SENDER/outbox/$RECIPIENT" "$SEND_BODY")" \
  && pass "sender enqueued encrypted envelope through Workflow API" \
  || fail "sender enqueue API failed"
ENVELOPE_REF="$(printf '%s' "$SENT" | jq -r '.envelope_ref // empty' 2>/dev/null)"
[ -n "$ENVELOPE_REF" ] && pass "send returned envelope ref" || fail "send did not return envelope ref: $SENT"
[ "$(printf '%s' "$SENT" | jq -r '.status // empty' 2>/dev/null)" = "queued" ] && pass "send returned queued status" || fail "send returned unexpected status: $SENT"
assert_no_marker "send response" "$SENT" "$PLAINTEXT_B64"
assert_no_marker "send response" "$SENT" "$SIGNAL_TRANSPORT_HMAC"
assert_no_marker "send response" "$SENT" "custody://"

HANDOFF_BODY="$(jq -cn \
  --arg envelope_ref "$ENVELOPE_REF" \
  --arg lease_id "scenario-137-lease-1" \
  --arg transport_ref "$TRANSPORT_REF" \
  --arg subject_ref "$SUBJECT_REF" \
  --arg space "$SPACE" \
  --arg delivery_id "delivery://scenario-137/$MESSAGE_REF" \
  '{envelope_ref:$envelope_ref,lease_id:$lease_id,transport_ref:$transport_ref,subject_ref:$subject_ref,space:$space,delivery_id:$delivery_id,requested_at_unix:1000,expires_at_unix:2000}')"
HANDED_OFF="$(post_json "/workers/$WORKER/outbox/handoff" "$HANDOFF_BODY")" \
  && pass "worker handed off queued envelope and published eventbus message through Workflow API" \
  || fail "worker handoff/eventbus publish API failed"
LEASE_REF="$(printf '%s' "$HANDED_OFF" | jq -r '.lease_ref // empty' 2>/dev/null)"
DELIVERY_REF="$(printf '%s' "$HANDED_OFF" | jq -r '.delivery_ref // empty' 2>/dev/null)"
EVENT_SEQUENCE="$(printf '%s' "$HANDED_OFF" | jq -r '.eventbus_sequence // empty' 2>/dev/null)"
[ -n "$LEASE_REF" ] && pass "handoff returned lease ref" || fail "handoff did not return lease ref: $HANDED_OFF"
[ -n "$DELIVERY_REF" ] && pass "handoff returned delivery ref" || fail "handoff did not return delivery ref: $HANDED_OFF"
[ "$(printf '%s' "$HANDED_OFF" | jq -r '.status // empty' 2>/dev/null)" = "claimed" ] && pass "handoff claimed the outbox envelope" || fail "handoff returned unexpected status: $HANDED_OFF"
[ -n "$EVENT_SEQUENCE" ] && pass "eventbus publish returned stream sequence" || fail "eventbus publish omitted sequence: $HANDED_OFF"
assert_no_marker "handoff response" "$HANDED_OFF" "$PLAINTEXT_B64"
assert_no_marker "handoff response" "$HANDED_OFF" "$SIGNAL_TRANSPORT_HMAC"
assert_no_marker "handoff response" "$HANDED_OFF" "custody://"

RECEIVED="$(post_json "/workers/$WORKER/eventbus/receive" '{}')" \
  && pass "worker consumed eventbus message, admitted Signal payload, and acked both systems through Workflow API" \
  || fail "worker eventbus receive/admit/ack API failed"
[ "$(printf '%s' "$RECEIVED" | jq -r '.signal_ack_status // empty' 2>/dev/null)" = "acked" ] && pass "Signal outbox ack returned terminal status" || fail "Signal ack returned unexpected status: $RECEIVED"
[ "$(printf '%s' "$RECEIVED" | jq -r '.receipt_verified // false' 2>/dev/null)" = "true" ] && pass "transport receipt verified before outbox ack" || fail "receipt verification missing: $RECEIVED"
[ "$(printf '%s' "$RECEIVED" | jq -r '.receipt_status // empty' 2>/dev/null)" = "received" ] && pass "transport receipt carried received status" || fail "receipt status mismatch: $RECEIVED"
[ -n "$(printf '%s' "$RECEIVED" | jq -r '.receipt_ref // empty' 2>/dev/null)" ] && pass "transport receipt returned receipt ref" || fail "receipt ref missing: $RECEIVED"
[ "$(printf '%s' "$RECEIVED" | jq -r '.recipient_ref // empty' 2>/dev/null)" = "participant://$RECIPIENT" ] && pass "admit bound payload to recipient from transport payload" || fail "admit returned wrong recipient: $RECEIVED"
[ -n "$(printf '%s' "$RECEIVED" | jq -r '.event_ack_token // empty' 2>/dev/null)" ] && pass "eventbus consume returned ack token" || fail "eventbus consume omitted ack token: $RECEIVED"
assert_no_marker "eventbus receive response" "$RECEIVED" "$PLAINTEXT_B64"
assert_no_marker "eventbus receive response" "$RECEIVED" "$SIGNAL_TRANSPORT_HMAC"
RECEIPT_JSON="$(printf '%s' "$RECEIVED" | jq -r '.receipt_json // empty' 2>/dev/null)"
TRANSPORT_PAYLOAD_JSON="$(printf '%s' "$RECEIVED" | jq -r '.transport_payload_json // empty' 2>/dev/null)"
[ -n "$RECEIPT_JSON" ] && [ -n "$TRANSPORT_PAYLOAD_JSON" ] && pass "receipt proof material returned for replay check" || fail "receipt proof material missing: $RECEIVED"
REPLAY_CODE="$(post_status "/workers/$WORKER/transport/receipt/verify" "$(jq -cn \
  --arg receipt_json "$RECEIPT_JSON" \
  --arg transport_payload_json "$TRANSPORT_PAYLOAD_JSON" \
  --arg transport_ref "$TRANSPORT_REF" \
  --arg subject_ref "$SUBJECT_REF" \
  --arg recipient_ref "participant://$RECIPIENT" \
  --arg envelope_ref "$ENVELOPE_REF" \
  '{receipt_json:$receipt_json,transport_payload_json:$transport_payload_json,expected_transport_ref:$transport_ref,expected_subject_ref:$subject_ref,expected_recipient_ref:$recipient_ref,expected_envelope_ref:$envelope_ref,requested_at_unix:1004}')")"
[ "$REPLAY_CODE" != "200" ] && pass "duplicate receipt verification was rejected by replay cache" || fail "duplicate receipt verify unexpectedly succeeded: $(cat "$BODY_FILE")"
assert_no_marker "eventbus receive response" "$RECEIVED" "custody://"

DECRYPT_BODY="$(jq -cn --arg envelope_ref "$ENVELOPE_REF" '{envelope_ref:$envelope_ref}')"
DECRYPTED="$(post_json "/participants/$RECIPIENT/inbox/decrypt" "$DECRYPT_BODY")" \
  && pass "recipient decrypted admitted envelope through Workflow API" \
  || fail "recipient decrypt API failed"
[ "$(printf '%s' "$DECRYPTED" | jq -r '.plaintext // empty' 2>/dev/null)" = "$PLAINTEXT_B64" ] && pass "recipient recovered original plaintext" || fail "recipient plaintext mismatch: $DECRYPTED"
assert_no_marker "recipient decrypt response" "$DECRYPTED" "$SIGNAL_TRANSPORT_HMAC"
assert_no_marker "recipient decrypt response" "$DECRYPTED" "custody://"

DUP_ACK_STATUS="$(post_status "/workers/$WORKER/outbox/ack" "$(jq -cn --arg envelope_ref "$ENVELOPE_REF" --arg lease_ref "$LEASE_REF" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref}')")"
[ "$DUP_ACK_STATUS" != "200" ] && pass "duplicate outbox ack was rejected" || fail "duplicate outbox ack unexpectedly succeeded: $(cat "$BODY_FILE")"

EMPTY_RECEIVE="$(post_json "/workers/$WORKER/eventbus/receive" '{}' 2>/dev/null)" && EMPTY_STATUS=0 || EMPTY_STATUS=$?
[ "$EMPTY_STATUS" -ne 0 ] && pass "second eventbus receive found no unacked message" || fail "second eventbus receive unexpectedly succeeded: $EMPTY_RECEIVE"

finish
