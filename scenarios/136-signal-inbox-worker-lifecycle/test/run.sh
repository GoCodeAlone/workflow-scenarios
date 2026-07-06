#!/usr/bin/env bash
# Scenario 136 - Signal inbox worker lifecycle.
#
# Demonstration-fidelity: starts the real Workflow server, builds/loads released
# workflow-plugin-signal v0.35.1 by default, and drives participant-parametric
# HTTP routes that execute inbox claim, release, stale reclaim, dead-letter,
# requeue, ack, and lease-aware decrypt against a SQLite envelope store.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.35.1}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi

SENDER="${SENDER:-user-a}"
RECIPIENT="${RECIPIENT:-user-b}"
WORKER="${WORKER:-signal-inbox-worker}"
OPERATOR="${OPERATOR:-signal-inbox-operator}"
SPACE="${SPACE:-private-space-136}"
PLAINTEXT_B64="${PLAINTEXT_B64:-c2lnbmFsIGluYm94IGxpZmVjeWNsZSBwcm9vZiAxMzY=}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18136}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG_TEMPLATE="$SCENARIO_DIR/config/app.yaml"
BODY_FILE="${TMPDIR:-/tmp}/scenario-136-http-body-$$"

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

plugin_repo_supports_inbox_lifecycle() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.version == "0.35.1") and
    (.capabilities.moduleTypes | index("signal.envelope_store")) and
    (.capabilities.stepTypes | index("step.signal_inbox_claim")) and
    (.capabilities.stepTypes | index("step.signal_inbox_reclaim_stale")) and
    (.capabilities.stepTypes | index("step.signal_inbox_release")) and
    (.capabilities.stepTypes | index("step.signal_inbox_ack")) and
    (.capabilities.stepTypes | index("step.signal_inbox_dead_letter")) and
    (.capabilities.stepTypes | index("step.signal_inbox_requeue")) and
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
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_inbox_lifecycle "$plugin_repo"; then
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

require_post_status() {
  local out_var="$1"
  local label="$2"
  local path="$3"
  local body="$4"
  local code
  if ! code="$(post_status "$path" "$body")"; then
    fail "$label request failed before an HTTP response"
    finish
    exit 1
  fi
  if ! printf '%s' "$code" | grep -Eq '^[0-9]{3}$'; then
    fail "$label returned invalid HTTP status '$code'"
    finish
    exit 1
  fi
  printf -v "$out_var" '%s' "$code"
}

status_query() {
  local body="$1"
  post_json "/status/envelopes" "$body"
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

send_envelope() {
  local message_ref="$1"
  local body
  body="$(jq -cn --arg plaintext "$PLAINTEXT_B64" --arg message_ref "$message_ref" --argjson remote_bundle "$RECIPIENT_BUNDLE" \
    '{plaintext:$plaintext,message_ref:$message_ref,remote_bundle:$remote_bundle}')" || return 1
  post_json "/spaces/$SPACE/participants/$SENDER/outbox/$RECIPIENT" "$body"
}

receive_from_claim() {
  local envelope_ref="$1"
  local claim="$2"
  local inbox_ref="$3"
  local envelope
  envelope="$(printf '%s' "$claim" | jq -c '.envelope // empty')" || return 1
  post_json "/participants/$RECIPIENT/inbox/receive" "$(jq -cn --arg envelope_ref "$inbox_ref" --arg key "$inbox_ref" --argjson envelope "$envelope" '{envelope_ref:$envelope_ref,idempotency_key:$key,envelope:$envelope,requested_at_unix:3000}')"
}

echo ""
echo "=== Scenario 136 - Signal Inbox Worker Lifecycle ==="
echo ""

[ -f "$CONFIG_TEMPLATE" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if grep -Eiq 'ali''ce|bo''b' "$CONFIG_TEMPLATE" "$0"; then
  fail "Workflow scenario should not bake fixed demo participant names"
else
  pass "Workflow API and test runner are participant-parametric"
fi
for step_type in step.signal_inbox_claim step.signal_inbox_reclaim_stale step.signal_inbox_release step.signal_inbox_ack step.signal_inbox_dead_letter step.signal_inbox_requeue step.signal_inbox_decrypt; do
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

DATA_DIR="$(mktemp -d)" || { fail "could not create temporary data directory"; finish; exit 1; }
SQLITE_PATH="$DATA_DIR/envelopes.sqlite"
RUNTIME_CONFIG="$DATA_DIR/app.yaml"
sed -e "s#__SQLITE_PATH__#$SQLITE_PATH#g" "$CONFIG_TEMPLATE" >"$RUNTIME_CONFIG" || { fail "could not render runtime config"; finish; exit 1; }
PLUGIN_DIR="$DATA_DIR/plugins"
if build_plugin "$PLUGIN_DIR"; then pass "built released workflow-plugin-signal v$PLUGIN_VERSION external plugin"; else fail "could not build released workflow-plugin-signal v$PLUGIN_VERSION"; finish; exit 1; fi
if start_server; then pass "workflow server started and served /healthz"; else fail "workflow server did not become ready; see $SERVER_LOG"; finish; exit 1; fi

RECIPIENT_SESSION="$(post_json "/participants/$RECIPIENT/session" '{}')" && pass "recipient prepared bundle via Workflow API" || fail "recipient session failed"
RECIPIENT_BUNDLE="$(printf '%s' "$RECIPIENT_SESSION" | jq -c '.bundle // empty')"
[ -n "$RECIPIENT_BUNDLE" ] && pass "recipient response included bundle" || fail "recipient bundle missing: $RECIPIENT_SESSION"

SEND_ACK="$(send_envelope "inbox-ack")" && pass "sender enqueued ack fixture" || fail "ack send failed"
OUTBOX_ACK_REF="$(printf '%s' "$SEND_ACK" | jq -r '.envelope_ref // empty')"
OUTBOX_ACK_CLAIM="$(post_json "/workers/$WORKER/outbox/claim" "$(jq -cn --arg envelope_ref "$OUTBOX_ACK_REF" '{envelope_ref:$envelope_ref,lease_id:"outbox-ack-lease",requested_at_unix:3000}')")" \
  && pass "worker claimed outbox fixture for inbox admission" || fail "outbox claim failed"
INBOX_ACK_REF="inbox://scenario/136/ack"
RECEIVED_ACK="$(receive_from_claim "$OUTBOX_ACK_REF" "$OUTBOX_ACK_CLAIM" "$INBOX_ACK_REF")" && pass "recipient inbox received fixture through Workflow API" || fail "inbox receive failed"
[ "$(printf '%s' "$RECEIVED_ACK" | jq -r '.status // empty')" = "received" ] && pass "inbox receive returned received status" || fail "receive status mismatch: $RECEIVED_ACK"

CLAIM_ACK="$(post_json "/workers/$WORKER/inbox/claim" "$(jq -cn --arg envelope_ref "$INBOX_ACK_REF" '{envelope_ref:$envelope_ref,lease_id:"inbox-ack-lease",requested_at_unix:3100,lease_ttl_seconds:20}')")" \
  && pass "worker claimed inbox item" || fail "inbox claim failed"
INBOX_LEASE="$(printf '%s' "$CLAIM_ACK" | jq -r '.lease_ref // empty')"
[ -n "$INBOX_LEASE" ] && pass "inbox claim returned lease ref" || fail "inbox claim lease missing: $CLAIM_ACK"
require_post_status NO_LEASE_CODE "decrypt of claimed inbox without lease" "/participants/$RECIPIENT/inbox/decrypt" "$(jq -cn --arg envelope_ref "$INBOX_ACK_REF" '{envelope_ref:$envelope_ref}')"
assert_rejected_not_missing "decrypt of claimed inbox without lease" "$NO_LEASE_CODE"
DECRYPTED="$(post_json "/participants/$RECIPIENT/inbox/decrypt" "$(jq -cn --arg envelope_ref "$INBOX_ACK_REF" --arg lease_ref "$INBOX_LEASE" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref}')")" \
  && pass "recipient decrypted claimed inbox item with lease" || fail "leased decrypt failed"
[ "$(printf '%s' "$DECRYPTED" | jq -r '.plaintext // empty')" = "$PLAINTEXT_B64" ] && pass "leased decrypt recovered original plaintext" || fail "leased decrypt mismatch: $DECRYPTED"
ACKED="$(post_json "/workers/$WORKER/inbox/ack" "$(jq -cn --arg envelope_ref "$INBOX_ACK_REF" --arg lease_ref "$INBOX_LEASE" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,requested_at_unix:3200}')")" \
  && pass "worker acked inbox item" || fail "inbox ack failed"
[ "$(printf '%s' "$ACKED" | jq -r '.status // empty')" = "acked" ] && pass "inbox ack returned terminal status" || fail "ack status mismatch: $ACKED"

SEND_REL="$(send_envelope "inbox-release")" && pass "sender enqueued release fixture" || fail "release send failed"
OUTBOX_REL_REF="$(printf '%s' "$SEND_REL" | jq -r '.envelope_ref // empty')"
OUTBOX_REL_CLAIM="$(post_json "/workers/$WORKER/outbox/claim" "$(jq -cn --arg envelope_ref "$OUTBOX_REL_REF" '{envelope_ref:$envelope_ref,lease_id:"outbox-release-lease",requested_at_unix:3300}')")" \
  && pass "worker claimed release fixture for inbox admission" || fail "release outbox claim failed"
INBOX_REL_REF="inbox://scenario/136/release"
receive_from_claim "$OUTBOX_REL_REF" "$OUTBOX_REL_CLAIM" "$INBOX_REL_REF" >/dev/null && pass "release inbox fixture received" || fail "release inbox receive failed"
CLAIM_REL="$(post_json "/workers/$WORKER/inbox/claim" "$(jq -cn --arg envelope_ref "$INBOX_REL_REF" '{envelope_ref:$envelope_ref,lease_id:"inbox-release-lease",requested_at_unix:3400,lease_ttl_seconds:1}')")" \
  && pass "worker claimed release fixture" || fail "claim release fixture failed"
REL_LEASE="$(printf '%s' "$CLAIM_REL" | jq -r '.lease_ref // empty')"
RELEASED="$(post_json "/workers/$WORKER/inbox/release" "$(jq -cn --arg envelope_ref "$INBOX_REL_REF" --arg lease_ref "$REL_LEASE" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,last_error_ref:"error://scenario/136/transient",requested_at_unix:3410}')")" \
  && pass "worker released inbox item" || fail "inbox release failed"
[ "$(printf '%s' "$RELEASED" | jq -r '.status // empty')" = "received" ] && pass "inbox release returned item to received state" || fail "release status mismatch: $RELEASED"
CLAIM_REL2="$(post_json "/workers/$WORKER/inbox/claim" "$(jq -cn --arg envelope_ref "$INBOX_REL_REF" '{envelope_ref:$envelope_ref,lease_id:"inbox-release-lease-2",requested_at_unix:3420,lease_ttl_seconds:1}')")" \
  && pass "worker reclaimed released inbox item" || fail "claim after release failed"
REL2_LEASE="$(printf '%s' "$CLAIM_REL2" | jq -r '.lease_ref // empty')"
RECLAIMED="$(post_json "/workers/$WORKER/inbox/reclaim-stale" "$(jq -cn --arg envelope_ref "$INBOX_REL_REF" '{envelope_ref:$envelope_ref,reason_ref:"reason://scenario/136/stale",requested_at_unix:3500}')")" \
  && pass "worker reclaimed stale inbox lease" || fail "stale reclaim failed"
[ "$(printf '%s' "$RECLAIMED" | jq -r '.status // empty')" = "received" ] && pass "stale reclaim returned received state" || fail "stale reclaim status mismatch: $RECLAIMED"
require_post_status STALE_ACK_CODE "ack with stale pre-reclaim lease" "/workers/$WORKER/inbox/ack" "$(jq -cn --arg envelope_ref "$INBOX_REL_REF" --arg lease_ref "$REL2_LEASE" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref}')"
assert_rejected_not_missing "ack with stale pre-reclaim lease" "$STALE_ACK_CODE"

CLAIM_DLQ="$(post_json "/workers/$WORKER/inbox/claim" "$(jq -cn --arg envelope_ref "$INBOX_REL_REF" '{envelope_ref:$envelope_ref,lease_id:"inbox-dlq-lease",requested_at_unix:3600}')")" \
  && pass "worker claimed inbox item for dead-letter" || fail "claim for dead-letter failed"
DLQ_LEASE="$(printf '%s' "$CLAIM_DLQ" | jq -r '.lease_ref // empty')"
DEAD="$(post_json "/workers/$WORKER/inbox/dead-letter" "$(jq -cn --arg envelope_ref "$INBOX_REL_REF" --arg lease_ref "$DLQ_LEASE" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,reason_ref:"reason://scenario/136/operator",requested_at_unix:3610}')")" \
  && pass "worker dead-lettered inbox item" || fail "inbox dead-letter failed"
[ "$(printf '%s' "$DEAD" | jq -r '.status // empty')" = "dead_lettered" ] && pass "inbox dead-letter returned terminal state" || fail "dead-letter status mismatch: $DEAD"
REQUEUED="$(post_json "/operators/$OPERATOR/inbox/requeue" "$(jq -cn --arg envelope_ref "$INBOX_REL_REF" '{envelope_ref:$envelope_ref,reason_ref:"reason://scenario/136/retry",requested_at_unix:3700,clear_last_error:true}')")" \
  && pass "operator requeued dead-lettered inbox item" || fail "inbox requeue failed"
[ "$(printf '%s' "$REQUEUED" | jq -r '.status // empty')" = "received" ] && pass "inbox requeue returned received state" || fail "requeue status mismatch: $REQUEUED"

STATUS="$(status_query "$(jq -cn --arg ack "$INBOX_ACK_REF" '{queue:"inbox",envelope_ref:$ack,limit:10}')")" && pass "inbox status query succeeded" || fail "inbox status query failed"
printf '%s' "$STATUS" | jq -e '.count == 1 and .items[0].status == "acked"' >/dev/null && pass "acked inbox item visible in status" || fail "acked status mismatch: $STATUS"
REL_STATUS="$(status_query "$(jq -cn --arg ref "$INBOX_REL_REF" '{queue:"inbox",envelope_ref:$ref,limit:10}')")" && pass "requeued status query succeeded" || fail "requeued status query failed"
printf '%s' "$REL_STATUS" | jq -e '.count == 1 and .items[0].status == "received" and .items[0].requeue_count == 1' >/dev/null && pass "requeued inbox item visible with lineage" || fail "requeue status mismatch: $REL_STATUS"

stop_server
if start_server; then pass "workflow server restarted against same SQLite store"; else fail "workflow server did not restart; see $SERVER_LOG"; finish; exit 1; fi
status_query "$(jq -cn --arg ref "$INBOX_ACK_REF" '{queue:"inbox",envelope_ref:$ref,limit:10}')" | jq -e '.count == 1 and .items[0].status == "acked"' >/dev/null \
  && pass "acked inbox state survived restart" || fail "acked inbox state missing after restart"
status_query "$(jq -cn --arg ref "$INBOX_REL_REF" '{queue:"inbox",envelope_ref:$ref,limit:10}')" | jq -e '.count == 1 and .items[0].status == "received" and .items[0].requeue_count == 1' >/dev/null \
  && pass "requeued inbox state survived restart" || fail "requeued inbox state missing after restart"

finish
