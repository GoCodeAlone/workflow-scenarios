#!/usr/bin/env bash
# Scenario 132 - Signal outbox DLQ.
#
# Demonstration-fidelity: starts the real Workflow server, builds/loads released
# workflow-plugin-signal v0.33.0 by default, uses a scenario-owned SQLite
# envelope store, drives dead-letter behavior via HTTP, restarts the server, and
# proves dead-letter state persists.
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
WORKER="${WORKER:-signal-dlq-worker}"
SPACE="${SPACE:-private-space-132}"
PLAINTEXT_B64="${PLAINTEXT_B64:-c2lnbmFsIG91dGJveCBkbHEgcHJvb2YgMTMy}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18132}"
RAW_ERROR="raw downstream failure with bearer-token"
SAFE_REASON="reason://scenario/132/invalid-route"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG_TEMPLATE="$SCENARIO_DIR/config/app.yaml"
BODY_FILE="${TMPDIR:-/tmp}/scenario-132-http-body-$$"

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

plugin_repo_supports_dlq() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.version == "0.33.0") and
    (.capabilities.moduleTypes | index("signal.envelope_store")) and
    (.capabilities.stepTypes | index("step.signal_envelope_status")) and
    (.capabilities.stepTypes | index("step.signal_outbox_dead_letter")) and
    (.capabilities.stepTypes | index("step.signal_outbox_handoff")) and
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
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_dlq "$plugin_repo"; then
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
echo "=== Scenario 132 - Signal Outbox DLQ ==="
echo ""

[ -f "$CONFIG_TEMPLATE" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if grep -Eiq 'ali''ce|bo''b' "$CONFIG_TEMPLATE" "$0"; then
  fail "Workflow scenario should not bake fixed demo participant names"
else
  pass "Workflow API and test runner are participant-parametric"
fi
for step_type in step.signal_outbox_enqueue step.signal_outbox_claim step.signal_outbox_handoff step.signal_outbox_release step.signal_outbox_dead_letter step.signal_envelope_status; do
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

EXPLICIT_SEND="$(send_envelope "dlq-explicit")" && pass "explicit DLQ fixture enqueued" || fail "explicit DLQ send failed"
EXPLICIT_REF="$(printf '%s' "$EXPLICIT_SEND" | jq -r '.envelope_ref // empty')"
EXPLICIT_CLAIM="$(post_json "/workers/$WORKER/outbox/claim" "$(jq -cn --arg envelope_ref "$EXPLICIT_REF" '{envelope_ref:$envelope_ref,lease_id:"dlq-explicit-lease",requested_at_unix:3000}')")" \
  && pass "explicit DLQ fixture claimed" || fail "explicit DLQ claim failed"
EXPLICIT_LEASE="$(printf '%s' "$EXPLICIT_CLAIM" | jq -r '.lease_ref // empty')"
BAD_DLQ_CODE="$(post_status "/workers/$WORKER/outbox/dead-letter" "$(jq -cn --arg envelope_ref "$EXPLICIT_REF" --arg reason "$SAFE_REASON" '{envelope_ref:$envelope_ref,lease_ref:"lease://wrong",reason_ref:$reason}')")"
assert_rejected_not_missing "dead-letter with mismatched lease" "$BAD_DLQ_CODE"
EXPLICIT_DLQ="$(post_json "/workers/$WORKER/outbox/dead-letter" "$(jq -cn --arg envelope_ref "$EXPLICIT_REF" --arg lease_ref "$EXPLICIT_LEASE" --arg reason "$SAFE_REASON" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,reason_ref:$reason,requested_at_unix:3100}')")" \
  && pass "explicit dead-letter transitioned through Workflow API" || fail "explicit dead-letter failed"
[ "$(printf '%s' "$EXPLICIT_DLQ" | jq -r '.status // empty')" = "dead_lettered" ] && pass "explicit dead-letter returned terminal status" || fail "explicit DLQ status mismatch: $EXPLICIT_DLQ"
assert_no_marker "dead-letter response" "$EXPLICIT_DLQ" "$PLAINTEXT_B64"
EXPLICIT_STATUS="$(status_for "$EXPLICIT_REF")" && pass "explicit dead-letter status query succeeded" || fail "explicit dead-letter status query failed"
[ "$(printf '%s' "$EXPLICIT_STATUS" | jq -r '.items[0].status // empty')" = "dead_lettered" ] && pass "explicit status reported dead-letter terminal state" || fail "explicit status mismatch: $EXPLICIT_STATUS"
[ "$(printf '%s' "$EXPLICIT_STATUS" | jq -r '.items[0].reason_ref // empty')" = "$SAFE_REASON" ] && pass "explicit status exposed safe reason ref" || fail "explicit reason mismatch: $EXPLICIT_STATUS"
assert_no_marker "explicit status" "$EXPLICIT_STATUS" "$PLAINTEXT_B64"
assert_no_marker "explicit status" "$EXPLICIT_STATUS" "custody://"
assert_no_marker "explicit status" "$EXPLICIT_STATUS" "authz://"
assert_no_marker "explicit status" "$EXPLICIT_STATUS" "$EXPLICIT_LEASE"

for path in claim handoff ack release; do
  case "$path" in
    claim) code="$(post_status "/workers/$WORKER/outbox/claim" "$(jq -cn --arg envelope_ref "$EXPLICIT_REF" '{envelope_ref:$envelope_ref,lease_id:"after-dlq"}')")" ;;
    handoff) code="$(post_status "/workers/$WORKER/outbox/handoff" "$(jq -cn --arg envelope_ref "$EXPLICIT_REF" '{envelope_ref:$envelope_ref,lease_id:"after-dlq",delivery_id:"delivery://after-dlq"}')")" ;;
    ack) code="$(post_status "/workers/$WORKER/outbox/ack" "$(jq -cn --arg envelope_ref "$EXPLICIT_REF" --arg lease_ref "$EXPLICIT_LEASE" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref}')")" ;;
    release) code="$(post_status "/workers/$WORKER/outbox/release" "$(jq -cn --arg envelope_ref "$EXPLICIT_REF" --arg lease_ref "$EXPLICIT_LEASE" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,last_error_ref:"error://after-dlq"}')")" ;;
  esac
  assert_rejected_not_missing "dead-lettered envelope $path" "$code"
done

DEFAULT_SEND="$(send_envelope "dlq-default-max")" && pass "default max fixture enqueued" || fail "default max send failed"
DEFAULT_REF="$(printf '%s' "$DEFAULT_SEND" | jq -r '.envelope_ref // empty')"
DEFAULT_CLAIM="$(post_json "/workers/$WORKER/outbox/claim" "$(jq -cn --arg envelope_ref "$DEFAULT_REF" '{envelope_ref:$envelope_ref,lease_id:"default-max",requested_at_unix:3200}')")" \
  && pass "default max fixture claimed" || fail "default max claim failed"
DEFAULT_LEASE="$(printf '%s' "$DEFAULT_CLAIM" | jq -r '.lease_ref // empty')"
DEFAULT_CODE="$(post_status "/workers/$WORKER/outbox/release" "$(jq -cn --arg envelope_ref "$DEFAULT_REF" --arg lease_ref "$DEFAULT_LEASE" --arg raw "$RAW_ERROR" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,last_error_ref:$raw,max_attempts:1,requested_at_unix:3300}')")"
assert_rejected_not_missing "default max-attempt release without DLQ transition" "$DEFAULT_CODE"
DEFAULT_STATUS="$(status_for "$DEFAULT_REF")"
[ "$(printf '%s' "$DEFAULT_STATUS" | jq -r '.items[0].status // empty')" = "claimed" ] && pass "default max-attempt release left record claimed" || fail "default max status mismatch: $DEFAULT_STATUS"

OPT_SEND="$(send_envelope "dlq-opt-in-max")" && pass "opt-in max fixture enqueued" || fail "opt-in max send failed"
OPT_REF="$(printf '%s' "$OPT_SEND" | jq -r '.envelope_ref // empty')"
OPT_CLAIM="$(post_json "/workers/$WORKER/outbox/claim" "$(jq -cn --arg envelope_ref "$OPT_REF" '{envelope_ref:$envelope_ref,lease_id:"opt-in-max",requested_at_unix:3400}')")" \
  && pass "opt-in max fixture claimed" || fail "opt-in max claim failed"
OPT_LEASE="$(printf '%s' "$OPT_CLAIM" | jq -r '.lease_ref // empty')"
OPT_DLQ="$(post_json "/workers/$WORKER/outbox/release" "$(jq -cn --arg envelope_ref "$OPT_REF" --arg lease_ref "$OPT_LEASE" --arg raw "$RAW_ERROR" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,last_error_ref:$raw,max_attempts:1,dead_letter_on_max_attempts:true,requested_at_unix:3500}')")" \
  && pass "opt-in max-attempt release transitioned to DLQ" || fail "opt-in max release failed"
[ "$(printf '%s' "$OPT_DLQ" | jq -r '.status // empty')" = "dead_lettered" ] && pass "opt-in max release returned dead_lettered" || fail "opt-in DLQ status mismatch: $OPT_DLQ"
OPT_STATUS="$(status_for "$OPT_REF")"
[ "$(printf '%s' "$OPT_STATUS" | jq -r '.items[0].last_error_redacted // false')" = "true" ] && pass "unsafe max-attempt error was redacted in status" || fail "unsafe max error was not redacted: $OPT_STATUS"
assert_no_marker "opt-in status" "$OPT_STATUS" "$RAW_ERROR"
assert_no_marker "opt-in status" "$OPT_STATUS" "$OPT_LEASE"

SNAPSHOT="$(sqlite_snapshot 2>/dev/null)" && pass "SQLite envelope snapshot was written" || fail "SQLite envelope snapshot missing"
assert_no_marker "SQLite snapshot" "$SNAPSHOT" "$PLAINTEXT_B64"
if printf '%s' "$SNAPSHOT" | grep -Fq 'dead_lettered'; then
  pass "SQLite snapshot contains dead-letter terminal state"
else
  fail "SQLite snapshot did not contain dead-letter state"
fi
if printf '%s' "$SNAPSHOT" | grep -Fq "$SAFE_REASON"; then
  pass "SQLite snapshot contains safe dead-letter reason"
else
  fail "SQLite snapshot did not contain safe dead-letter reason"
fi

stop_server
if start_server; then
  pass "workflow server restarted against same SQLite store"
else
  fail "workflow server did not restart; see $SERVER_LOG"
  finish
  exit 1
fi
RESTART_STATUS="$(status_for "$EXPLICIT_REF")" && pass "status query after restart succeeded" || fail "status query after restart failed"
[ "$(printf '%s' "$RESTART_STATUS" | jq -r '.items[0].status // empty')" = "dead_lettered" ] && pass "dead-letter status persisted after restart" || fail "restart status mismatch: $RESTART_STATUS"
[ "$(printf '%s' "$RESTART_STATUS" | jq -r '.items[0].reason_ref // empty')" = "$SAFE_REASON" ] && pass "safe reason ref persisted after restart" || fail "restart reason mismatch: $RESTART_STATUS"
assert_no_marker "restart status" "$RESTART_STATUS" "$PLAINTEXT_B64"
assert_no_marker "restart status" "$RESTART_STATUS" "$EXPLICIT_LEASE"

finish
