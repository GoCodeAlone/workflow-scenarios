#!/usr/bin/env bash
# Scenario 107 - Signal Encrypted Blob Handoff.
#
# Demonstration-fidelity: this starts the real Workflow server, loads
# workflow-plugin-signal as an external plugin, moves caller-supplied blob bytes
# through participant-parametric HTTP routes, and stores only encrypted blob JSON
# in a local object-store mock before recipient decrypt.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.13.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
CLIENT_A="${CLIENT_A:-user-a}"
CLIENT_B="${CLIENT_B:-user-b}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18107}"
BLOB_REF="${BLOB_REF:-blob://scenario-107/private-report.json}"
MARKER="${MARKER:-signal-blob-secret-marker-107}"

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

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

plugin_repo_supports_blob() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.capabilities.moduleTypes | index("signal.identity_store")) and
    (.capabilities.stepTypes | index("step.signal_session_prepare")) and
    (.capabilities.stepTypes | index("step.signal_blob_encrypt")) and
    (.capabilities.stepTypes | index("step.signal_blob_decrypt"))
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
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_blob "$plugin_repo"; then
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

echo ""
echo "=== Scenario 107 - Signal Encrypted Blob Handoff ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if grep -Eiq 'alice|bob' "$CONFIG"; then
  fail "Workflow pipelines should not hard-code Alice/Bob participant names"
else
  pass "Workflow API is participant-parametric"
fi
for step_type in step.signal_blob_encrypt step.signal_blob_decrypt; do
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
  pass "built workflow-plugin-signal external plugin with blob primitives"
else
  fail "could not build workflow-plugin-signal $SIGNAL_PLUGIN_REF; set SIGNAL_PLUGIN_REPO"
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

PLAINTEXT="$(jq -cn \
  --arg schema "scenario-107.private-report.v1" \
  --arg marker "$MARKER" \
  --arg sender "$CLIENT_A" \
  --arg recipient "$CLIENT_B" \
  '{schema:$schema,marker:$marker,sender:$sender,recipient:$recipient,rows:[{label:"private",amount:107}]}' )"
PLAINTEXT_B64="$(printf '%s' "$PLAINTEXT" | base64_encode)"
PLAINTEXT_SHA="$(sha256_text "$PLAINTEXT")"
UPLOAD_BODY="$(jq -cn \
  --arg blob_ref "$BLOB_REF" \
  --arg filename "private-report.json" \
  --arg content_type "application/json" \
  --arg plaintext "$PLAINTEXT_B64" \
  --arg aad_context "scenario://107/signal/blob" \
  --argjson remote_bundle "$BUNDLE" \
  '{remote_id:"user-b@example.test",remote_device_id:1,remote_bundle:$remote_bundle,blob_ref:$blob_ref,filename:$filename,content_type:$content_type,plaintext:$plaintext,aad_context:$aad_context}')" || UPLOAD_BODY=""

ENCRYPTED="$(curl -fsS -X POST "$BASE_URL/participants/$CLIENT_A/blobs/$CLIENT_B" -H 'Content-Type: application/json' -d "$UPLOAD_BODY")" \
  && pass "sender encrypted blob bytes through Workflow API" \
  || fail "sender blob encrypt API failed"

OBJECT_STORE="$DATA_DIR/mock-object-store"
mkdir -p "$OBJECT_STORE"
OBJECT_FILE="$OBJECT_STORE/scenario-107-object.json"
printf '%s' "$ENCRYPTED" >"$OBJECT_FILE"
[ -s "$OBJECT_FILE" ] && pass "mock object store persisted encrypted blob JSON" || fail "mock object store did not persist encrypted blob JSON"

if grep -q "$MARKER" "$OBJECT_FILE" || grep -q "$PLAINTEXT_B64" "$OBJECT_FILE" || grep -q "$PLAINTEXT_SHA" "$OBJECT_FILE"; then
  fail "mock object store leaked plaintext, plaintext bytes, or plaintext digest"
else
  pass "mock object store did not expose plaintext or plaintext digest"
fi
if jq -e '[.. | objects | select(has("key") or has("content_key") or has("contentKey"))] | length == 0' "$OBJECT_FILE" >/dev/null 2>&1; then
  pass "mock object store did not expose clear content key material"
else
  fail "mock object store exposed clear content key material"
fi
if jq -e '.blob.ciphertext and .blob.nonce and .manifest_envelope.ciphertext and .manifest_ref' "$OBJECT_FILE" >/dev/null 2>&1; then
  pass "mock object store contains encrypted blob and Signal manifest envelope"
else
  fail "mock object store missing encrypted blob or manifest envelope: $ENCRYPTED"
fi

DECRYPT_BODY="$(jq -cn \
  --arg principal "$CLIENT_B" \
  --arg custody_ref "custody://$CLIENT_B/device-1" \
  --arg authz_ref "authz://signal/blob/$CLIENT_B/read/scenario-107" \
  --slurpfile object "$OBJECT_FILE" \
  '{principal:$principal,custody_ref:$custody_ref,authz_ref:$authz_ref,manifest_envelope:$object[0].manifest_envelope,blob:$object[0].blob}')" || DECRYPT_BODY=""
DECRYPTED="$(curl -fsS -X POST "$BASE_URL/participants/$CLIENT_B/blobs/decrypt" -H 'Content-Type: application/json' -d "$DECRYPT_BODY")" \
  && pass "recipient decrypted stored blob through Workflow API" \
  || fail "recipient blob decrypt API failed"

if [ "$(printf '%s' "$DECRYPTED" | jq -r '.verified // empty' 2>/dev/null)" = "true" ]; then
  pass "recipient decrypt verified ciphertext and plaintext digests"
else
  fail "recipient decrypt did not report verified output: $DECRYPTED"
fi

DECRYPTED_B64="$(printf '%s' "$DECRYPTED" | jq -r '.plaintext // empty' 2>/dev/null)"
DECRYPTED_TEXT="$(printf '%s' "$DECRYPTED_B64" | base64_decode 2>/dev/null || true)"
if [ "$DECRYPTED_TEXT" = "$PLAINTEXT" ]; then
  pass "recipient recovered original blob plaintext"
else
  fail "recipient plaintext mismatch"
fi

if [ "$(printf '%s' "$DECRYPTED" | jq -r '.plaintext_sha256 // empty' 2>/dev/null)" = "$PLAINTEXT_SHA" ] &&
   [ "$(printf '%s' "$DECRYPTED" | jq -r '.blob_ref // empty' 2>/dev/null)" = "$BLOB_REF" ]; then
  pass "recipient output carried verified digest and blob ref"
else
  fail "recipient output missing digest/blob ref evidence: $DECRYPTED"
fi

finish
