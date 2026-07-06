#!/usr/bin/env bash
# Scenario 134 - Signal envelope purge.
#
# Demonstration-fidelity: starts the real Workflow server, builds/loads released
# workflow-plugin-signal v0.34.0 by default, uses a scenario-owned SQLite
# envelope store, drives terminal envelope purge preview/execute behavior via
# HTTP, restarts the server, and proves purge state persists.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.34.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi

SENDER="${SENDER:-user-a}"
RECIPIENT="${RECIPIENT:-user-b}"
WORKER="${WORKER:-signal-purge-worker}"
OPERATOR="${OPERATOR:-signal-retention-operator}"
SPACE="${SPACE:-private-space-134}"
PLAINTEXT_B64="${PLAINTEXT_B64:-c2lnbmFsIGVudmVsb3BlIHB1cmdlIHByb29mIDEzNA==}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18134}"
RAW_ERROR="raw downstream failure with bearer-token"
SAFE_REASON="reason://scenario/134/invalid-route"
PURGE_REASON="reason://scenario/134/retention-window"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG_TEMPLATE="$SCENARIO_DIR/config/app.yaml"
BODY_FILE="${TMPDIR:-/tmp}/scenario-134-http-body-$$"

PASS=0
FAIL=0
SERVER_PID=""
DATA_DIR=""
RUNTIME_CONFIG=""
SQLITE_PATH=""
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
cleanup() {
  stop_server
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

plugin_repo_supports_purge() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.version == "0.34.0") and
    (.capabilities.moduleTypes | index("signal.envelope_store")) and
    (.capabilities.stepTypes | index("step.signal_envelope_status")) and
    (.capabilities.stepTypes | index("step.signal_outbox_dead_letter")) and
    (.capabilities.stepTypes | index("step.signal_envelope_purge")) and
    (.capabilities.stepTypes | index("step.signal_outbox_handoff")) and
    (.capabilities.stepTypes | index("step.signal_outbox_ack")) and
    (.capabilities.stepTypes | index("step.signal_inbox_receive")) and
    (.capabilities.stepTypes | index("step.signal_outbox_release"))
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
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_purge "$plugin_repo"; then
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
  "$SERVER_BIN" -config "$RUNTIME_CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  wait_for_http "$BASE_URL/healthz"
}

stop_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  SERVER_PID=""
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

assert_rejected_not_missing() {
  local label="$1"
  local code="$2"
  if [ "$code" = "200" ]; then
    fail "$label unexpectedly succeeded"
  elif [ "$code" = "404" ]; then
    fail "$label returned 404; route may be missing: $(cat "$BODY_FILE")"
  else
    pass "$label was rejected with HTTP $code"
  fi
}

status_for() {
  local ref="$1"
  post_json "/status/envelopes" "$(jq -cn --arg envelope_ref "$ref" '{queue:"outbox",status:"",envelope_ref:$envelope_ref,message_ref:"",sender_ref:"",recipient_ref:"",limit:100}')"
}

status_query() {
  local body="$1"
  post_json "/status/envelopes" "$body"
}

send_envelope() {
  local message_ref="$1"
  local body
  body="$(jq -cn --arg plaintext "$PLAINTEXT_B64" --arg message_ref "$message_ref" --argjson remote_bundle "$RECIPIENT_BUNDLE" \
    '{plaintext:$plaintext,message_ref:$message_ref,remote_bundle:$remote_bundle}')" || return 1
  post_json "/spaces/$SPACE/participants/$SENDER/outbox/$RECIPIENT" "$body"
}

sqlite_snapshot() {
  sqlite3 "$SQLITE_PATH" 'select state_json from signal_envelope_store_snapshots where store_ref = "signal_envelopes";'
}

echo ""
echo "=== Scenario 134 - Signal Envelope Purge ==="
echo ""

[ -f "$CONFIG_TEMPLATE" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if grep -Eiq 'ali''ce|bo''b' "$CONFIG_TEMPLATE" "$0"; then
  fail "Workflow scenario should not bake fixed demo participant names"
else
  pass "Workflow API and test runner are participant-parametric"
fi
for step_type in step.signal_outbox_enqueue step.signal_outbox_claim step.signal_outbox_release step.signal_outbox_dead_letter step.signal_outbox_ack step.signal_inbox_receive step.signal_envelope_status step.signal_envelope_purge; do
  grep -q "type: $step_type" "$CONFIG_TEMPLATE" && pass "Workflow app config exercises $step_type" || fail "Workflow app config does not exercise $step_type"
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
SQLITE_PATH="$DATA_DIR/envelopes.sqlite"
RUNTIME_CONFIG="$DATA_DIR/app.yaml"
sed -e "s#__SQLITE_PATH__#$SQLITE_PATH#g" "$CONFIG_TEMPLATE" >"$RUNTIME_CONFIG" || {
  fail "could not render runtime config"
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

ACTIVE_SEND="$(send_envelope "purge-active")" && pass "active queued fixture enqueued" || fail "active send failed"
ACTIVE_REF="$(printf '%s' "$ACTIVE_SEND" | jq -r '.envelope_ref // empty')"

CLAIMED_SEND="$(send_envelope "purge-claimed")" && pass "active claimed fixture enqueued" || fail "claimed send failed"
CLAIMED_REF="$(printf '%s' "$CLAIMED_SEND" | jq -r '.envelope_ref // empty')"
CLAIMED_CLAIM="$(post_json "/workers/$WORKER/outbox/claim" "$(jq -cn --arg envelope_ref "$CLAIMED_REF" '{envelope_ref:$envelope_ref,lease_id:"purge-claimed-lease",requested_at_unix:3000}')")" \
  && pass "active claimed fixture claimed" || fail "claimed fixture claim failed"
CLAIMED_LEASE="$(printf '%s' "$CLAIMED_CLAIM" | jq -r '.lease_ref // empty')"

DEAD_SEND="$(send_envelope "purge-dead")" && pass "dead-letter fixture enqueued" || fail "dead-letter send failed"
DEAD_REF="$(printf '%s' "$DEAD_SEND" | jq -r '.envelope_ref // empty')"
DEAD_CLAIM="$(post_json "/workers/$WORKER/outbox/claim" "$(jq -cn --arg envelope_ref "$DEAD_REF" '{envelope_ref:$envelope_ref,lease_id:"purge-dead-lease",requested_at_unix:3100}')")" \
  && pass "dead-letter fixture claimed" || fail "dead-letter claim failed"
DEAD_LEASE="$(printf '%s' "$DEAD_CLAIM" | jq -r '.lease_ref // empty')"
DEAD_OUT="$(post_json "/workers/$WORKER/outbox/dead-letter" "$(jq -cn --arg envelope_ref "$DEAD_REF" --arg lease_ref "$DEAD_LEASE" --arg reason "$SAFE_REASON" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,reason_ref:$reason,requested_at_unix:3200}')")" \
  && pass "dead-letter terminal fixture created" || fail "dead-letter fixture failed"
[ "$(printf '%s' "$DEAD_OUT" | jq -r '.status // empty')" = "dead_lettered" ] && pass "dead-letter fixture returned terminal state" || fail "dead-letter fixture mismatch: $DEAD_OUT"

ACK_SEND="$(send_envelope "purge-acked")" && pass "acked fixture enqueued" || fail "acked send failed"
ACK_REF="$(printf '%s' "$ACK_SEND" | jq -r '.envelope_ref // empty')"
ACK_CLAIM="$(post_json "/workers/$WORKER/outbox/claim" "$(jq -cn --arg envelope_ref "$ACK_REF" '{envelope_ref:$envelope_ref,lease_id:"purge-ack-lease",requested_at_unix:3300}')")" \
  && pass "acked fixture claimed" || fail "acked claim failed"
ACK_LEASE="$(printf '%s' "$ACK_CLAIM" | jq -r '.lease_ref // empty')"
ACK_ENV="$(printf '%s' "$ACK_CLAIM" | jq -c '.envelope // empty')"
ACK_OUT="$(post_json "/workers/$WORKER/outbox/ack" "$(jq -cn --arg envelope_ref "$ACK_REF" --arg lease_ref "$ACK_LEASE" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,requested_at_unix:3400}')")" \
  && pass "acked terminal fixture created" || fail "ack fixture failed"
[ "$(printf '%s' "$ACK_OUT" | jq -r '.status // empty')" = "acked" ] && pass "ack fixture returned terminal state" || fail "ack fixture mismatch: $ACK_OUT"

INBOX_REF="inbox://scenario/134/received"
INBOX_OUT="$(post_json "/participants/$RECIPIENT/inbox/receive" "$(jq -cn --arg envelope_ref "$INBOX_REF" --argjson envelope "$ACK_ENV" '{envelope_ref:$envelope_ref,idempotency_key:"purge-inbox",envelope:$envelope,requested_at_unix:3500}')")" \
  && pass "received inbox terminal fixture created" || fail "inbox receive failed"
[ "$(printf '%s' "$INBOX_OUT" | jq -r '.status // empty')" = "received" ] && pass "inbox fixture returned received state" || fail "inbox fixture mismatch: $INBOX_OUT"

PREVIEW="$(post_json "/operators/$OPERATOR/envelopes/purge" "$(jq -cn --arg reason "$PURGE_REASON" '{limit:1,reason_ref:$reason}')")" \
  && pass "purge preview executed through Workflow API" || fail "purge preview failed"
[ "$(printf '%s' "$PREVIEW" | jq -r '.preview // false')" = "true" ] && pass "purge preview defaulted to preview mode" || fail "purge preview flag mismatch: $PREVIEW"
[ "$(printf '%s' "$PREVIEW" | jq -r '.matched_count // 0')" = "3" ] && pass "purge preview reported all terminal matches" || fail "purge preview matched_count mismatch: $PREVIEW"
[ "$(printf '%s' "$PREVIEW" | jq -r '.items | length')" = "1" ] && pass "purge preview respected item limit" || fail "purge preview limit mismatch: $PREVIEW"
[ "$(printf '%s' "$PREVIEW" | jq -r '.purged_count // 0')" = "0" ] && pass "purge preview did not delete records" || fail "purge preview purged records: $PREVIEW"
assert_no_marker "purge preview" "$PREVIEW" "$PLAINTEXT_B64"
assert_no_marker "purge preview" "$PREVIEW" "custody://"
assert_no_marker "purge preview" "$PREVIEW" "authz://"
assert_no_marker "purge preview" "$PREVIEW" "$CLAIMED_LEASE"

assertStatusDead="$(status_for "$DEAD_REF")" && pass "dead-letter still visible after preview" || fail "dead-letter status after preview failed"
[ "$(printf '%s' "$assertStatusDead" | jq -r '.items[0].status // empty')" = "dead_lettered" ] && pass "preview retained dead-letter record" || fail "preview deleted dead-letter: $assertStatusDead"
assertStatusAck="$(status_for "$ACK_REF")" && pass "acked record still visible after preview" || fail "acked status after preview failed"
[ "$(printf '%s' "$assertStatusAck" | jq -r '.items[0].status // empty')" = "acked" ] && pass "preview retained acked record" || fail "preview deleted acked: $assertStatusAck"
assertStatusInbox="$(status_query "$(jq -cn --arg envelope_ref "$INBOX_REF" '{queue:"inbox",envelope_ref:$envelope_ref,limit:100}')")" && pass "inbox record still visible after preview" || fail "inbox status after preview failed"
[ "$(printf '%s' "$assertStatusInbox" | jq -r '.items[0].status // empty')" = "received" ] && pass "preview retained inbox record" || fail "preview deleted inbox: $assertStatusInbox"

ACTIVE_PURGE_CODE="$(post_status "/operators/$OPERATOR/envelopes/purge" "$(jq -cn --arg reason "$PURGE_REASON" '{queue:"outbox",status:"queued",execute_purge:true,reason_ref:$reason}')")"
assert_rejected_not_missing "destructive purge of active queued records" "$ACTIVE_PURGE_CODE"
CLAIMED_PURGE_CODE="$(post_status "/operators/$OPERATOR/envelopes/purge" "$(jq -cn --arg reason "$PURGE_REASON" '{queue:"outbox",status:"claimed",execute_purge:true,reason_ref:$reason}')")"
assert_rejected_not_missing "destructive purge of active claimed records" "$CLAIMED_PURGE_CODE"

PURGED="$(post_json "/operators/$OPERATOR/envelopes/purge" "$(jq -cn --arg reason "$PURGE_REASON" '{execute_purge:true,reason_ref:$reason,limit:100,requested_at_unix:3600}')")" \
  && pass "destructive terminal purge executed through Workflow API" || fail "destructive purge failed"
[ "$(printf '%s' "$PURGED" | jq -r '.preview // false')" = "false" ] && pass "destructive purge returned non-preview mode" || fail "purge execute flag mismatch: $PURGED"
[ "$(printf '%s' "$PURGED" | jq -r '.matched_count // 0')" = "3" ] && pass "destructive purge matched terminal records" || fail "purge matched_count mismatch: $PURGED"
[ "$(printf '%s' "$PURGED" | jq -r '.purged_count // 0')" = "3" ] && pass "destructive purge removed terminal records" || fail "purge count mismatch: $PURGED"
assert_no_marker "purge execute response" "$PURGED" "$PLAINTEXT_B64"
assert_no_marker "purge execute response" "$PURGED" "custody://"
assert_no_marker "purge execute response" "$PURGED" "authz://"
assert_no_marker "purge execute response" "$PURGED" "$CLAIMED_LEASE"

status_for "$DEAD_REF" | jq -e '(.count // 0) == 0' >/dev/null && pass "dead-letter record disappeared after purge" || fail "dead-letter record remained after purge"
status_for "$ACK_REF" | jq -e '(.count // 0) == 0' >/dev/null && pass "acked record disappeared after purge" || fail "acked record remained after purge"
status_query "$(jq -cn --arg envelope_ref "$INBOX_REF" '{queue:"inbox",envelope_ref:$envelope_ref,limit:100}')" | jq -e '(.count // 0) == 0' >/dev/null && pass "inbox record disappeared after purge" || fail "inbox record remained after purge"
status_for "$ACTIVE_REF" | jq -e '.count == 1 and .items[0].status == "queued"' >/dev/null && pass "queued active record survived purge" || fail "queued active record missing after purge"
status_for "$CLAIMED_REF" | jq -e '.count == 1 and .items[0].status == "claimed"' >/dev/null && pass "claimed active record survived purge" || fail "claimed active record missing after purge"

SNAPSHOT="$(sqlite_snapshot 2>/dev/null)" && pass "SQLite envelope snapshot was written" || fail "SQLite envelope snapshot missing"
assert_no_marker "SQLite snapshot" "$SNAPSHOT" "$PLAINTEXT_B64"
if printf '%s' "$SNAPSHOT" | grep -Fq "$DEAD_REF" || printf '%s' "$SNAPSHOT" | grep -Fq "$ACK_REF" || printf '%s' "$SNAPSHOT" | grep -Fq "$INBOX_REF"; then
  fail "SQLite snapshot retained purged terminal refs"
else
  pass "SQLite snapshot omitted purged terminal refs"
fi

stop_server
if start_server; then
  pass "workflow server restarted against same SQLite store"
else
  fail "workflow server did not restart; see $SERVER_LOG"
  finish
  exit 1
fi
status_for "$DEAD_REF" | jq -e '(.count // 0) == 0' >/dev/null && pass "dead-letter purge persisted after restart" || fail "dead-letter ref returned after restart"
status_for "$ACK_REF" | jq -e '(.count // 0) == 0' >/dev/null && pass "acked purge persisted after restart" || fail "acked ref returned after restart"
status_query "$(jq -cn --arg envelope_ref "$INBOX_REF" '{queue:"inbox",envelope_ref:$envelope_ref,limit:100}')" | jq -e '(.count // 0) == 0' >/dev/null && pass "inbox purge persisted after restart" || fail "inbox ref returned after restart"
status_for "$ACTIVE_REF" | jq -e '.count == 1 and .items[0].status == "queued"' >/dev/null && pass "queued active record survived restart" || fail "queued active record missing after restart"
status_for "$CLAIMED_REF" | jq -e '.count == 1 and .items[0].status == "claimed"' >/dev/null && pass "claimed active record survived restart" || fail "claimed active record missing after restart"

finish
