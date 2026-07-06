#!/usr/bin/env bash
# Scenario 135 - Signal outbox batch enqueue.
#
# Demonstration-fidelity: starts the real Workflow server, builds/loads released
# workflow-plugin-signal v0.35.1 by default, and drives a participant-parametric
# HTTP route that encrypts two caller-supplied messages and executes
# step.signal_outbox_enqueue_batch against a scenario-owned SQLite store.
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
SPACE="${SPACE:-private-space-135}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18135}"
PLAINTEXT_ONE="${PLAINTEXT_ONE:-c2lnbmFsIGJhdGNoIG1lc3NhZ2Ugb25lIDEzNQ==}"
PLAINTEXT_TWO="${PLAINTEXT_TWO:-c2lnbmFsIGJhdGNoIG1lc3NhZ2UgdHdvIDEzNQ==}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG_TEMPLATE="$SCENARIO_DIR/config/app.yaml"
BODY_FILE="${TMPDIR:-/tmp}/scenario-135-http-body-$$"

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

plugin_repo_supports_batch() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.version == "0.35.1") and
    (.capabilities.moduleTypes | index("signal.envelope_store")) and
    (.capabilities.stepTypes | index("step.signal_session_prepare")) and
    (.capabilities.stepTypes | index("step.signal_encrypt")) and
    (.capabilities.stepTypes | index("step.signal_outbox_enqueue_batch")) and
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
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_batch "$plugin_repo"; then
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

sqlite_snapshot() {
  sqlite3 "$SQLITE_PATH" 'select state_json from signal_envelope_store_snapshots where store_ref = "signal_envelopes";'
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

assert_rejected_not_missing() {
  local label="$1"
  local code="$2"
  if [ "$code" = "200" ] || [ "$code" = "202" ]; then
    fail "$label unexpectedly succeeded"
  elif [ "$code" = "404" ]; then
    fail "$label returned 404; route may be missing: $(cat "$BODY_FILE")"
  else
    pass "$label was rejected with HTTP $code"
  fi
}

batch_body() {
  local batch_ref="$1"
  local first_ref="$2"
  local second_ref="$3"
  local first_key="$4"
  local second_key="$5"
  jq -cn \
    --arg batch_ref "$batch_ref" \
    --arg p1 "$PLAINTEXT_ONE" \
    --arg p2 "$PLAINTEXT_TWO" \
    --arg m1 "$first_ref" \
    --arg m2 "$second_ref" \
    --arg k1 "$first_key" \
    --arg k2 "$second_key" \
    --argjson remote_bundle "$RECIPIENT_BUNDLE" \
    '{batch_ref:$batch_ref,remote_bundle:$remote_bundle,messages:[{message_ref:$m1,plaintext:$p1,idempotency_key:$k1},{message_ref:$m2,plaintext:$p2,idempotency_key:$k2}]}'
}

echo ""
echo "=== Scenario 135 - Signal Outbox Batch Enqueue ==="
echo ""

if [ -f "$CONFIG_TEMPLATE" ]; then
  pass "Workflow app config exists"
else
  fail "Workflow app config missing"
  finish
  exit 1
fi
if grep -Eiq 'ali''ce|bo''b' "$CONFIG_TEMPLATE" "$0"; then
  fail "Workflow scenario should not bake fixed demo participant names"
else
  pass "Workflow API and test runner are participant-parametric"
fi
for step_type in step.signal_session_prepare step.signal_encrypt step.signal_outbox_enqueue_batch step.signal_envelope_status; do
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

require_post_status BAD_CODE "duplicate idempotency batch" "/spaces/$SPACE/participants/$SENDER/outbox-batch/$RECIPIENT" "$(batch_body "batch://scenario/135/bad" "batch-bad-one" "batch-bad-two" "duplicate-key" "duplicate-key")"
assert_rejected_not_missing "duplicate idempotency batch" "$BAD_CODE"
BAD_STATUS="$(status_query "$(jq -cn '{message_ref:"batch-bad-one",limit:10}')")" && pass "status query after rejected batch succeeded" || fail "status query after rejected batch failed"
[ "$(printf '%s' "$BAD_STATUS" | jq -r '.count // 0')" = "0" ] && pass "invalid batch rolled back first item" || fail "invalid batch persisted first item: $BAD_STATUS"

require_post_status BATCH_CODE "valid batch enqueue" "/spaces/$SPACE/participants/$SENDER/outbox-batch/$RECIPIENT" "$(batch_body "batch://scenario/135/good" "batch-good-one" "batch-good-two" "batch-good-one-key" "batch-good-two-key")"
BATCH="$(cat "$BODY_FILE")"
if [ "$BATCH_CODE" = "202" ]; then
  pass "valid batch enqueued through Workflow API"
else
  fail "valid batch enqueue failed with HTTP $BATCH_CODE: $BATCH"
  tail -80 "$SERVER_LOG"
  finish
  exit 1
fi
[ "$(printf '%s' "$BATCH" | jq -r '.enqueued_count // 0')" = "2" ] && pass "batch enqueued two items" || fail "batch enqueue count mismatch: $BATCH"
[ "$(printf '%s' "$BATCH" | jq -r '.rejected_count // 0')" = "0" ] && pass "batch reported no rejections" || fail "batch rejected valid items: $BATCH"
[ "$(printf '%s' "$BATCH" | jq -r '.items | length')" = "2" ] && pass "batch returned two item summaries" || fail "batch item result count mismatch: $BATCH"
FIRST_REF="$(printf '%s' "$BATCH" | jq -r '.items[0].envelope_ref // empty')"
SECOND_REF="$(printf '%s' "$BATCH" | jq -r '.items[1].envelope_ref // empty')"
[ -n "$FIRST_REF" ] && [ -n "$SECOND_REF" ] && pass "batch returned envelope refs" || fail "batch envelope refs missing: $BATCH"

FIRST_STATUS="$(status_query "$(jq -cn '{message_ref:"batch-good-one",limit:10}')")" && pass "first batch item status query succeeded" || fail "first status query failed"
SECOND_STATUS="$(status_query "$(jq -cn '{message_ref:"batch-good-two",limit:10}')")" && pass "second batch item status query succeeded" || fail "second status query failed"
printf '%s' "$FIRST_STATUS" | jq -e '.count == 1 and .items[0].status == "queued"' >/dev/null && pass "first batch item persisted queued" || fail "first status mismatch: $FIRST_STATUS"
printf '%s' "$SECOND_STATUS" | jq -e '.count == 1 and .items[0].status == "queued"' >/dev/null && pass "second batch item persisted queued" || fail "second status mismatch: $SECOND_STATUS"
assert_no_marker "batch status" "$FIRST_STATUS$SECOND_STATUS" "$PLAINTEXT_ONE"
assert_no_marker "batch status" "$FIRST_STATUS$SECOND_STATUS" "$PLAINTEXT_TWO"
assert_no_marker "batch status" "$FIRST_STATUS$SECOND_STATUS" "custody://"
assert_no_marker "batch status" "$FIRST_STATUS$SECOND_STATUS" "authz://"

require_post_status DUP_CODE "second encrypted batch with reused idempotency keys" "/spaces/$SPACE/participants/$SENDER/outbox-batch/$RECIPIENT" "$(batch_body "batch://scenario/135/duplicate" "batch-good-one" "batch-good-two" "batch-good-one-key" "batch-good-two-key")"
assert_rejected_not_missing "second encrypted batch with reused idempotency keys" "$DUP_CODE"
TOTAL_STATUS="$(status_query "$(jq -cn --arg sender "participant://$SENDER" '{queue:"outbox",sender_ref:$sender,limit:10}')")" && pass "sender status query succeeded" || fail "sender status query failed"
[ "$(printf '%s' "$TOTAL_STATUS" | jq -r '.count // 0')" = "2" ] && pass "duplicate retry did not create extra items" || fail "duplicate retry mutated outbox: $TOTAL_STATUS"

SNAPSHOT="$(sqlite_snapshot 2>/dev/null)" && pass "SQLite envelope snapshot was written" || fail "SQLite envelope snapshot missing"
printf '%s' "$SNAPSHOT" | grep -Fq "$FIRST_REF" && printf '%s' "$SNAPSHOT" | grep -Fq "$SECOND_REF" \
  && pass "SQLite snapshot contains both batch envelope refs" || fail "SQLite snapshot missing batch refs"
assert_no_marker "SQLite snapshot" "$SNAPSHOT" "$PLAINTEXT_ONE"
assert_no_marker "SQLite snapshot" "$SNAPSHOT" "$PLAINTEXT_TWO"

stop_server
if start_server; then
  pass "workflow server restarted against same SQLite store"
else
  fail "workflow server did not restart; see $SERVER_LOG"
  finish
  exit 1
fi
status_query "$(jq -cn '{message_ref:"batch-good-one",limit:10}')" | jq -e '.count == 1 and .items[0].status == "queued"' >/dev/null \
  && pass "first batch item survived restart" || fail "first batch item missing after restart"
status_query "$(jq -cn '{message_ref:"batch-good-two",limit:10}')" | jq -e '.count == 1 and .items[0].status == "queued"' >/dev/null \
  && pass "second batch item survived restart" || fail "second batch item missing after restart"

finish
