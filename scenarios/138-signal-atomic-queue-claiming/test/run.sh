#!/usr/bin/env bash
# Scenario 138 - Signal atomic queue claiming.
#
# Demonstration-fidelity: starts the real Workflow server, builds/loads released
# workflow-plugin-signal v0.36.0 by default, and drives participant-parametric
# HTTP routes that execute outbox claim-next, claim-batch, release, ack, and
# status checks against a SQLite envelope store.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.36.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi

SENDER="${SENDER:-user-a}"
RECIPIENT="${RECIPIENT:-user-b}"
WORKER="${WORKER:-signal-queue-worker}"
OPERATOR="${OPERATOR:-signal-queue-operator}"
SPACE="${SPACE:-private-space-138}"
PLAINTEXT_B64="${PLAINTEXT_B64:-c2lnbmFsIGluYm94IGxpZmVjeWNsZSBwcm9vZiAxMzY=}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18138}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG_TEMPLATE="$SCENARIO_DIR/config/app.yaml"
BODY_FILE="${TMPDIR:-/tmp}/scenario-138-http-body-$$"

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

plugin_repo_supports_atomic_claiming() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.version == "0.36.0") and
    (.capabilities.moduleTypes | index("signal.envelope_store")) and
    (.capabilities.stepTypes | index("step.signal_outbox_claim_next")) and
    (.capabilities.stepTypes | index("step.signal_outbox_claim_batch")) and
    (.capabilities.stepTypes | index("step.signal_outbox_release")) and
    (.capabilities.stepTypes | index("step.signal_outbox_ack")) and
    (.capabilities.stepTypes | index("step.signal_envelope_status"))
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
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_atomic_claiming "$plugin_repo"; then
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
echo "=== Scenario 138 - Signal Atomic Queue Claiming ==="
echo ""

[ -f "$CONFIG_TEMPLATE" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if grep -Eiq 'ali''ce|bo''b' "$CONFIG_TEMPLATE" "$0"; then
  fail "Workflow scenario should not bake fixed demo participant names"
else
  pass "Workflow API and test runner are participant-parametric"
fi
for step_type in step.signal_outbox_claim_next step.signal_outbox_claim_batch step.signal_outbox_release step.signal_outbox_ack step.signal_envelope_status; do
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

SEND_FIRST="$(send_envelope "claim-next-first")" && pass "sender enqueued first claim-next fixture" || fail "first send failed"
FIRST_REF="$(printf '%s' "$SEND_FIRST" | jq -r '.envelope_ref // empty')"
SEND_SECOND="$(send_envelope "claim-next-second")" && pass "sender enqueued second claim-next fixture" || fail "second send failed"
SECOND_REF="$(printf '%s' "$SEND_SECOND" | jq -r '.envelope_ref // empty')"
CLAIM_NEXT="$(post_json "/workers/$WORKER/outbox/claim-next" "$(jq -cn '{lease_id:"next-lease-1",requested_at_unix:3000,status:"queued"}')")" \
  && pass "worker claimed next queued outbox item through Workflow API" || fail "claim-next failed"
NEXT_REF="$(printf '%s' "$CLAIM_NEXT" | jq -r '.envelope_ref // empty')"
NEXT_LEASE="$(printf '%s' "$CLAIM_NEXT" | jq -r '.lease_ref // empty')"
[ "$NEXT_REF" = "$FIRST_REF" ] && pass "claim-next selected oldest eligible envelope" || fail "claim-next selected $NEXT_REF, want $FIRST_REF"
[ -n "$NEXT_LEASE" ] && pass "claim-next returned lease ref" || fail "claim-next lease missing: $CLAIM_NEXT"
require_post_status SECOND_CLAIM_CODE "second worker claim of claimed envelope" "/workers/$WORKER/outbox/claim-next" "$(jq -cn --arg ref "$FIRST_REF" '{lease_id:"next-lease-conflict",message_ref:"claim-next-first",requested_at_unix:3001,status:"queued"}')"
assert_rejected_not_missing "second worker claim of claimed envelope" "$SECOND_CLAIM_CODE"
ACKED_NEXT="$(post_json "/workers/$WORKER/outbox/ack" "$(jq -cn --arg envelope_ref "$FIRST_REF" --arg lease_ref "$NEXT_LEASE" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,requested_at_unix:3010}')")" \
  && pass "worker acked claim-next item" || fail "outbox ack after claim-next failed"
[ "$(printf '%s' "$ACKED_NEXT" | jq -r '.status // empty')" = "acked" ] && pass "claim-next item reached terminal acked status" || fail "claim-next ack status mismatch: $ACKED_NEXT"
require_post_status TERMINAL_CLAIM_CODE "claim-next skips terminal acked envelope" "/workers/$WORKER/outbox/claim-next" "$(jq -cn '{lease_id:"next-terminal",message_ref:"claim-next-first",requested_at_unix:3020,status:"queued"}')"
assert_rejected_not_missing "claim-next skips terminal acked envelope" "$TERMINAL_CLAIM_CODE"

SEND_THIRD="$(send_envelope "claim-batch-third")" && pass "sender enqueued first batch fixture" || fail "third send failed"
THIRD_REF="$(printf '%s' "$SEND_THIRD" | jq -r '.envelope_ref // empty')"
SEND_FOURTH="$(send_envelope "claim-batch-fourth")" && pass "sender enqueued second batch fixture" || fail "fourth send failed"
FOURTH_REF="$(printf '%s' "$SEND_FOURTH" | jq -r '.envelope_ref // empty')"
BATCH="$(post_json "/workers/$WORKER/outbox/claim-batch" "$(jq -cn '{lease_id:"batch-lease",requested_at_unix:3100,status:"queued",limit:2}')")" \
  && pass "worker claimed queued batch through Workflow API" || fail "claim-batch failed"
printf '%s' "$BATCH" | jq -e '.claimed_count == 2 and (.items | length) == 2' >/dev/null \
  && pass "claim-batch returned two claimed items" || fail "claim-batch count mismatch: $BATCH"
printf '%s' "$BATCH" | jq -e --arg first "$FIRST_REF" 'all(.items[].envelope_ref; . != $first)' >/dev/null \
  && pass "claim-batch did not reclaim terminal acked item" || fail "claim-batch included terminal item: $BATCH"
BATCH_FIRST_REF="$(printf '%s' "$BATCH" | jq -r '.items[0].envelope_ref // empty')"
BATCH_SECOND_REF="$(printf '%s' "$BATCH" | jq -r '.items[1].envelope_ref // empty')"
BATCH_FIRST_LEASE="$(printf '%s' "$BATCH" | jq -r '.items[0].lease_ref // empty')"
BATCH_SECOND_LEASE="$(printf '%s' "$BATCH" | jq -r '.items[1].lease_ref // empty')"
post_json "/workers/$WORKER/outbox/release" "$(jq -cn --arg envelope_ref "$BATCH_FIRST_REF" --arg lease_ref "$BATCH_FIRST_LEASE" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,last_error_ref:"error://scenario/138/retry",requested_at_unix:3110}')" >/dev/null \
  && pass "worker released first batch item" || fail "first batch release failed"
post_json "/workers/$WORKER/outbox/ack" "$(jq -cn --arg envelope_ref "$BATCH_SECOND_REF" --arg lease_ref "$BATCH_SECOND_LEASE" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,requested_at_unix:3120}')" >/dev/null \
  && pass "worker acked second batch item" || fail "second batch ack failed"
RECLAIM="$(post_json "/workers/$WORKER/outbox/claim-next" "$(jq -cn '{lease_id:"next-after-release",requested_at_unix:3130,status:"queued"}')")" \
  && pass "claim-next reclaimed released batch item" || fail "claim-next after release failed"
[ "$(printf '%s' "$RECLAIM" | jq -r '.envelope_ref // empty')" = "$BATCH_FIRST_REF" ] && pass "released item became eligible again" || fail "released item was not next: $RECLAIM"

STATUS="$(status_query "$(jq -cn '{queue:"outbox",limit:20}')")" && pass "outbox status query succeeded" || fail "outbox status query failed"
printf '%s' "$STATUS" | jq -e '.count >= 4' >/dev/null && pass "outbox status sees scenario records" || fail "outbox status count mismatch: $STATUS"
assert_no_marker "outbox status response" "$STATUS" "$PLAINTEXT_B64"
assert_no_marker "outbox status response" "$STATUS" "custody://"
assert_no_marker "outbox status response" "$STATUS" "authz://"

stop_server
if start_server; then pass "workflow server restarted against same SQLite store"; else fail "workflow server did not restart; see $SERVER_LOG"; finish; exit 1; fi
status_query "$(jq -cn --arg ref "$FIRST_REF" '{queue:"outbox",envelope_ref:$ref,limit:10}')" | jq -e '.count == 1 and .items[0].status == "acked"' >/dev/null \
  && pass "acked claim-next state survived restart" || fail "acked claim-next state missing after restart"
status_query "$(jq -cn --arg ref "$BATCH_FIRST_REF" '{queue:"outbox",envelope_ref:$ref,limit:10}')" | jq -e '.count == 1 and .items[0].status == "claimed"' >/dev/null \
  && pass "reclaimed outbox state survived restart" || fail "reclaimed outbox state missing after restart"
status_query "$(jq -cn '{queue:"outbox",limit:20}')" | jq -e '.count >= 4' >/dev/null \
  && pass "outbox state survived restart" || fail "outbox state missing after restart"

finish
