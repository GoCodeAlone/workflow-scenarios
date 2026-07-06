#!/usr/bin/env bash
# Scenario 127 - Signal transport handoff.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-signal subprocess from data/plugins, starts a scenario-owned
# HTTP transport mock, and drives sender, worker, transport, and recipient
# clients through participant-parametric Workflow API routes.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.31.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
export SIGNAL_TRANSPORT_HMAC="${SIGNAL_TRANSPORT_HMAC:-scenario-127-hmac-secret}"
SENDER="${SENDER:-user-a}"
RECIPIENT="${RECIPIENT:-user-b}"
WORKER="${WORKER:-transport-worker}"
SPACE="${SPACE:-private-space-127}"
PLAINTEXT_B64="${PLAINTEXT_B64:-c2lnbmFsIHRyYW5zcG9ydCBoYW5kb2ZmIHByb29mIDEyNw==}"
MESSAGE_REF="${MESSAGE_REF:-scenario-127-envelope-1}"
TRANSPORT_REF="${TRANSPORT_REF:-transport://scenario/127/mock-http}"
SUBJECT_REF="${SUBJECT_REF:-subject://$SPACE}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18127}"
TRANSPORT_ADDR="${TRANSPORT_ADDR:-127.0.0.1:19127}"
TRANSPORT_URL="http://$TRANSPORT_ADDR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG="$SCENARIO_DIR/config/app.yaml"
BODY_FILE="${TMPDIR:-/tmp}/scenario-127-http-body-$$"

PASS=0
FAIL=0
SERVER_PID=""
TRANSPORT_PID=""
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
  if [ -n "$TRANSPORT_PID" ] && kill -0 "$TRANSPORT_PID" >/dev/null 2>&1; then
    kill "$TRANSPORT_PID" >/dev/null 2>&1 || true
    wait "$TRANSPORT_PID" >/dev/null 2>&1 || true
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

plugin_repo_supports_transport_handoff() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.capabilities.moduleTypes | index("signal.envelope_store")) and
    (.capabilities.stepTypes | index("step.signal_session_prepare")) and
    (.capabilities.stepTypes | index("step.signal_encrypt")) and
    (.capabilities.stepTypes | index("step.signal_outbox_enqueue")) and
    (.capabilities.stepTypes | index("step.signal_outbox_handoff")) and
    (.capabilities.stepTypes | index("step.signal_transport_admit")) and
    (.capabilities.stepTypes | index("step.signal_outbox_ack")) and
    (.capabilities.stepTypes | index("step.signal_inbox_decrypt"))
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
  plugin_repo="$(find_repo "${SIGNAL_PLUGIN_REPO:-}" "$REPO_ROOT/../workflow-plugin-signal" "$REPO_ROOT/../../../workflow-plugin-signal")" || plugin_repo=""
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_transport_handoff "$plugin_repo"; then
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

start_transport() {
  TRANSPORT_LOG="$SCRIPT_DIR/artifacts/last-transport.log"
  TRANSPORT_STATE="$DATA_DIR/transport-state.json"
  TRANSPORT_BIN="$DATA_DIR/signal-transport-mock"
  mkdir -p "$(dirname "$TRANSPORT_LOG")"
  (cd "$SCENARIO_DIR" && GOWORK=off go build -o "$TRANSPORT_BIN" ./mock) >/dev/null 2>&1 || return 1
  "$TRANSPORT_BIN" --addr "$TRANSPORT_ADDR" --path "$TRANSPORT_STATE" >"$TRANSPORT_LOG" 2>&1 &
  TRANSPORT_PID=$!
  wait_for_http "$TRANSPORT_URL/healthz" "$TRANSPORT_PID"
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

transport_post_json() {
  local path="$1"
  local body="$2"
  curl -fsS -X POST "$TRANSPORT_URL$path" -H 'Content-Type: application/json' -d "$body"
}

transport_get_json() {
  local path="$1"
  curl -fsS "$TRANSPORT_URL$path"
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
echo "=== Scenario 127 - Signal Transport Handoff ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if grep -Eiq 'ali''ce|bo''b' "$CONFIG"; then
  fail "Workflow pipelines should not bake fixed demo participant names"
else
  pass "Workflow API is participant-parametric"
fi
for step_type in step.signal_outbox_enqueue step.signal_outbox_handoff step.signal_transport_admit step.signal_outbox_ack step.signal_inbox_decrypt; do
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
if build_plugin "$PLUGIN_DIR"; then
  pass "built workflow-plugin-signal v$PLUGIN_VERSION external plugin"
else
  fail "could not build workflow-plugin-signal v$PLUGIN_VERSION; set SIGNAL_PLUGIN_REPO"
  finish
  exit 1
fi

if start_transport; then
  pass "scenario-owned HTTP transport mock started"
else
  fail "transport mock did not become ready; see $TRANSPORT_LOG"
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

HANDOFF_BODY="$(jq -cn \
  --arg envelope_ref "$ENVELOPE_REF" \
  --arg lease_id "scenario-127-lease-1" \
  --arg transport_ref "$TRANSPORT_REF" \
  --arg subject_ref "$SUBJECT_REF" \
  --arg delivery_id "delivery://scenario-127/$MESSAGE_REF" \
  '{envelope_ref:$envelope_ref,lease_id:$lease_id,transport_ref:$transport_ref,subject_ref:$subject_ref,delivery_id:$delivery_id,requested_at_unix:1000,expires_at_unix:2000}')"
HANDED_OFF="$(post_json "/workers/$WORKER/outbox/handoff" "$HANDOFF_BODY")" \
  && pass "worker handed off queued envelope through Workflow API" \
  || fail "worker handoff API failed"
LEASE_REF="$(printf '%s' "$HANDED_OFF" | jq -r '.lease_ref // empty' 2>/dev/null)"
DELIVERY_REF="$(printf '%s' "$HANDED_OFF" | jq -r '.delivery_ref // empty' 2>/dev/null)"
TRANSPORT_PAYLOAD="$(printf '%s' "$HANDED_OFF" | jq -r '.transport_payload_json // empty' 2>/dev/null)"
[ -n "$LEASE_REF" ] && pass "handoff returned lease ref" || fail "handoff did not return lease ref: $HANDED_OFF"
[ -n "$DELIVERY_REF" ] && pass "handoff returned delivery ref" || fail "handoff did not return delivery ref: $HANDED_OFF"
[ "$(printf '%s' "$HANDED_OFF" | jq -r '.status // empty' 2>/dev/null)" = "claimed" ] && pass "handoff claimed the outbox envelope" || fail "handoff returned unexpected status: $HANDED_OFF"
[ -n "$TRANSPORT_PAYLOAD" ] && printf '%s' "$TRANSPORT_PAYLOAD" | jq -e . >/dev/null 2>&1 && pass "handoff produced JSON transport payload" || fail "handoff payload was not JSON: $HANDED_OFF"
[ "$(printf '%s' "$TRANSPORT_PAYLOAD" | jq -r '.transport_ref // empty' 2>/dev/null)" = "$TRANSPORT_REF" ] && pass "transport payload carried expected transport ref" || fail "transport payload had wrong transport ref: $TRANSPORT_PAYLOAD"
[ "$(printf '%s' "$TRANSPORT_PAYLOAD" | jq -r '.subject_ref // empty' 2>/dev/null)" = "$SUBJECT_REF" ] && pass "transport payload carried expected subject ref" || fail "transport payload had wrong subject ref: $TRANSPORT_PAYLOAD"
[ -n "$(printf '%s' "$TRANSPORT_PAYLOAD" | jq -r '.payload_mac // empty' 2>/dev/null)" ] && pass "transport payload carried HMAC integrity metadata" || fail "transport payload omitted payload_mac: $TRANSPORT_PAYLOAD"
assert_no_marker "transport payload" "$TRANSPORT_PAYLOAD" "$PLAINTEXT_B64"
assert_no_marker "transport payload" "$TRANSPORT_PAYLOAD" "$SIGNAL_TRANSPORT_HMAC"
assert_no_marker "transport payload" "$TRANSPORT_PAYLOAD" "custody://"

PUBLISH_BODY="$(jq -cn --arg id "$DELIVERY_REF" --arg recipient_ref "participant://$RECIPIENT" --arg payload "$TRANSPORT_PAYLOAD" \
  '{id:$id,recipient_ref:$recipient_ref,transport_payload_json:$payload}')"
transport_post_json "/publish" "$PUBLISH_BODY" >/dev/null \
  && pass "transport mock accepted ciphertext-only payload" \
  || fail "transport mock publish failed"

FETCHED="$(transport_get_json "/fetch?recipient_ref=participant://$RECIPIENT")" \
  && pass "recipient fetched transport payload from mock transport" \
  || fail "transport mock fetch failed"
FETCHED_PAYLOAD="$(printf '%s' "$FETCHED" | jq -r '.transport_payload_json // empty' 2>/dev/null)"
[ "$FETCHED_PAYLOAD" = "$TRANSPORT_PAYLOAD" ] && pass "transport mock preserved payload byte-for-byte" || fail "transport mock changed payload: $FETCHED"

ADMIT_BODY="$(jq -cn --arg payload "$FETCHED_PAYLOAD" --arg transport_ref "$TRANSPORT_REF" --arg subject_ref "$SUBJECT_REF" \
  '{transport_payload_json:$payload,transport_ref:$transport_ref,subject_ref:$subject_ref,requested_at_unix:1001,idempotency_key:"scenario-127-admit-1"}')"
ADMITTED="$(post_json "/participants/$RECIPIENT/transport/admit" "$ADMIT_BODY")" \
  && pass "recipient admitted transport payload through Workflow API" \
  || fail "recipient transport admit API failed"
[ "$(printf '%s' "$ADMITTED" | jq -r '.status // empty' 2>/dev/null)" = "received" ] && pass "admit wrote recipient inbox entry" || fail "admit returned unexpected status: $ADMITTED"
[ "$(printf '%s' "$ADMITTED" | jq -r '.recipient_ref // empty' 2>/dev/null)" = "participant://$RECIPIENT" ] && pass "admit bound payload to recipient route param" || fail "admit returned wrong recipient: $ADMITTED"

ACK_BODY="$(jq -cn --arg envelope_ref "$ENVELOPE_REF" --arg lease_ref "$LEASE_REF" \
  '{envelope_ref:$envelope_ref,lease_ref:$lease_ref}')"
ACKED="$(post_json "/workers/$WORKER/outbox/ack" "$ACK_BODY")" \
  && pass "worker acked handed-off envelope after recipient admit" \
  || fail "worker ack API failed"
[ "$(printf '%s' "$ACKED" | jq -r '.status // empty' 2>/dev/null)" = "acked" ] && pass "ack returned terminal acked status" || fail "ack returned unexpected status: $ACKED"
transport_post_json "/ack?id=$DELIVERY_REF" '{}' >/dev/null \
  && pass "transport mock marked delivery acked" \
  || fail "transport mock ack failed"

DECRYPT_BODY="$(jq -cn --arg envelope_ref "$ENVELOPE_REF" '{envelope_ref:$envelope_ref}')"
DECRYPTED="$(post_json "/participants/$RECIPIENT/inbox/decrypt" "$DECRYPT_BODY")" \
  && pass "recipient decrypted admitted envelope through Workflow API" \
  || fail "recipient decrypt API failed"
[ "$(printf '%s' "$DECRYPTED" | jq -r '.plaintext // empty' 2>/dev/null)" = "$PLAINTEXT_B64" ] && pass "recipient recovered original plaintext" || fail "recipient plaintext mismatch: $DECRYPTED"

TRANSPORT_STATE_JSON="$(transport_get_json "/state")"
assert_no_marker "transport mock state" "$TRANSPORT_STATE_JSON" "$PLAINTEXT_B64"
assert_no_marker "transport mock state" "$TRANSPORT_STATE_JSON" "$SIGNAL_TRANSPORT_HMAC"
assert_no_marker "transport mock state" "$TRANSPORT_STATE_JSON" "custody://"
DUP_ACK_STATUS="$(post_status "/workers/$WORKER/outbox/ack" "$ACK_BODY")"
[ "$DUP_ACK_STATUS" != "200" ] && pass "duplicate outbox ack was rejected" || fail "duplicate outbox ack unexpectedly succeeded: $(cat "$BODY_FILE")"

finish
