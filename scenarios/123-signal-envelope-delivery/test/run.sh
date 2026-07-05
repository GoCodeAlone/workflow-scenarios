#!/usr/bin/env bash
# Scenario 123 - Signal envelope delivery lifecycle.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-signal subprocess from data/plugins, and drives separate
# sender, worker, and recipient HTTP clients through participant-parametric API
# routes. The worker sees ciphertext and refs only.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.29.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
SENDER="${SENDER:-user-a}"
RECIPIENT="${RECIPIENT:-user-b}"
WORKER="${WORKER:-delivery-worker}"
SPACE="${SPACE:-private-space-123}"
PLAINTEXT_B64="${PLAINTEXT_B64:-c2lnbmFsIGVudmVsb3BlIGxpZmVjeWNsZSBwcm9vZiAxMjM=}"
MESSAGE_REF="${MESSAGE_REF:-scenario-123-envelope-1}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18123}"

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

plugin_repo_supports_envelope_lifecycle() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.capabilities.moduleTypes | index("signal.envelope_store")) and
    (.capabilities.stepTypes | index("step.signal_session_prepare")) and
    (.capabilities.stepTypes | index("step.signal_encrypt")) and
    (.capabilities.stepTypes | index("step.signal_outbox_enqueue")) and
    (.capabilities.stepTypes | index("step.signal_outbox_claim")) and
    (.capabilities.stepTypes | index("step.signal_outbox_release")) and
    (.capabilities.stepTypes | index("step.signal_outbox_ack")) and
    (.capabilities.stepTypes | index("step.signal_inbox_receive")) and
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
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_envelope_lifecycle "$plugin_repo"; then
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

post_json() {
  local path="$1"
  local body="$2"
  curl -fsS -X POST "$BASE_URL$path" -H 'Content-Type: application/json' -d "$body"
}

post_status() {
  local path="$1"
  local body="$2"
  curl -sS -o /tmp/scenario-123-http-body -w "%{http_code}" \
    -X POST "$BASE_URL$path" -H 'Content-Type: application/json' -d "$body"
}

echo ""
echo "=== Scenario 123 - Signal Envelope Delivery ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if grep -Eiq 'ali''ce|bo''b' "$CONFIG"; then
  fail "Workflow pipelines should not bake fixed demo participant names"
else
  pass "Workflow API is participant-parametric"
fi
for step_type in step.signal_outbox_enqueue step.signal_outbox_claim step.signal_outbox_release step.signal_outbox_ack step.signal_inbox_receive step.signal_inbox_decrypt; do
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
if printf '%s' "$SENT" | grep -q "$PLAINTEXT_B64"; then
  fail "send response leaked plaintext"
else
  pass "send response exposed refs only"
fi

CLAIM_BODY="$(jq -cn --arg envelope_ref "$ENVELOPE_REF" '{envelope_ref:$envelope_ref,lease_id:"scenario-123-lease-1"}')"
CLAIMED="$(post_json "/workers/$WORKER/outbox/claim" "$CLAIM_BODY")" \
  && pass "worker claimed queued envelope through Workflow API" \
  || fail "worker claim API failed"
LEASE_REF="$(printf '%s' "$CLAIMED" | jq -r '.lease_ref // empty' 2>/dev/null)"
CLAIM_ENVELOPE="$(printf '%s' "$CLAIMED" | jq -c '.envelope // empty' 2>/dev/null)"
[ -n "$LEASE_REF" ] && pass "claim returned lease ref" || fail "claim did not return lease ref: $CLAIMED"
[ "$(printf '%s' "$CLAIMED" | jq -r '.status // empty' 2>/dev/null)" = "claimed" ] && pass "claim returned claimed status" || fail "claim returned unexpected status: $CLAIMED"
if printf '%s' "$CLAIMED" | grep -q "$PLAINTEXT_B64"; then
  fail "claim response leaked plaintext to worker"
else
  pass "claim response gave worker ciphertext and refs only"
fi

RELEASE_BODY="$(jq -cn --arg envelope_ref "$ENVELOPE_REF" --arg lease_ref "$LEASE_REF" \
  '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,last_error_ref:"error://scenario-123/transient"}')"
RELEASED="$(post_json "/workers/$WORKER/outbox/release" "$RELEASE_BODY")" \
  && pass "worker released claimed envelope for retry" \
  || fail "worker release API failed"
[ "$(printf '%s' "$RELEASED" | jq -r '.status // empty' 2>/dev/null)" = "queued" ] && pass "release returned envelope to queued status" || fail "release returned unexpected status: $RELEASED"
[ "$(printf '%s' "$RELEASED" | jq -r '.metadata.last_error_ref // empty' 2>/dev/null)" = "error://scenario-123/transient" ] && pass "release preserved ref-only error metadata" || fail "release did not preserve error ref: $RELEASED"

RECLAIM_BODY="$(jq -cn --arg envelope_ref "$ENVELOPE_REF" '{envelope_ref:$envelope_ref,lease_id:"scenario-123-lease-2"}')"
RECLAIMED="$(post_json "/workers/$WORKER/outbox/claim" "$RECLAIM_BODY")" \
  && pass "worker reclaimed released envelope" \
  || fail "worker reclaim API failed"
RECLAIM_LEASE="$(printf '%s' "$RECLAIMED" | jq -r '.lease_ref // empty' 2>/dev/null)"
RECLAIM_ENVELOPE="$(printf '%s' "$RECLAIMED" | jq -c '.envelope // empty' 2>/dev/null)"
[ "$(printf '%s' "$RECLAIMED" | jq -r '.metadata.attempt_count // empty' 2>/dev/null)" = "1" ] && pass "reclaim observed release attempt count" || fail "reclaim did not expose attempt count: $RECLAIMED"
[ "$RECLAIM_ENVELOPE" = "$CLAIM_ENVELOPE" ] && pass "reclaim delivered the same ciphertext envelope" || fail "reclaim changed ciphertext envelope"

DELIVER_BODY="$(jq -cn --arg envelope_ref "$ENVELOPE_REF" --argjson envelope "$RECLAIM_ENVELOPE" \
  '{envelope_ref:$envelope_ref,envelope:$envelope}')"
DELIVERED="$(post_json "/workers/$WORKER/inbox/deliver/$RECIPIENT" "$DELIVER_BODY")" \
  && pass "worker delivered ciphertext envelope to recipient inbox" \
  || fail "worker deliver API failed"
[ "$(printf '%s' "$DELIVERED" | jq -r '.status // empty' 2>/dev/null)" = "received" ] && pass "deliver returned received status" || fail "deliver returned unexpected status: $DELIVERED"

ACK_BODY="$(jq -cn --arg envelope_ref "$ENVELOPE_REF" --arg lease_ref "$RECLAIM_LEASE" \
  '{envelope_ref:$envelope_ref,lease_ref:$lease_ref}')"
ACKED="$(post_json "/workers/$WORKER/outbox/ack" "$ACK_BODY")" \
  && pass "worker acked delivered envelope" \
  || fail "worker ack API failed"
[ "$(printf '%s' "$ACKED" | jq -r '.status // empty' 2>/dev/null)" = "acked" ] && pass "ack returned terminal acked status" || fail "ack returned unexpected status: $ACKED"

DECRYPT_BODY="$(jq -cn --arg envelope_ref "$ENVELOPE_REF" '{envelope_ref:$envelope_ref}')"
DECRYPTED="$(post_json "/participants/$RECIPIENT/inbox/decrypt" "$DECRYPT_BODY")" \
  && pass "recipient decrypted delivered envelope through Workflow API" \
  || fail "recipient decrypt API failed"
[ "$(printf '%s' "$DECRYPTED" | jq -r '.plaintext // empty' 2>/dev/null)" = "$PLAINTEXT_B64" ] && pass "recipient recovered original plaintext" || fail "recipient plaintext mismatch: $DECRYPTED"

DUP_ACK_STATUS="$(post_status "/workers/$WORKER/outbox/ack" "$ACK_BODY")"
[ "$DUP_ACK_STATUS" != "200" ] && pass "duplicate ack was rejected" || fail "duplicate ack unexpectedly succeeded: $(cat /tmp/scenario-123-http-body)"
RECLAIM_AFTER_ACK_STATUS="$(post_status "/workers/$WORKER/outbox/claim" "$RECLAIM_BODY")"
[ "$RECLAIM_AFTER_ACK_STATUS" != "200" ] && pass "acked envelope could not be reclaimed" || fail "acked envelope reclaim unexpectedly succeeded: $(cat /tmp/scenario-123-http-body)"

finish
