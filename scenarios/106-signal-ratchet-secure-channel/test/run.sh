#!/usr/bin/env bash
# Scenario 106 - Signal Ratchet Secure Channel.
#
# Demonstration-fidelity: this executes the real ratchet CLI to create a flow
# run bundle, starts the real Workflow server, loads workflow-plugin-signal as
# an external plugin, and moves the Ratchet bundle descriptor through
# participant-parametric Signal outbox/inbox HTTP routes.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.12.0}"
RATCHET_CLI_REF="${RATCHET_CLI_REF:-v0.25.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
CLIENT_A="${CLIENT_A:-user-a}"
CLIENT_B="${CLIENT_B:-user-b}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18106}"
RUN_ID="${RUN_ID:-ratchet-secure-channel-106}"
MARKER="${MARKER:-ratchet-secure-channel-marker-106}"
NOTE="${NOTE:-private ratchet run bundle handoff}"

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

base64_encode() {
  base64 | tr -d '\n'
}

base64_decode() {
  if printf '' | base64 --decode >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

plugin_repo_supports_service_readiness() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.capabilities.moduleTypes | index("signal.key_custody")) and
    (.capabilities.moduleTypes | index("signal.account_ref")) and
    (.capabilities.moduleTypes | index("signal.envelope_store")) and
    (.capabilities.stepTypes | index("step.signal_service_send_prepare")) and
    (.capabilities.stepTypes | index("step.signal_outbox_enqueue")) and
    (.capabilities.stepTypes | index("step.signal_outbox_claim")) and
    (.capabilities.stepTypes | index("step.signal_inbox_receive")) and
    (.capabilities.stepTypes | index("step.signal_inbox_decrypt"))
  ' "$repo/plugin.json" >/dev/null 2>&1
}

ratchet_repo_supports_flow_bundles() {
  local repo="$1"
  [ -f "$repo/go.mod" ] || return 1
  grep -q 'FlowReplayBundleSchema' "$repo/internal/acpclient/flow_replay.go" 2>/dev/null || return 1
  grep -q 'case "replay"' "$repo/cmd/ratchet/cmd_acp_client.go" 2>/dev/null
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
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_service_readiness "$plugin_repo"; then
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

build_ratchet() {
  local bin="$1"
  local ratchet_repo
  if [ -n "${RATCHET_CLI_REPO:-}" ]; then
    ratchet_repo="$(find_repo "$RATCHET_CLI_REPO")" || return 1
    ratchet_repo_supports_flow_bundles "$ratchet_repo" || return 1
  else
    ratchet_repo="$(find_repo "" "$REPO_ROOT/../ratchet-cli" "$REPO_ROOT/../../../ratchet-cli")" || ratchet_repo=""
    if [ -n "$ratchet_repo" ] && ! ratchet_repo_supports_flow_bundles "$ratchet_repo"; then
      ratchet_repo=""
    fi
  fi
  if [ -z "$ratchet_repo" ]; then
    ratchet_repo="$DATA_DIR/repos/ratchet-cli"
    mkdir -p "$(dirname "$ratchet_repo")" || return 1
    git clone --quiet --depth 1 https://github.com/GoCodeAlone/ratchet-cli.git "$ratchet_repo" || return 1
    git -C "$ratchet_repo" fetch --quiet --depth 1 origin "refs/tags/$RATCHET_CLI_REF:refs/tags/$RATCHET_CLI_REF" || return 1
    git -C "$ratchet_repo" -c advice.detachedHead=false checkout --quiet "$RATCHET_CLI_REF^{commit}" || return 1
  fi
  (cd "$ratchet_repo" && GOWORK=off go build -o "$bin" ./cmd/ratchet) >/dev/null 2>&1 || return 1
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

echo ""
echo "=== Scenario 106 - Signal Ratchet Secure Channel ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if grep -Eiq 'alice|bob' "$CONFIG"; then
  fail "Workflow pipelines should not hard-code Alice/Bob participant names"
else
  pass "Workflow API is participant-parametric"
fi
for step_type in \
  step.signal_outbox_enqueue \
  step.signal_outbox_claim \
  step.signal_inbox_receive \
  step.signal_inbox_decrypt
do
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

RATCHET_BIN="$DATA_DIR/bin/ratchet"
mkdir -p "$(dirname "$RATCHET_BIN")"
if build_ratchet "$RATCHET_BIN"; then
  pass "built real ratchet CLI"
else
  fail "could not build ratchet CLI; set RATCHET_CLI_REPO"
  finish
  exit 1
fi

RATCHET_VERSION="$("$RATCHET_BIN" version 2>/dev/null || true)"
if printf '%s' "$RATCHET_VERSION" | grep -qi 'ratchet'; then
  pass "ratchet CLI executed version command"
else
  fail "ratchet CLI version command did not execute: $RATCHET_VERSION"
fi

FLOW_PAYLOAD="$(jq -cn \
  --arg schema "ratchet.secure-channel.message.v1" \
  --arg marker "$MARKER" \
  --arg sender "$CLIENT_A" \
  --arg recipient "$CLIENT_B" \
  --arg note "$NOTE" \
  '{schema:$schema,marker:$marker,sender:$sender,recipient:$recipient,note:$note}')" || FLOW_PAYLOAD=""
FLOW_FILE="$DATA_DIR/ratchet-flow.json"
jq -n --arg payload "$FLOW_PAYLOAD" '{
  format_version: 1,
  name: "signal-ratchet-secure-channel",
  requires: ["shell"],
  start_at: "bundle",
  nodes: [
    {id: "bundle", type: "action", command: "printf", args: ["%s", $payload]}
  ]
}' >"$FLOW_FILE" || {
  fail "could not write ratchet flow definition"
  finish
  exit 1
}

RATCHET_HOME="$DATA_DIR/ratchet-home"
RATCHET_STATE="$DATA_DIR/ratchet-state"
RATCHET_CWD="$DATA_DIR/ratchet-cwd"
mkdir -p "$RATCHET_HOME" "$RATCHET_STATE" "$RATCHET_CWD"
FLOW_RESULT="$(HOME="$RATCHET_HOME" XDG_STATE_HOME="$RATCHET_STATE" "$RATCHET_BIN" acp client flow run "$FLOW_FILE" \
  --run-id "$RUN_ID" \
  --input-json "$(jq -cn --arg sender "$CLIENT_A" --arg recipient "$CLIENT_B" '{sender:$sender,recipient:$recipient}')" \
  --cwd "$RATCHET_CWD" \
  --allow shell \
  --json)" \
  && pass "ratchet CLI created a flow-run bundle" \
  || fail "ratchet CLI flow run failed"

RUN_DIR="$(printf '%s' "$FLOW_RESULT" | jq -r '.run_dir // empty' 2>/dev/null)"
if [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ]; then
  pass "ratchet flow result returned a run directory"
else
  fail "ratchet flow result missing run directory: $FLOW_RESULT"
fi

if [ "$(jq -r '.schema // empty' "$RUN_DIR/manifest.json" 2>/dev/null)" = "acpx.flow-run-bundle.v1" ]; then
  pass "ratchet run directory contains an acpx.flow-run-bundle.v1 manifest"
else
  fail "ratchet run directory missing flow-run manifest"
fi

STEP_STDOUT="$(jq -r '.stdout // empty' "$RUN_DIR/steps/bundle.json" 2>/dev/null)"
if [ "$STEP_STDOUT" = "$FLOW_PAYLOAD" ]; then
  pass "ratchet bundle step output contains caller-supplied secure-channel payload"
else
  fail "ratchet bundle step output mismatch"
fi

REPLAY="$(HOME="$RATCHET_HOME" XDG_STATE_HOME="$RATCHET_STATE" "$RATCHET_BIN" acp client flow replay "$RUN_DIR" --json)" \
  && pass "ratchet CLI replayed the saved flow bundle" \
  || fail "ratchet CLI flow replay failed"
if [ "$(printf '%s' "$REPLAY" | jq -r '.status // empty' 2>/dev/null)" = "completed" ]; then
  pass "ratchet replay summary reports completed status"
else
  fail "ratchet replay summary unexpected: $REPLAY"
fi

PLUGIN_DIR="$DATA_DIR/plugins"
if build_plugin "$PLUGIN_DIR"; then
  pass "built workflow-plugin-signal external plugin"
else
  fail "could not build workflow-plugin-signal; set SIGNAL_PLUGIN_REPO"
  finish
  exit 1
fi

SERVER_LOG="$SCRIPT_DIR/artifacts/last-server.log"
mkdir -p "$(dirname "$SERVER_LOG")"
"$SERVER_BIN" -config "$CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

if wait_for_server "$BASE_URL"; then
  pass "workflow server started and served /healthz"
else
  fail "workflow server did not become ready; see $SERVER_LOG"
  finish
  exit 1
fi

SESSION_B="$(curl -fsS -X POST "$BASE_URL/participants/$CLIENT_B/session" -H 'Content-Type: application/json' -d '{}')" \
  && pass "recipient published a pre-key bundle via Workflow API" \
  || fail "recipient session prepare API failed"
BUNDLE="$(printf '%s' "$SESSION_B" | jq -c '.bundle // empty' 2>/dev/null)"
[ -n "$BUNDLE" ] && [ "$BUNDLE" != "null" ] && pass "recipient response contained a bundle" || fail "recipient response did not contain a bundle: $SESSION_B"

SESSION_A="$(curl -fsS -X POST "$BASE_URL/participants/$CLIENT_A/session" -H 'Content-Type: application/json' -d '{}')" \
  && pass "sender published a pre-key bundle via Workflow API" \
  || fail "sender session prepare API failed"
BUNDLE_A="$(printf '%s' "$SESSION_A" | jq -c '.bundle // empty' 2>/dev/null)"
[ -n "$BUNDLE_A" ] && [ "$BUNDLE_A" != "null" ] && pass "sender response contained a bundle" || fail "sender response did not contain a bundle: $SESSION_A"

MANIFEST_SHA="$(sha256_file "$RUN_DIR/manifest.json")"
DESCRIPTOR="$(jq -cn \
  --arg schema "ratchet.signal.secure-channel.v1" \
  --arg marker "$MARKER" \
  --arg sender "$CLIENT_A" \
  --arg recipient "$CLIENT_B" \
  --arg run_id "$RUN_ID" \
  --arg manifest_sha256 "$MANIFEST_SHA" \
  --slurpfile manifest "$RUN_DIR/manifest.json" \
  '{schema:$schema,marker:$marker,sender:$sender,recipient:$recipient,run_id:$run_id,manifest_sha256:$manifest_sha256,flow_manifest:$manifest[0]}')" || DESCRIPTOR=""
PLAINTEXT_B64="$(printf '%s' "$DESCRIPTOR" | base64_encode)"

QUEUE_BODY="$(jq -cn --arg plaintext "$PLAINTEXT_B64" --arg message_ref "scenario-106-ratchet-bundle" --argjson remote_bundle "$BUNDLE" \
  '{plaintext:$plaintext, message_ref:$message_ref, remote_bundle:$remote_bundle}')" || QUEUE_BODY=""
QUEUED="$(curl -fsS -X POST "$BASE_URL/participants/$CLIENT_A/outbox/$CLIENT_B" -H 'Content-Type: application/json' -d "$QUEUE_BODY")" \
  && pass "sender enqueued encrypted Ratchet bundle descriptor through Workflow API" \
  || fail "sender outbox enqueue API failed"

QUEUED_REF="$(printf '%s' "$QUEUED" | jq -r '.envelope_ref // empty' 2>/dev/null)"
[ -n "$QUEUED_REF" ] && pass "outbox enqueue returned an envelope ref" || fail "outbox enqueue did not return an envelope ref: $QUEUED"

if printf '%s' "$QUEUED" | grep -q "$PLAINTEXT_B64" || printf '%s' "$QUEUED" | grep -q "$MARKER"; then
  fail "outbox queue response leaked Ratchet descriptor plaintext"
else
  pass "outbox queue response did not expose Ratchet descriptor plaintext"
fi

RECEIVE_BODY="$(jq -cn --arg envelope_ref "$QUEUED_REF" --arg lease_id "scenario-106-lease-1" \
  '{envelope_ref:$envelope_ref, lease_id:$lease_id}')" || RECEIVE_BODY=""
RECEIVED="$(curl -fsS -X POST "$BASE_URL/participants/$CLIENT_B/messages/receive" -H 'Content-Type: application/json' -d "$RECEIVE_BODY")" \
  && pass "recipient claimed, received, and decrypted queued Ratchet descriptor through Workflow API" \
  || fail "recipient queued receive API failed"

if [ "$(printf '%s' "$RECEIVED" | jq -r '.claim_status // empty' 2>/dev/null)" = "claimed" ] &&
   [ "$(printf '%s' "$RECEIVED" | jq -r '.receive_status // empty' 2>/dev/null)" = "received" ]; then
  pass "queued Ratchet descriptor moved through claimed and received states"
else
  fail "queued Ratchet descriptor did not move through expected states: $RECEIVED"
fi

DECRYPTED_B64="$(printf '%s' "$RECEIVED" | jq -r '.plaintext // empty' 2>/dev/null)"
if [ "$DECRYPTED_B64" = "$PLAINTEXT_B64" ]; then
  pass "recipient recovered the original Ratchet descriptor plaintext"
else
  fail "recipient plaintext mismatch"
fi

DECRYPTED_DESCRIPTOR="$(printf '%s' "$DECRYPTED_B64" | base64_decode 2>/dev/null || true)"
if [ "$(printf '%s' "$DECRYPTED_DESCRIPTOR" | jq -r '.marker // empty' 2>/dev/null)" = "$MARKER" ] &&
   [ "$(printf '%s' "$DECRYPTED_DESCRIPTOR" | jq -r '.run_id // empty' 2>/dev/null)" = "$RUN_ID" ] &&
   [ "$(printf '%s' "$DECRYPTED_DESCRIPTOR" | jq -r '.flow_manifest.schema // empty' 2>/dev/null)" = "acpx.flow-run-bundle.v1" ]; then
  pass "decrypted descriptor references the real Ratchet flow-run bundle"
else
  fail "decrypted descriptor missing Ratchet bundle evidence: $DECRYPTED_DESCRIPTOR"
fi

finish
