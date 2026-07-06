#!/usr/bin/env bash
# Scenario 126 - Signal envelope HTTP-store persistence.
#
# Demonstration-fidelity: this starts a local mock for the host-managed HTTP
# snapshot dependency, starts the real Workflow server with an http
# signal.envelope_store, drives separate sender/worker/recipient API calls,
# restarts the app, and proves queued, released, and acked state survives
# through the plugin's HTTP backend.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.30.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
SENDER="${SENDER:-user-a}"
RECIPIENT="${RECIPIENT:-user-b}"
WORKER="${WORKER:-http-worker}"
SPACE="${SPACE:-private-space-126}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18126}"
HTTP_STORE_ADDR="${HTTP_STORE_ADDR:-127.0.0.1:19126}"
HTTP_STORE_ENDPOINT="${HTTP_STORE_ENDPOINT:-http://$HTTP_STORE_ADDR}"
SIGNAL_HTTP_STORE_TOKEN="${SIGNAL_HTTP_STORE_TOKEN:-scenario-126-token}"
export SIGNAL_HTTP_STORE_TOKEN
PLAINTEXT_QUEUED_B64="${PLAINTEXT_QUEUED_B64:-c2lnbmFsIGh0dHAgcXVldWVkIHByb29mIDEyNg==}"
PLAINTEXT_RELEASED_B64="${PLAINTEXT_RELEASED_B64:-c2lnbmFsIGh0dHAgcmVsZWFzZWQgcHJvb2YgMTI2}"
PLAINTEXT_ACKED_B64="${PLAINTEXT_ACKED_B64:-c2lnbmFsIGh0dHAgYWNrZWQgcHJvb2YgMTI2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG_TEMPLATE="$SCENARIO_DIR/config/app.yaml"

PASS=0
FAIL=0
SERVER_PID=""
MOCK_PID=""
DATA_DIR=""
RUNTIME_CONFIG=""
HTTP_STORE_STATE=""
HTTP_STORE_BIN=""
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
stop_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  SERVER_PID=""
}
stop_mock() {
  if [ -n "$MOCK_PID" ] && kill -0 "$MOCK_PID" >/dev/null 2>&1; then
    kill "$MOCK_PID" >/dev/null 2>&1 || true
    wait "$MOCK_PID" >/dev/null 2>&1 || true
  fi
  MOCK_PID=""
}
cleanup() {
  stop_server
  stop_mock
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

plugin_repo_supports_http_lifecycle() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.capabilities.moduleTypes | index("signal.envelope_store")) and
    (.capabilities.stepTypes | index("step.signal_session_prepare")) and
    (.capabilities.stepTypes | index("step.signal_encrypt")) and
    (.capabilities.stepTypes | index("step.signal_outbox_enqueue")) and
    (.capabilities.stepTypes | index("step.signal_outbox_claim")) and
    (.capabilities.stepTypes | index("step.signal_outbox_release")) and
    (.capabilities.stepTypes | index("step.signal_inbox_receive")) and
    (.capabilities.stepTypes | index("step.signal_outbox_ack")) and
    (.capabilities.stepTypes | index("step.signal_inbox_decrypt"))
  ' "$repo/plugin.json" >/dev/null 2>&1 || return 1
  grep -q 'endpoint_url' "$repo/internal/contracts/signal.proto" 2>/dev/null &&
    grep -q 'allow_insecure_http' "$repo/internal/contracts/signal.proto" 2>/dev/null
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
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_http_lifecycle "$plugin_repo"; then
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
  "$SERVER_BIN" -config "$RUNTIME_CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  wait_for_server "$BASE_URL"
}

wait_for_mock() {
  local i
  for i in $(seq 1 80); do
    curl -fs "http://$HTTP_STORE_ADDR/healthz" >/dev/null 2>&1 && return 0
    if [ -n "$MOCK_PID" ] && ! kill -0 "$MOCK_PID" >/dev/null 2>&1; then
      return 1
    fi
    sleep 0.25
  done
  return 1
}

start_mock() {
  MOCK_LOG="$SCRIPT_DIR/artifacts/last-http-store.log"
  mkdir -p "$(dirname "$MOCK_LOG")"
  if [ -z "$HTTP_STORE_BIN" ]; then
    HTTP_STORE_BIN="$DATA_DIR/bin/signal-http-store-mock"
    mkdir -p "$(dirname "$HTTP_STORE_BIN")"
    (cd "$SCENARIO_DIR" && go build -o "$HTTP_STORE_BIN" ./mock) || return 1
  fi
  "$HTTP_STORE_BIN" \
    --addr "$HTTP_STORE_ADDR" \
    --path "$HTTP_STORE_STATE" \
    --auth-header X-Workflow-Signal-Store-Token \
    --auth-token "$SIGNAL_HTTP_STORE_TOKEN" >"$MOCK_LOG" 2>&1 &
  MOCK_PID=$!
  wait_for_mock
}

post_json() {
  local path="$1"
  local body="$2"
  curl -fsS -X POST "$BASE_URL$path" -H 'Content-Type: application/json' -d "$body"
}

post_status() {
  local path="$1"
  local body="$2"
  curl -sS -o /tmp/scenario-126-http-body -w "%{http_code}" \
    -X POST "$BASE_URL$path" -H 'Content-Type: application/json' -d "$body"
}

post_store_control() {
  local path="$1"
  curl -fsS -X POST "$HTTP_STORE_ENDPOINT$path" -H "X-Workflow-Signal-Store-Token: $SIGNAL_HTTP_STORE_TOKEN"
}

send_envelope() {
  local message_ref="$1"
  local plaintext="$2"
  local body
  body="$(jq -cn --arg plaintext "$plaintext" --arg message_ref "$message_ref" --argjson remote_bundle "$RECIPIENT_BUNDLE" \
    '{plaintext:$plaintext,message_ref:$message_ref,remote_bundle:$remote_bundle}')"
  post_json "/spaces/$SPACE/participants/$SENDER/outbox/$RECIPIENT" "$body"
}

claim_envelope() {
  local envelope_ref="$1"
  local lease_id="$2"
  local body
  body="$(jq -cn --arg envelope_ref "$envelope_ref" --arg lease_id "$lease_id" '{envelope_ref:$envelope_ref,lease_id:$lease_id}')"
  post_json "/workers/$WORKER/outbox/claim" "$body"
}

release_envelope() {
  local envelope_ref="$1"
  local lease_ref="$2"
  local body
  body="$(jq -cn --arg envelope_ref "$envelope_ref" --arg lease_ref "$lease_ref" \
    '{envelope_ref:$envelope_ref,lease_ref:$lease_ref,last_error_ref:"error://scenario-126/transient"}')"
  post_json "/workers/$WORKER/outbox/release" "$body"
}

deliver_envelope() {
  local envelope_ref="$1"
  local envelope="$2"
  local body
  body="$(jq -cn --arg envelope_ref "$envelope_ref" --argjson envelope "$envelope" '{envelope_ref:$envelope_ref,envelope:$envelope}')"
  post_json "/workers/$WORKER/inbox/deliver/$RECIPIENT" "$body"
}

ack_envelope() {
  local envelope_ref="$1"
  local lease_ref="$2"
  local body
  body="$(jq -cn --arg envelope_ref "$envelope_ref" --arg lease_ref "$lease_ref" '{envelope_ref:$envelope_ref,lease_ref:$lease_ref}')"
  post_json "/workers/$WORKER/outbox/ack" "$body"
}

decrypt_envelope() {
  local envelope_ref="$1"
  local body
  body="$(jq -cn --arg envelope_ref "$envelope_ref" '{envelope_ref:$envelope_ref}')"
  post_json "/participants/$RECIPIENT/inbox/decrypt" "$body"
}

echo ""
echo "=== Scenario 126 - Signal Envelope HTTP Store ==="
echo ""

[ -f "$CONFIG_TEMPLATE" ] && pass "Workflow app config template exists" || fail "Workflow app config template missing"
if grep -Eiq 'ali''ce|bo''b' "$CONFIG_TEMPLATE"; then
  fail "Workflow pipelines should not bake fixed demo participant names"
else
  pass "Workflow API is participant-parametric"
fi
for marker in 'backend: http' 'endpoint_url: __HTTP_STORE_ENDPOINT__' 'auth_header_env: SIGNAL_HTTP_STORE_TOKEN' 'allow_insecure_http: true' 'type: step.signal_outbox_release' 'type: step.signal_outbox_ack'; do
  if grep -q "$marker" "$CONFIG_TEMPLATE"; then
    pass "Workflow app config contains $marker"
  else
    fail "Workflow app config missing $marker"
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
HTTP_STORE_STATE="$DATA_DIR/http-store/state.json"
mkdir -p "$(dirname "$HTTP_STORE_STATE")"
RUNTIME_CONFIG="$DATA_DIR/app.yaml"
sed "s#__HTTP_STORE_ENDPOINT__#$HTTP_STORE_ENDPOINT#g" "$CONFIG_TEMPLATE" >"$RUNTIME_CONFIG"

PLUGIN_DIR="$DATA_DIR/plugins"
if build_plugin "$PLUGIN_DIR"; then
  pass "built workflow-plugin-signal v$PLUGIN_VERSION external plugin"
else
  fail "could not build workflow-plugin-signal v$PLUGIN_VERSION; set SIGNAL_PLUGIN_REPO"
  finish
  exit 1
fi

if start_mock; then
  pass "mock host-managed HTTP store started"
else
  fail "mock HTTP store did not become ready; see $MOCK_LOG"
  finish
  exit 1
fi

if start_server; then
  pass "workflow server started with HTTP envelope store"
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

post_json "/participants/$SENDER/session" '{}' >/dev/null \
  && pass "sender published a pre-key bundle via Workflow API" \
  || fail "sender session prepare API failed"

QUEUED_SENT="$(send_envelope scenario-126-queued "$PLAINTEXT_QUEUED_B64")" \
  && pass "queued envelope was stored in HTTP-backed outbox" \
  || fail "queued envelope send failed"
QUEUED_REF="$(printf '%s' "$QUEUED_SENT" | jq -r '.envelope_ref // empty')"

RELEASED_SENT="$(send_envelope scenario-126-released "$PLAINTEXT_RELEASED_B64")" \
  && pass "released envelope was stored in HTTP-backed outbox" \
  || fail "released envelope send failed"
RELEASED_REF="$(printf '%s' "$RELEASED_SENT" | jq -r '.envelope_ref // empty')"
RELEASED_CLAIM="$(claim_envelope "$RELEASED_REF" scenario-126-release-lease)" \
  && pass "released envelope was claimed before release" \
  || fail "released envelope claim failed"
RELEASED_LEASE="$(printf '%s' "$RELEASED_CLAIM" | jq -r '.lease_ref // empty')"
RELEASED_RELEASE="$(release_envelope "$RELEASED_REF" "$RELEASED_LEASE")" \
  && pass "released envelope returned to queued state before restart" \
  || fail "released envelope release failed"
[ "$(printf '%s' "$RELEASED_RELEASE" | jq -r '.metadata.last_error_ref // empty')" = "error://scenario-126/transient" ] && pass "release wrote ref-only error metadata" || fail "release metadata mismatch: $RELEASED_RELEASE"

ACKED_SENT="$(send_envelope scenario-126-acked "$PLAINTEXT_ACKED_B64")" \
  && pass "acked envelope was stored in HTTP-backed outbox" \
  || fail "acked envelope send failed"
ACKED_REF="$(printf '%s' "$ACKED_SENT" | jq -r '.envelope_ref // empty')"
ACKED_CLAIM="$(claim_envelope "$ACKED_REF" scenario-126-ack-lease)" \
  && pass "acked envelope was claimed before ack" \
  || fail "acked envelope claim failed"
ACKED_LEASE="$(printf '%s' "$ACKED_CLAIM" | jq -r '.lease_ref // empty')"
ACKED_ENVELOPE="$(printf '%s' "$ACKED_CLAIM" | jq -c '.envelope // empty')"
deliver_envelope "$ACKED_REF" "$ACKED_ENVELOPE" >/dev/null \
  && pass "acked envelope was delivered before ack" \
  || fail "acked envelope delivery failed"
ACKED="$(ack_envelope "$ACKED_REF" "$ACKED_LEASE")" \
  && pass "acked envelope reached terminal state before restart" \
  || fail "acked envelope ack failed"
[ "$(printf '%s' "$ACKED" | jq -r '.status // empty')" = "acked" ] && pass "ack returned terminal status" || fail "ack status mismatch: $ACKED"
ACKED_DECRYPTED="$(decrypt_envelope "$ACKED_REF")" \
  && pass "acked envelope decrypted before restart" \
  || fail "acked envelope decrypt before restart failed"
[ "$(printf '%s' "$ACKED_DECRYPTED" | jq -r '.plaintext // empty')" = "$PLAINTEXT_ACKED_B64" ] && pass "acked plaintext survived encrypted delivery before restart" || fail "acked plaintext mismatch: $ACKED_DECRYPTED"

NO_AUTH_STATUS="$(curl -sS -o /tmp/scenario-126-store-body -w "%{http_code}" "$HTTP_STORE_ENDPOINT/snapshot?store_ref=signal_envelopes")"
[ "$NO_AUTH_STATUS" = "401" ] && pass "HTTP store rejected unauthenticated snapshot access" || fail "HTTP store accepted unauthenticated snapshot access: $(cat /tmp/scenario-126-store-body)"

post_store_control "/control/conflict?store_ref=signal_envelopes" >/dev/null \
  && pass "HTTP store injected external generation conflict" \
  || fail "HTTP store conflict control failed"
CONFLICT_BODY="$(jq -cn --arg plaintext "$PLAINTEXT_QUEUED_B64" --arg message_ref "scenario-126-conflict" --argjson remote_bundle "$RECIPIENT_BUNDLE" \
  '{plaintext:$plaintext,message_ref:$message_ref,remote_bundle:$remote_bundle}')"
CONFLICT_STATUS="$(post_status "/spaces/$SPACE/participants/$SENDER/outbox/$RECIPIENT" "$CONFLICT_BODY")"
[ "$CONFLICT_STATUS" != "202" ] && pass "Workflow API failed closed on HTTP generation conflict" || fail "Workflow API accepted stale HTTP generation write"
stop_server
if start_server; then
  pass "workflow server resynchronized after host-managed generation conflict"
else
  fail "workflow server did not resynchronize after generation conflict; see $SERVER_LOG"
  finish
  exit 1
fi

if [ -s "$HTTP_STORE_STATE" ]; then
  pass "HTTP store state file exists"
else
  fail "HTTP store state file was not created"
fi

if jq -e '.generation_ref | startswith("generation-")' "$HTTP_STORE_STATE" >/dev/null 2>&1; then
  pass "HTTP store recorded CAS generation metadata"
else
  fail "HTTP store generation metadata missing"
fi
GET_COUNT="$(jq -r '.get_count // 0' "$HTTP_STORE_STATE" 2>/dev/null)"
PUT_COUNT="$(jq -r '.put_count // 0' "$HTTP_STORE_STATE" 2>/dev/null)"
AUTH_COUNT="$(jq -r '.auth_count // 0' "$HTTP_STORE_STATE" 2>/dev/null)"
if [ "$GET_COUNT" -ge 1 ] && [ "$PUT_COUNT" -ge 1 ] && [ "$AUTH_COUNT" -ge 2 ]; then
  pass "HTTP store recorded authenticated GET and PUT snapshot traffic"
else
  fail "HTTP store traffic counts unexpected: get=$GET_COUNT put=$PUT_COUNT auth=$AUTH_COUNT"
fi
STATE_JSON="$(jq -c '.snapshots.signal_envelopes.state // empty' "$HTTP_STORE_STATE" 2>/dev/null)"
for plaintext in "$PLAINTEXT_QUEUED_B64" "$PLAINTEXT_RELEASED_B64" "$PLAINTEXT_ACKED_B64"; do
  if printf '%s' "$STATE_JSON" | grep -q "$plaintext"; then
    fail "HTTP store snapshot leaked plaintext marker $plaintext"
  else
    pass "HTTP store snapshot did not expose plaintext marker $plaintext"
  fi
done
if printf '%s' "$STATE_JSON" | grep -q 'ciphertext'; then
  pass "HTTP store snapshot contains ciphertext envelope state"
else
  fail "HTTP store snapshot did not contain ciphertext envelope state"
fi

HTTP_STORE_STATE_BACKUP="$HTTP_STORE_STATE.good"
cp "$HTTP_STORE_STATE" "$HTTP_STORE_STATE_BACKUP"
post_store_control "/control/corrupt?store_ref=signal_envelopes" >/dev/null \
  && pass "HTTP store injected malformed checksum snapshot" \
  || fail "HTTP store corrupt control failed"
stop_server
if start_server; then
  fail "workflow server accepted malformed HTTP snapshot on startup"
  stop_server
else
  pass "workflow server rejected malformed HTTP snapshot on startup"
fi
stop_mock
cp "$HTTP_STORE_STATE_BACKUP" "$HTTP_STORE_STATE"
if start_mock; then
  pass "mock HTTP store restarted with restored snapshot"
else
  fail "mock HTTP store did not restart after restore; see $MOCK_LOG"
  finish
  exit 1
fi
if start_server; then
  pass "workflow server restarted against the same HTTP envelope store"
else
  fail "workflow server did not restart; see $SERVER_LOG"
  finish
  exit 1
fi

QUEUED_CLAIM="$(claim_envelope "$QUEUED_REF" scenario-126-queued-after-restart)" \
  && pass "queued envelope survived restart and could be claimed" \
  || fail "queued envelope claim after restart failed"
QUEUED_LEASE="$(printf '%s' "$QUEUED_CLAIM" | jq -r '.lease_ref // empty')"
QUEUED_ENVELOPE="$(printf '%s' "$QUEUED_CLAIM" | jq -c '.envelope // empty')"
deliver_envelope "$QUEUED_REF" "$QUEUED_ENVELOPE" >/dev/null \
  && pass "queued envelope delivered after restart" \
  || fail "queued envelope deliver after restart failed"
ack_envelope "$QUEUED_REF" "$QUEUED_LEASE" >/dev/null \
  && pass "queued envelope acked after restart" \
  || fail "queued envelope ack after restart failed"

RELEASED_RECLAIM="$(claim_envelope "$RELEASED_REF" scenario-126-released-after-restart)" \
  && pass "released envelope survived restart and could be reclaimed" \
  || fail "released envelope reclaim after restart failed"
[ "$(printf '%s' "$RELEASED_RECLAIM" | jq -r '.metadata.attempt_count // empty')" = "1" ] && pass "released retry attempt count survived restart" || fail "released attempt count mismatch: $RELEASED_RECLAIM"
[ "$(printf '%s' "$RELEASED_RECLAIM" | jq -r '.metadata.last_error_ref // empty')" = "error://scenario-126/transient" ] && pass "released error ref survived restart" || fail "released error ref mismatch: $RELEASED_RECLAIM"
RELEASED_RECLAIM_LEASE="$(printf '%s' "$RELEASED_RECLAIM" | jq -r '.lease_ref // empty')"
RELEASED_RECLAIM_ENVELOPE="$(printf '%s' "$RELEASED_RECLAIM" | jq -c '.envelope // empty')"
deliver_envelope "$RELEASED_REF" "$RELEASED_RECLAIM_ENVELOPE" >/dev/null \
  && pass "released envelope delivered after restart" \
  || fail "released envelope deliver after restart failed"
ack_envelope "$RELEASED_REF" "$RELEASED_RECLAIM_LEASE" >/dev/null \
  && pass "released envelope acked after restart" \
  || fail "released envelope ack after restart failed"

ACKED_RECLAIM_BODY="$(jq -cn --arg envelope_ref "$ACKED_REF" '{envelope_ref:$envelope_ref,lease_id:"scenario-126-acked-after-restart"}')"
ACKED_RECLAIM_STATUS="$(post_status "/workers/$WORKER/outbox/claim" "$ACKED_RECLAIM_BODY")"
[ "$ACKED_RECLAIM_STATUS" != "200" ] && pass "acked envelope stayed terminal across restart" || fail "acked envelope was reclaimable after restart: $(cat /tmp/scenario-126-http-body)"

finish
