#!/usr/bin/env bash
# Scenario 140 - Signal device directory fanout.
#
# Demonstration-fidelity: starts the real Workflow server, builds/loads released
# workflow-plugin-signal v0.36.0 by default, and drives participant-parametric
# HTTP routes that publish, list, revoke, and fan out devices through a
# scenario-owned local-file signal.device_directory.
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
SPACE="${SPACE:-private-space-140}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18140}"
ACCOUNT="${ACCOUNT:-team-device-140}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG_TEMPLATE="$SCENARIO_DIR/config/app.yaml"
BODY_FILE="${TMPDIR:-/tmp}/scenario-140-http-body-$$"

PASS=0
FAIL=0
SERVER_PID=""
DATA_DIR=""
RUNTIME_CONFIG=""
SQLITE_PATH=""
DEVICE_DIR_PATH=""
SERVER_START_COUNT=0
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

plugin_repo_supports_device_directory() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.version == "0.36.0") and
    (.capabilities.moduleTypes | index("signal.device_directory")) and
    (.capabilities.stepTypes | index("step.signal_session_prepare")) and
    (.capabilities.stepTypes | index("step.signal_device_publish")) and
    (.capabilities.stepTypes | index("step.signal_device_list")) and
    (.capabilities.stepTypes | index("step.signal_device_revoke")) and
    (.capabilities.stepTypes | index("step.signal_device_fanout_prepare"))
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
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_device_directory "$plugin_repo"; then
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
  SERVER_START_COUNT=$((SERVER_START_COUNT + 1))
  SERVER_LOG="$SCRIPT_DIR/artifacts/server-$SERVER_START_COUNT.log"
  mkdir -p "$(dirname "$SERVER_LOG")"
  rm -f "$SCRIPT_DIR/artifacts/last-server.log"
  ln -s "$(basename "$SERVER_LOG")" "$SCRIPT_DIR/artifacts/last-server.log"
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
echo "=== Scenario 140 - Signal Device Directory Fanout ==="
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
for step_type in step.signal_session_prepare step.signal_device_publish step.signal_device_list step.signal_device_revoke step.signal_device_fanout_prepare; do
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
DEVICE_DIR_PATH="$DATA_DIR/devices.json"
RUNTIME_CONFIG="$DATA_DIR/app.yaml"
sed -e "s#__SQLITE_PATH__#$SQLITE_PATH#g" -e "s#__DEVICE_DIR_PATH__#$DEVICE_DIR_PATH#g" "$CONFIG_TEMPLATE" >"$RUNTIME_CONFIG" || {
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

BUNDLE_ONE="$(post_json "/participants/user-a/session" '{}')" && pass "prepared first device bundle through Workflow API" || fail "first bundle failed"
BUNDLE_TWO="$(post_json "/participants/user-b/session" '{}')" && pass "prepared second device bundle through Workflow API" || fail "second bundle failed"
BUNDLE_THREE="$(post_json "/participants/user-c/session" '{}')" && pass "prepared third device bundle through Workflow API" || fail "third bundle failed"
DEVICE_ONE_BODY="$(printf '%s' "$BUNDLE_ONE" | jq -c --arg key "publish-$ACCOUNT-1" '{identity_ref:.bundle.identity_ref,device_id:.bundle.device_id,bundle:.bundle,idempotency_key:$key,operator:"scenario-140"}')"
DEVICE_TWO_BODY="$(printf '%s' "$BUNDLE_TWO" | jq -c --arg key "publish-$ACCOUNT-2" '{identity_ref:.bundle.identity_ref,device_id:2,bundle:(.bundle + {device_id:2}),idempotency_key:$key,operator:"scenario-140"}')"
DEVICE_THREE_BODY="$(printf '%s' "$BUNDLE_THREE" | jq -c --arg key "publish-$ACCOUNT-3" '{identity_ref:.bundle.identity_ref,device_id:3,bundle:(.bundle + {device_id:3}),idempotency_key:$key,operator:"scenario-140"}')"

PUBLISH_ONE="$(post_json "/accounts/$ACCOUNT/devices/one/publish" "$DEVICE_ONE_BODY")" && pass "published first device through Workflow API" || fail "first publish failed"
PUBLISH_TWO="$(post_json "/accounts/$ACCOUNT/devices/two/publish" "$DEVICE_TWO_BODY")" && pass "published second device through Workflow API" || fail "second publish failed"
PUBLISH_THREE="$(post_json "/accounts/$ACCOUNT/devices/three/publish" "$DEVICE_THREE_BODY")" && pass "published third device through Workflow API" || fail "third publish failed"
[ "$(printf '%s' "$PUBLISH_ONE" | jq -r '.status // empty')" = "active" ] \
  && [ "$(printf '%s' "$PUBLISH_TWO" | jq -r '.status // empty')" = "active" ] \
  && [ "$(printf '%s' "$PUBLISH_THREE" | jq -r '.status // empty')" = "active" ] \
  && pass "all published devices are active" || fail "publish statuses mismatch"
REPLAY_ONE="$(post_json "/accounts/$ACCOUNT/devices/one/publish" "$DEVICE_ONE_BODY")" && pass "identical publish replay succeeded" || fail "identical publish replay failed"
[ "$(printf '%s' "$REPLAY_ONE" | jq -r '.existing // false')" = "true" ] && pass "identical publish replay reported existing" || fail "publish replay did not report existing: $REPLAY_ONE"
BAD_DEVICE_BODY="$(printf '%s' "$DEVICE_ONE_BODY" | jq -c '.identity_ref = "identity://scenario/140/changed"')"
require_post_status BAD_DEVICE_CODE "mismatched same-device publish replay" "/accounts/$ACCOUNT/devices/one/publish" "$BAD_DEVICE_BODY"
assert_rejected_not_missing "mismatched same-device publish replay" "$BAD_DEVICE_CODE"

LIST_ACTIVE="$(post_json "/accounts/$ACCOUNT/devices" '{}')" && pass "listed active devices through Workflow API" || fail "device list failed"
printf '%s' "$LIST_ACTIVE" | jq -e '.count == 3' >/dev/null && pass "device list returned three active devices" || fail "device list mismatch: $LIST_ACTIVE"
REVOKED="$(post_json "/accounts/$ACCOUNT/devices/two/revoke" "$(jq -cn '{reason_ref:"reason://scenario/140/lost",requested_at_unix:2200}')")" \
  && pass "revoked second device through Workflow API" || fail "device revoke failed"
[ "$(printf '%s' "$REVOKED" | jq -r '.status // empty')" = "revoked" ] && pass "device revoke returned revoked status" || fail "revoke status mismatch: $REVOKED"
FANOUT="$(post_json "/accounts/$ACCOUNT/fanout" "$(jq -cn '{message_ref:"message://scenario/140/fanout",limit:10}')")" \
  && pass "prepared fanout through Workflow API" || fail "fanout prepare failed"
printf '%s' "$FANOUT" | jq -e '.recipient_count == 2 and ([.recipients[].device_ref] | index("device://team-device-140/two") | not)' >/dev/null \
  && pass "fanout excluded revoked device" || fail "fanout included revoked or wrong count: $FANOUT"
assert_no_marker "fanout response" "$FANOUT" "private_key"
assert_no_marker "fanout response" "$FANOUT" "custody://"
assert_no_marker "fanout response" "$FANOUT" "authz://"

[ -f "$DEVICE_DIR_PATH" ] && pass "device directory local-file snapshot was written" || fail "device directory snapshot missing"
SNAPSHOT="$(cat "$DEVICE_DIR_PATH")"
printf '%s' "$SNAPSHOT" | grep -Fq "device://$ACCOUNT/one" && pass "snapshot contains published device refs" || fail "snapshot missing device refs"
assert_no_marker "device directory snapshot" "$SNAPSHOT" "private_key"
assert_no_marker "device directory snapshot" "$SNAPSHOT" "custody://"
assert_no_marker "device directory snapshot" "$SNAPSHOT" "authz://"
assert_no_marker "device directory snapshot" "$SNAPSHOT" "credential://scenario/140/must-not-persist"

stop_server
if start_server; then
  pass "workflow server restarted against same device directory file"
else
  fail "workflow server did not restart; see $SERVER_LOG"
  finish
  exit 1
fi
post_json "/accounts/$ACCOUNT/devices" '{}' | jq -e '.count == 2' >/dev/null \
  && pass "active device list survived restart" || fail "device list missing after restart"

stop_server
printf '%s' '{"schema_version":999,"checksum":"bad","state":{}}' >"$DEVICE_DIR_PATH"
if start_server; then
  fail "corrupt device directory snapshot unexpectedly started"
else
  pass "corrupt device directory snapshot failed closed"
fi

finish
