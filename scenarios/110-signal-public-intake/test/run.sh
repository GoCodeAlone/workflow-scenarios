#!/usr/bin/env bash
# Scenario 110 - Signal Public Intake.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-signal subprocess from data/plugins, publishes a public intake
# bundle through an operator HTTP route, and drives public caller HTTP routes
# for encrypted message/blob submission before operator decrypt.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.15.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
INTAKE_REF="${INTAKE_REF:-support-intake}"
CALLER_A="${CALLER_A:-caller-a}"
CALLER_B="${CALLER_B:-caller-b}"
AUDIENCE_REF="${AUDIENCE_REF:-audience://public-contact}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18110}"
MESSAGE_MARKER="${MESSAGE_MARKER:-signal-public-intake-message-secret-110}"
BLOB_MARKER="${BLOB_MARKER:-signal-public-intake-blob-secret-110}"
BLOB_REF="${BLOB_REF:-blob://scenario-110/private-intake.json}"

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

plugin_repo_supports_public_intake() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.capabilities.moduleTypes | index("signal.public_prekey_directory")) and
    (.capabilities.stepTypes | index("step.signal_public_prekey_publish")) and
    (.capabilities.stepTypes | index("step.signal_public_prekey_resolve")) and
    (.capabilities.stepTypes | index("step.signal_encrypt")) and
    (.capabilities.stepTypes | index("step.signal_decrypt")) and
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
  if [ -n "${SIGNAL_PLUGIN_REPO:-}" ] && [ ! -d "$SIGNAL_PLUGIN_REPO" ]; then
    echo "SIGNAL_PLUGIN_REPO is set but is not a directory: $SIGNAL_PLUGIN_REPO" >&2
    return 1
  fi
  plugin_repo="$(find_repo "${SIGNAL_PLUGIN_REPO:-}" "$REPO_ROOT/../workflow-plugin-signal" "$REPO_ROOT/../../../workflow-plugin-signal")" || plugin_repo=""
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_public_intake "$plugin_repo"; then
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
echo "=== Scenario 110 - Signal Public Intake ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if grep -Eiq 'alice|bob' "$CONFIG"; then
  fail "Workflow pipelines should not hard-code Alice/Bob participant names"
else
  pass "Workflow API is actor-parametric"
fi
for step_type in \
  step.signal_public_prekey_publish \
  step.signal_public_prekey_resolve \
  step.signal_encrypt \
  step.signal_decrypt \
  step.signal_blob_encrypt \
  step.signal_blob_decrypt
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

PLUGIN_DIR="$DATA_DIR/plugins"
if build_plugin "$PLUGIN_DIR"; then
  pass "built workflow-plugin-signal external plugin with public-intake primitives"
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

PUBLISH_BODY="$(jq -cn \
  --arg audience_ref "$AUDIENCE_REF" \
  '{audience_ref:$audience_ref,allowed_purpose:"public-contact",requested_at_unix:"1783000000",expires_at_unix:"1783003600"}')" || PUBLISH_BODY=""
PUBLISHED="$(curl -fsS -X POST "$BASE_URL/operator/$INTAKE_REF/publish" -H 'Content-Type: application/json' -d "$PUBLISH_BODY")" \
  && pass "operator published intake pre-key bundle through Workflow API" \
  || fail "operator publish API failed"

if [ "$(printf '%s' "$PUBLISHED" | jq -r '.status // empty' 2>/dev/null)" = "published" ]; then
  pass "publish response returned published status"
else
  fail "publish response unexpected: $PUBLISHED"
fi
if printf '%s' "$PUBLISHED" | jq -e '.bundle and .bundle_sha256 and .identity_key_fingerprint and .public_metadata' >/dev/null 2>&1; then
  pass "publish response exposed public bundle hash, fingerprint, and metadata"
else
  fail "publish response missing public bundle evidence: $PUBLISHED"
fi
for forbidden in 'custody://' 'credential://' 'operator://host-intake' 'private-key' 'plaintext'; do
  if printf '%s' "$PUBLISHED" | grep -q "$forbidden"; then
    fail "publish response leaked forbidden marker $forbidden"
  else
    pass "publish response did not leak $forbidden"
  fi
done

RESOLVED="$(curl -fsS "$BASE_URL/intake/$INTAKE_REF/bundle?audience_ref=$AUDIENCE_REF&requested_at_unix=1783000060")" \
  && pass "public caller resolved intake bundle through unauthenticated Workflow API" \
  || fail "public bundle resolve API failed"

if [ "$(printf '%s' "$RESOLVED" | jq -r '.status // empty' 2>/dev/null)" = "resolved" ]; then
  pass "public resolve returned resolved status"
else
  fail "public resolve unexpected: $RESOLVED"
fi
HOST_BUNDLE="$(printf '%s' "$RESOLVED" | jq -c '.bundle // empty' 2>/dev/null)"
if [ -n "$HOST_BUNDLE" ] && [ "$HOST_BUNDLE" != "null" ]; then
  pass "public resolve returned a bundle"
else
  fail "public resolve did not return bundle: $RESOLVED"
fi
PUBLISHED_HASH="$(printf '%s' "$PUBLISHED" | jq -r '.bundle_sha256 // empty' 2>/dev/null)"
RESOLVED_HASH="$(printf '%s' "$RESOLVED" | jq -r '.bundle_sha256 // empty' 2>/dev/null)"
if [ -n "$PUBLISHED_HASH" ] && [ "$PUBLISHED_HASH" = "$RESOLVED_HASH" ]; then
  pass "public resolve bundle hash matches operator-published hash"
else
  fail "public resolve bundle hash mismatch"
fi

MISMATCH="$(curl -fsS "$BASE_URL/intake/$INTAKE_REF/bundle?audience_ref=audience://wrong&requested_at_unix=1783000060")" \
  && pass "audience-mismatch resolve returned a Workflow response" \
  || fail "audience-mismatch resolve API failed"
if [ "$(printf '%s' "$MISMATCH" | jq -r '.status // empty' 2>/dev/null)" = "audience_mismatch" ] &&
   printf '%s' "$MISMATCH" | jq -e '.bundle == null' >/dev/null 2>&1; then
  pass "audience mismatch returned no bundle"
else
  fail "audience mismatch did not deny bundle: $MISMATCH"
fi

EXPIRED_BODY="$(jq -cn \
  --arg audience_ref "$AUDIENCE_REF" \
  '{audience_ref:$audience_ref,allowed_purpose:"public-contact",requested_at_unix:"1783000000",expires_at_unix:"1783000001"}')" || EXPIRED_BODY=""
curl -fsS -X POST "$BASE_URL/operator/$INTAKE_REF-expired/publish" -H 'Content-Type: application/json' -d "$EXPIRED_BODY" >/dev/null \
  && pass "operator published short-lived intake bundle" \
  || fail "operator short-lived publish failed"
EXPIRED="$(curl -fsS "$BASE_URL/intake/$INTAKE_REF-expired/bundle?audience_ref=$AUDIENCE_REF&requested_at_unix=1783000060")" \
  && pass "expired resolve returned a Workflow response" \
  || fail "expired resolve API failed"
if [ "$(printf '%s' "$EXPIRED" | jq -r '.status // empty' 2>/dev/null)" = "expired" ] &&
   printf '%s' "$EXPIRED" | jq -e '.bundle == null' >/dev/null 2>&1; then
  pass "expired intake returned no bundle"
else
  fail "expired intake did not deny bundle: $EXPIRED"
fi

MESSAGE_TEXT="$(jq -cn --arg marker "$MESSAGE_MARKER" --arg caller "$CALLER_A" '{kind:"message",marker:$marker,caller:$caller}')"
MESSAGE_B64="$(printf '%s' "$MESSAGE_TEXT" | base64_encode)"
MESSAGE_BODY="$(jq -cn --arg plaintext "$MESSAGE_B64" --argjson remote_bundle "$HOST_BUNDLE" \
  '{plaintext:$plaintext,remote_bundle:$remote_bundle}')" || MESSAGE_BODY=""
MESSAGE_SUBMIT="$(curl -fsS -X POST "$BASE_URL/intake/$INTAKE_REF/messages/$CALLER_A" -H 'Content-Type: application/json' -d "$MESSAGE_BODY")" \
  && pass "public caller submitted encrypted message through Workflow API" \
  || fail "public message submit API failed"
MESSAGE_FILE="$DATA_DIR/message-queue.json"
printf '%s' "$MESSAGE_SUBMIT" >"$MESSAGE_FILE"
[ -s "$MESSAGE_FILE" ] && pass "local queue mock persisted message submission JSON" || fail "message queue mock did not persist output"
if grep -q "$MESSAGE_MARKER" "$MESSAGE_FILE" || grep -q "$MESSAGE_B64" "$MESSAGE_FILE"; then
  fail "message queue mock leaked plaintext"
else
  pass "message queue mock stored no plaintext"
fi
ENVELOPE="$(printf '%s' "$MESSAGE_SUBMIT" | jq -c '.envelope // empty' 2>/dev/null)"
if [ -n "$ENVELOPE" ] && [ "$ENVELOPE" != "null" ]; then
  pass "message submit returned encrypted envelope"
else
  fail "message submit did not return envelope: $MESSAGE_SUBMIT"
fi

WRONG_DECRYPT_BODY="$(jq -cn --arg principal "operator://wrong" --argjson envelope "$ENVELOPE" \
  '{principal:$principal,envelope:$envelope}')" || WRONG_DECRYPT_BODY=""
WRONG_DECRYPT="$(curl -fsS -X POST "$BASE_URL/operator/$INTAKE_REF/messages/decrypt" -H 'Content-Type: application/json' -d "$WRONG_DECRYPT_BODY")" \
  && pass "wrong-principal message decrypt returned Workflow response" \
  || fail "wrong-principal message decrypt API failed"
if [ "$(printf '%s' "$WRONG_DECRYPT" | jq -r '.denied // empty' 2>/dev/null)" = "true" ] &&
   [ -z "$(printf '%s' "$WRONG_DECRYPT" | jq -r '.plaintext // empty' 2>/dev/null)" ]; then
  pass "wrong-principal message decrypt denied without plaintext"
else
  fail "wrong-principal message decrypt leaked or allowed plaintext: $WRONG_DECRYPT"
fi

DECRYPT_BODY="$(jq -cn --arg principal "operator://host-intake" --argjson envelope "$ENVELOPE" \
  '{principal:$principal,envelope:$envelope}')" || DECRYPT_BODY=""
DECRYPTED="$(curl -fsS -X POST "$BASE_URL/operator/$INTAKE_REF/messages/decrypt" -H 'Content-Type: application/json' -d "$DECRYPT_BODY")" \
  && pass "operator decrypted public message through Workflow API" \
  || fail "operator message decrypt API failed"
if [ "$(printf '%s' "$DECRYPTED" | jq -r '.plaintext // empty' 2>/dev/null)" = "$MESSAGE_B64" ]; then
  pass "operator recovered original message plaintext"
else
  fail "operator message plaintext mismatch: $DECRYPTED"
fi

BLOB_TEXT="$(jq -cn --arg marker "$BLOB_MARKER" --arg caller "$CALLER_B" '{kind:"blob",marker:$marker,caller:$caller,rows:[{label:"intake",amount:110}]}')"
BLOB_B64="$(printf '%s' "$BLOB_TEXT" | base64_encode)"
BLOB_SHA="$(sha256_text "$BLOB_TEXT")"
BLOB_BODY="$(jq -cn \
  --arg blob_ref "$BLOB_REF" \
  --arg filename "private-intake.json" \
  --arg content_type "application/json" \
  --arg plaintext "$BLOB_B64" \
  --arg aad_context "scenario://110/signal/public-intake" \
  --argjson remote_bundle "$HOST_BUNDLE" \
  '{remote_bundle:$remote_bundle,blob_ref:$blob_ref,filename:$filename,content_type:$content_type,plaintext:$plaintext,aad_context:$aad_context}')" || BLOB_BODY=""
BLOB_SUBMIT="$(curl -fsS -X POST "$BASE_URL/intake/$INTAKE_REF/blobs/$CALLER_B" -H 'Content-Type: application/json' -d "$BLOB_BODY")" \
  && pass "public caller submitted encrypted blob through Workflow API" \
  || fail "public blob submit API failed"

OBJECT_STORE="$DATA_DIR/mock-object-store"
mkdir -p "$OBJECT_STORE"
OBJECT_FILE="$OBJECT_STORE/scenario-110-object.json"
printf '%s' "$BLOB_SUBMIT" >"$OBJECT_FILE"
[ -s "$OBJECT_FILE" ] && pass "mock object store persisted encrypted blob JSON" || fail "mock object store did not persist encrypted blob JSON"
if grep -q "$BLOB_MARKER" "$OBJECT_FILE" || grep -q "$BLOB_B64" "$OBJECT_FILE" || grep -q "$BLOB_SHA" "$OBJECT_FILE"; then
  fail "mock object store leaked blob plaintext or plaintext digest"
else
  pass "mock object store did not expose blob plaintext or digest"
fi
if jq -e '[.. | objects | select(has("key") or has("content_key") or has("contentKey"))] | length == 0' "$OBJECT_FILE" >/dev/null 2>&1; then
  pass "mock object store did not expose clear content key material"
else
  fail "mock object store exposed clear content key material"
fi

WRONG_BLOB_BODY="$(jq -cn \
  --arg principal "operator://wrong" \
  --arg custody_ref "custody://host-intake/device-1" \
  --arg authz_ref "authz://signal/public-intake/blob/read" \
  --slurpfile object "$OBJECT_FILE" \
  '{principal:$principal,custody_ref:$custody_ref,authz_ref:$authz_ref,manifest_envelope:$object[0].manifest_envelope,blob:$object[0].blob}')" || WRONG_BLOB_BODY=""
WRONG_BLOB="$(curl -fsS -X POST "$BASE_URL/operator/$INTAKE_REF/blobs/decrypt" -H 'Content-Type: application/json' -d "$WRONG_BLOB_BODY")" \
  && pass "wrong-principal blob decrypt returned Workflow response" \
  || fail "wrong-principal blob decrypt API failed"
if [ "$(printf '%s' "$WRONG_BLOB" | jq -r '.denied // empty' 2>/dev/null)" = "true" ] &&
   [ -z "$(printf '%s' "$WRONG_BLOB" | jq -r '.plaintext // empty' 2>/dev/null)" ]; then
  pass "wrong-principal blob decrypt denied without plaintext"
else
  fail "wrong-principal blob decrypt leaked or allowed plaintext: $WRONG_BLOB"
fi

BLOB_DECRYPT_BODY="$(jq -cn \
  --arg principal "operator://host-intake" \
  --arg custody_ref "custody://host-intake/device-1" \
  --arg authz_ref "authz://signal/public-intake/blob/read" \
  --slurpfile object "$OBJECT_FILE" \
  '{principal:$principal,custody_ref:$custody_ref,authz_ref:$authz_ref,manifest_envelope:$object[0].manifest_envelope,blob:$object[0].blob}')" || BLOB_DECRYPT_BODY=""
BLOB_DECRYPTED="$(curl -fsS -X POST "$BASE_URL/operator/$INTAKE_REF/blobs/decrypt" -H 'Content-Type: application/json' -d "$BLOB_DECRYPT_BODY")" \
  && pass "operator decrypted public blob through Workflow API" \
  || fail "operator blob decrypt API failed"
if [ "$(printf '%s' "$BLOB_DECRYPTED" | jq -r '.verified // empty' 2>/dev/null)" = "true" ]; then
  pass "operator blob decrypt verified ciphertext and plaintext digest"
else
  fail "operator blob decrypt did not verify output: $BLOB_DECRYPTED"
fi
BLOB_DECRYPTED_B64="$(printf '%s' "$BLOB_DECRYPTED" | jq -r '.plaintext // empty' 2>/dev/null)"
BLOB_DECRYPTED_TEXT="$(printf '%s' "$BLOB_DECRYPTED_B64" | base64_decode 2>/dev/null || true)"
if [ "$BLOB_DECRYPTED_TEXT" = "$BLOB_TEXT" ]; then
  pass "operator recovered original blob plaintext"
else
  fail "operator blob plaintext mismatch"
fi

finish
