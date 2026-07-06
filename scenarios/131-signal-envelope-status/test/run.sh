#!/usr/bin/env bash
# Scenario 131 - Signal envelope status.
#
# Demonstration-fidelity: starts the real Workflow server, builds/loads released
# workflow-plugin-signal v0.33.0 by default, and drives participant-parametric
# HTTP routes that execute Signal envelope lifecycle and status steps.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.33.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi

SENDER="${SENDER:-user-a}"
RECIPIENT="${RECIPIENT:-user-b}"
WORKER="${WORKER:-signal-status-worker}"
SPACE="${SPACE:-private-space-131}"
PLAINTEXT_B64="${PLAINTEXT_B64:-c2lnbmFsIGVudmVsb3BlIHN0YXR1cyBwcm9vZiAxMzE=}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18131}"
RAW_ERROR="temporary raw failure text with bearer-token"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG="$SCENARIO_DIR/config/app.yaml"
BODY_FILE="${TMPDIR:-/tmp}/scenario-131-http-body-$$"

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
  rm -f "$BODY_FILE"
  [ -n "$DATA_DIR" ] && rm -rf "$DATA_DIR"
}
trap cleanup EXIT

find_repo() {
  local env_value="$1"
  shift || true
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

plugin_repo_supports_status() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.version == "0.33.0") and
    (.capabilities.moduleTypes | index("signal.envelope_store")) and
    (.capabilities.stepTypes | index("step.signal_envelope_status")) and
    (.capabilities.stepTypes | index("step.signal_outbox_claim")) and
    (.capabilities.stepTypes | index("step.signal_outbox_release")) and
    (.capabilities.stepTypes | index("step.signal_outbox_ack")) and
    (.capabilities.stepTypes | index("step.signal_inbox_receive")) and
    (.capabilities.stepTypes | index("step.signal_inbox_decrypt"))
  ' "$repo/plugin.json" >/dev/null 2>&1
}

clone_or_checkout_plugin() {
  local target="$1"
  mkdir -p "$(dirname "$target")" || return 1
  if git ls-remote --exit-code --tags https://github.com/GoCodeAlone/workflow-plugin-signal.git "refs/tags/$SIGNAL_PLUGIN_REF" >/dev/null 2>&1; then
    git clone --quiet --depth 1 https://github.com/GoCodeAlone/workflow-plugin-signal.git "$target" || return 1
    git -C "$target" fetch --quiet --depth 1 origin "refs/tags/$SIGNAL_PLUGIN_REF:refs/tags/$SIGNAL_PLUGIN_REF" || return 1
    git -C "$target" -c advice.detachedHead=false checkout --quiet "$SIGNAL_PLUGIN_REF^{commit}" || return 1
  else
    git clone --quiet --depth 1 --branch "$SIGNAL_PLUGIN_REF" https://github.com/GoCodeAlone/workflow-plugin-signal.git "$target" || return 1
  fi
}

build_plugin() {
  local plugin_dir="$1"
  local plugin_repo
  if [ -n "${SIGNAL_PLUGIN_REPO:-}" ] && [ ! -d "$SIGNAL_PLUGIN_REPO" ]; then
    echo "SIGNAL_PLUGIN_REPO is set but is not a directory: $SIGNAL_PLUGIN_REPO" >&2
    return 1
  fi
  plugin_repo="$(find_repo "${SIGNAL_PLUGIN_REPO:-}")" || plugin_repo=""
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_status "$plugin_repo"; then
    plugin_repo="$DATA_DIR/repos/workflow-plugin-signal"
    clone_or_checkout_plugin "$plugin_repo" || return 1
  fi
  mkdir -p "$plugin_dir/$PLUGIN_NAME" || return 1
  cp "$plugin_repo/plugin.json" "$plugin_dir/$PLUGIN_NAME/plugin.json" || return 1
  (cd "$plugin_repo" && GOWORK=off go build \
    -ldflags "-X github.com/GoCodeAlone/workflow-plugin-signal/internal.Version=${PLUGIN_VERSION}" \
    -o "$plugin_dir/$PLUGIN_NAME/$PLUGIN_NAME" ./cmd/workflow-plugin-signal) >/dev/null 2>&1 || return 1
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

wait_for_http() {
  local url="$1"
  local i
  for i in $(seq 1 80); do
    curl -fs "$url" >/dev/null 2>&1 && return 0
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
  wait_for_http "$BASE_URL/healthz"
}

post_json() {
  local path="$1"
  local body="$2"
  curl -fsS -X POST "$BASE_URL$path" -H 'Content-Type: application/json' -d "$body"
}

post_status() {
  local path="$1"
  local body="$2"
  curl -sS -o "$BODY_FILE" -w "%{http_code}" -X POST "$BASE_URL$path" -H 'Content-Type: application/json' -d "$body"
}

assert_no_marker() {
  local label="$1"
  local value="$2"
  local marker="$3"
  if [ -z "$marker" ]; then
    pass "$label had no marker to inspect"
    return 0
  fi
  if printf '%s' "$value" | grep -Fq "$marker"; then
    fail "$label leaked marker $marker"
  else
    pass "$label did not leak marker $marker"
  fi
}

status_query() {
  local body="$1"
  local normalized
  normalized="$(printf '%s' "$body" | jq -c '{
    queue: (.queue // ""),
    status: (.status // ""),
    envelope_ref: (.envelope_ref // ""),
    message_ref: (.message_ref // ""),
    sender_ref: (.sender_ref // ""),
    recipient_ref: (.recipient_ref // ""),
    limit: (.limit // 100)
  }')" || return 1
  post_json "/status/envelopes" "$normalized"
}

echo ""
echo "=== Scenario 131 - Signal Envelope Status ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if grep -Eiq 'ali''ce|bo''b' "$CONFIG" "$0"; then
  fail "Workflow scenario should not bake fixed demo participant names"
else
  pass "Workflow API and test runner are participant-parametric"
fi
for step_type in step.signal_outbox_enqueue step.signal_outbox_claim step.signal_outbox_release step.signal_outbox_ack step.signal_inbox_receive step.signal_inbox_decrypt step.signal_envelope_status; do
  grep -q "type: $step_type" "$CONFIG" && pass "Workflow app config exercises $step_type" || fail "Workflow app config does not exercise $step_type"
done

SERVER_BIN="$(resolve_server)"
if [ "$?" -eq 0 ]; then
  pass "workflow server binary is available"
else
  fail "workflow server unavailable; set WORKFLOW_SERVER or WORKFLOW_REPO"
  finish
  exit 1
fi

DATA_DIR="$(mktemp -d)" || {
  fail "could not create temporary data directory"
  finish
  exit 1
}
PLUGIN_DIR="$DATA_DIR/plugins"
if build_plugin "$PLUGIN_DIR"; then
  pass "built released workflow-plugin-signal v$PLUGIN_VERSION external plugin"
else
  fail "could not build released workflow-plugin-signal v$PLUGIN_VERSION"
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

RECIPIENT_SESSION="$(post_json "/participants/$RECIPIENT/session" '{}')" && pass "recipient prepared bundle via Workflow API" || fail "recipient session failed"
RECIPIENT_BUNDLE="$(printf '%s' "$RECIPIENT_SESSION" | jq -c '.bundle // empty')"
[ -n "$RECIPIENT_BUNDLE" ] && pass "recipient response included bundle" || fail "recipient bundle missing: $RECIPIENT_SESSION"

send_envelope() {
  local message_ref="$1"
  local body
  body="$(jq -cn --arg plaintext "$PLAINTEXT_B64" --arg message_ref "$message_ref" --argjson remote_bundle "$RECIPIENT_BUNDLE" \
    '{plaintext:$plaintext,message_ref:$message_ref,remote_bundle:$remote_bundle}')" || return 1
  post_json "/spaces/$SPACE/participants/$SENDER/outbox/$RECIPIENT" "$body"
}

QUEUED="$(send_envelope "status-queued")" && pass "queued envelope sent through Workflow API" || fail "queued send failed"
QUEUED_REF="$(printf '%s' "$QUEUED" | jq -r '.envelope_ref // empty')"
CLAIM_SOURCE="$(send_envelope "status-claimed")" && pass "claim fixture sent through Workflow API" || fail "claim fixture send failed"
CLAIM_REF="$(printf '%s' "$CLAIM_SOURCE" | jq -r '.envelope_ref // empty')"
RELEASE_SOURCE="$(send_envelope "status-released")" && pass "release fixture sent through Workflow API" || fail "release fixture send failed"
RELEASE_REF="$(printf '%s' "$RELEASE_SOURCE" | jq -r '.envelope_ref // empty')"
ACK_SOURCE="$(send_envelope "status-acked")" && pass "ack fixture sent through Workflow API" || fail "ack fixture send failed"
ACK_REF="$(printf '%s' "$ACK_SOURCE" | jq -r '.envelope_ref // empty')"

CLAIMED="$(post_json "/workers/$WORKER/outbox/claim" "$(jq -cn --arg envelope_ref "$CLAIM_REF" '{envelope_ref:$envelope_ref,lease_id:"lease-claimed",requested_at_unix:2000}')")" \
  && pass "worker claimed envelope through Workflow API" || fail "claim API failed"
CLAIM_LEASE="$(printf '%s' "$CLAIMED" | jq -r '.lease_ref // empty')"

RELEASE_CLAIM="$(post_json "/workers/$WORKER/outbox/claim" "$(jq -cn --arg envelope_ref "$RELEASE_REF" '{envelope_ref:$envelope_ref,lease_id:"lease-release",requested_at_unix:2100}')")" \
  && pass "worker claimed release fixture" || fail "release fixture claim failed"
RELEASE_LEASE="$(printf '%s' "$RELEASE_CLAIM" | jq -r '.lease_ref // empty')"
RELEASED="$(post_json "/workers/$WORKER/outbox/release" "$(jq -cn --arg envelope_ref "$RELEASE_REF" --arg lease_ref "$RELEASE_LEASE" --arg raw "$RAW_ERROR" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,last_error_ref:$raw,requested_at_unix:2200}')")" \
  && pass "worker released envelope with unsafe error text" || fail "release API failed"
[ "$(printf '%s' "$RELEASED" | jq -r '.status // empty')" = "queued" ] && pass "release returned queued status" || fail "release status unexpected: $RELEASED"

ACK_CLAIM="$(post_json "/workers/$WORKER/outbox/claim" "$(jq -cn --arg envelope_ref "$ACK_REF" '{envelope_ref:$envelope_ref,lease_id:"lease-ack",requested_at_unix:2300}')")" \
  && pass "worker claimed ack fixture" || fail "ack fixture claim failed"
ACK_LEASE="$(printf '%s' "$ACK_CLAIM" | jq -r '.lease_ref // empty')"
ACKED="$(post_json "/workers/$WORKER/outbox/ack" "$(jq -cn --arg envelope_ref "$ACK_REF" --arg lease_ref "$ACK_LEASE" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,requested_at_unix:2400}')")" \
  && pass "worker acked envelope through Workflow API" || fail "ack API failed"
[ "$(printf '%s' "$ACKED" | jq -r '.status // empty')" = "acked" ] && pass "ack returned terminal status" || fail "ack status unexpected: $ACKED"

INBOX_REF="signal-envelope://inbox/status-received"
RECEIVED="$(post_json "/participants/$RECIPIENT/inbox/receive" "$(jq -cn --arg envelope_ref "$INBOX_REF" --arg idempotency_key "status-received" --argjson envelope "$(printf '%s' "$ACK_CLAIM" | jq -c '.envelope')" '{envelope_ref:$envelope_ref,idempotency_key:$idempotency_key,envelope:$envelope,requested_at_unix:2500}')")" \
  && pass "recipient admitted inbox envelope through Workflow API" || fail "inbox receive API failed"
[ "$(printf '%s' "$RECEIVED" | jq -r '.status // empty')" = "received" ] && pass "inbox receive returned received status" || fail "inbox receive status unexpected: $RECEIVED"
DECRYPTED="$(post_json "/participants/$RECIPIENT/inbox/decrypt" "$(jq -cn --arg envelope_ref "$INBOX_REF" '{envelope_ref:$envelope_ref}')")" \
  && pass "recipient decrypted inbox envelope through Workflow API" || fail "inbox decrypt API failed"
[ "$(printf '%s' "$DECRYPTED" | jq -r '.plaintext // empty')" = "$PLAINTEXT_B64" ] && pass "recipient recovered original plaintext" || fail "plaintext mismatch: $DECRYPTED"

ALL_STATUS="$(status_query '{"limit":3}')" && pass "status route returned bounded result set" || fail "status route failed"
[ "$(printf '%s' "$ALL_STATUS" | jq -r '.count // 0')" = "3" ] && pass "status count reflected requested limit" || fail "status count unexpected: $ALL_STATUS"
[ "$(printf '%s' "$ALL_STATUS" | jq -r '.truncated // false')" = "true" ] && pass "status reported truncation" || fail "status did not report truncation: $ALL_STATUS"

check_status_item() {
  local label="$1"
  local ref="$2"
  local queue="$3"
  local want_status="$4"
  BODY="$(jq -cn --arg envelope_ref "$ref" --arg queue "$queue" '{envelope_ref:$envelope_ref,queue:$queue}')"
  STATUS_OUT="$(status_query "$BODY")" && pass "$label status query succeeded" || fail "$label status query failed"
  [ "$(printf '%s' "$STATUS_OUT" | jq -r '.count // 0')" = "1" ] && pass "$label status returned one item" || fail "$label status count unexpected: $STATUS_OUT"
  [ "$(printf '%s' "$STATUS_OUT" | jq -r '.items[0].status // empty')" = "$want_status" ] && pass "$label status matched $want_status" || fail "$label status mismatch: $STATUS_OUT"
  assert_no_marker "$label status" "$STATUS_OUT" "$PLAINTEXT_B64"
  assert_no_marker "$label status" "$STATUS_OUT" "ciphertext"
  assert_no_marker "$label status" "$STATUS_OUT" "custody://"
  assert_no_marker "$label status" "$STATUS_OUT" "authz://"
  assert_no_marker "$label status" "$STATUS_OUT" "$CLAIM_LEASE"
}

check_status_item "queued" "$QUEUED_REF" "outbox" "queued"
check_status_item "claimed" "$CLAIM_REF" "outbox" "claimed"
check_status_item "released" "$RELEASE_REF" "outbox" "queued"
check_status_item "acked" "$ACK_REF" "outbox" "acked"
check_status_item "received" "$INBOX_REF" "inbox" "received"

RELEASE_STATUS="$(status_query "$(jq -cn --arg envelope_ref "$RELEASE_REF" '{envelope_ref:$envelope_ref,queue:"outbox"}')")"
[ "$(printf '%s' "$RELEASE_STATUS" | jq -r '.items[0].last_error_redacted // false')" = "true" ] && pass "unsafe release error was redacted" || fail "unsafe error was not redacted: $RELEASE_STATUS"
[ "$(printf '%s' "$RELEASE_STATUS" | jq -r '.items[0].last_error_ref_sha256 // empty')" != "" ] && pass "unsafe release error returned hash evidence" || fail "unsafe error hash missing: $RELEASE_STATUS"
assert_no_marker "release status" "$RELEASE_STATUS" "$RAW_ERROR"

finish
