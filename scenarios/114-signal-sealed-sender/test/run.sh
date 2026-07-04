#!/usr/bin/env bash
# Scenario 114 - Signal Sealed Sender.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-signal subprocess from data/plugins, and drives multiple
# participant-parametric HTTP clients through sealed-sender app routes.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.19.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
SENDER="${SENDER:-user-a}"
RECIPIENT="${RECIPIENT:-user-b}"
THIRD_PARTY="${THIRD_PARTY:-user-c}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18114}"
MESSAGE_MARKER="${MESSAGE_MARKER:-signal-sealed-sender-secret-114}"

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
  stop_server
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

plugin_repo_supports_sealed_sender() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.capabilities.moduleTypes | index("signal.identity_store")) and
    (.capabilities.stepTypes | index("step.signal_session_prepare")) and
    (.capabilities.stepTypes | index("step.signal_encrypt")) and
    (.capabilities.stepTypes | index("step.signal_decrypt")) and
    (.capabilities.stepTypes | index("step.signal_sender_certificate_issue")) and
    (.capabilities.stepTypes | index("step.signal_sender_seal")) and
    (.capabilities.stepTypes | index("step.signal_sender_unseal"))
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
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_sealed_sender "$plugin_repo"; then
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
  "$SERVER_BIN" -config "$CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  wait_for_server "$BASE_URL"
}

stop_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  SERVER_PID=""
}

http_status() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -o /dev/null -w "%{http_code}" -X "$method" "$url" -H 'Content-Type: application/json' -d "$body" 2>/dev/null || echo "000"
  else
    curl -sS -o /dev/null -w "%{http_code}" -X "$method" "$url" 2>/dev/null || echo "000"
  fi
}

echo ""
echo "=== Scenario 114 - Signal Sealed Sender ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if [ ! -f "$CONFIG" ]; then
  finish
  exit 1
fi

if grep -Eiq 'alice|bob' "$CONFIG"; then
  fail "Workflow pipelines should not hard-code Alice/Bob participant names"
else
  pass "Workflow API is participant-parametric"
fi
for step_type in \
  step.signal_session_prepare \
  step.signal_encrypt \
  step.signal_sender_certificate_issue \
  step.signal_sender_seal \
  step.signal_sender_unseal \
  step.signal_decrypt
do
  if grep -Fq -- "type: $step_type" "$CONFIG"; then
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
  pass "built workflow-plugin-signal external plugin with sealed-sender primitives"
else
  fail "could not build workflow-plugin-signal $SIGNAL_PLUGIN_REF; set SIGNAL_PLUGIN_REPO"
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

RECIPIENT_SESSION="$(curl -fsS -X POST "$BASE_URL/participants/$RECIPIENT/session" -H 'Content-Type: application/json' -d '{}')" \
  && pass "recipient published a pre-key bundle through Workflow API" \
  || fail "recipient session prepare API failed"
RECIPIENT_BUNDLE="$(printf '%s' "$RECIPIENT_SESSION" | jq -c '.bundle // empty' 2>/dev/null)"
RECIPIENT_IDENTITY_KEY="$(printf '%s' "$RECIPIENT_BUNDLE" | jq -r '.identity_key // empty' 2>/dev/null)"
if [ -n "$RECIPIENT_BUNDLE" ] && [ "$RECIPIENT_BUNDLE" != "null" ] && [ -n "$RECIPIENT_IDENTITY_KEY" ]; then
  pass "recipient bundle exposes public identity key for sealed sender"
else
  fail "recipient bundle missing public identity key: $RECIPIENT_SESSION"
fi

SENDER_SESSION="$(curl -fsS -X POST "$BASE_URL/participants/$SENDER/session" -H 'Content-Type: application/json' -d '{}')" \
  && pass "sender published a pre-key bundle through Workflow API" \
  || fail "sender session prepare API failed"
if printf '%s' "$SENDER_SESSION" | jq -e '.bundle.identity_key' >/dev/null 2>&1; then
  pass "sender identity is available through the Workflow app"
else
  fail "sender session response missing identity bundle: $SENDER_SESSION"
fi

MESSAGE_TEXT="$(jq -cn --arg marker "$MESSAGE_MARKER" --arg sender "$SENDER" --arg recipient "$RECIPIENT" \
  '{kind:"sealed-message",marker:$marker,sender:$sender,recipient:$recipient}')"
MESSAGE_B64="$(printf '%s' "$MESSAGE_TEXT" | base64_encode)"
SEAL_BODY="$(jq -cn --arg plaintext "$MESSAGE_B64" --argjson remote_bundle "$RECIPIENT_BUNDLE" \
  '{plaintext:$plaintext,remote_bundle:$remote_bundle,content_hint:"resendable"}')" || SEAL_BODY=""
SEALED_RESPONSE="$(curl -fsS -X POST "$BASE_URL/participants/$SENDER/sealed/$RECIPIENT" -H 'Content-Type: application/json' -d "$SEAL_BODY")" \
  && pass "sender sealed an encrypted message through Workflow API" \
  || fail "sender sealed-message API failed"

if printf '%s' "$SEALED_RESPONSE" | jq -e '.sealed_message and .sealed_message_size and .trust_root_public_key' >/dev/null 2>&1; then
  pass "sealed response returned sealed transport bytes and trust root"
else
  fail "sealed response missing transport evidence: $SEALED_RESPONSE"
fi
SEALED_MESSAGE="$(printf '%s' "$SEALED_RESPONSE" | jq -c '.sealed_message // empty' 2>/dev/null)"
TRUST_ROOT="$(printf '%s' "$SEALED_RESPONSE" | jq -r '.trust_root_public_key // empty' 2>/dev/null)"
SEALED_BYTES="$(printf '%s' "$SEALED_RESPONSE" | jq -r '.sealed_message.sealed_message // empty' 2>/dev/null)"
SEALED_RECIPIENT_ID="$(printf '%s' "$SEALED_RESPONSE" | jq -r '.sealed_message.recipient_id // empty' 2>/dev/null)"
SEALED_RECIPIENT_DEVICE="$(printf '%s' "$SEALED_RESPONSE" | jq -r '.sealed_message.recipient_device_id // empty' 2>/dev/null)"
if [ "$SEALED_RECIPIENT_ID" = "$RECIPIENT@example.test" ] && [ "$SEALED_RECIPIENT_DEVICE" = "1" ]; then
  pass "sealed transport visible routing matches recipient participant"
else
  fail "sealed transport visible routing mismatch: $SEALED_MESSAGE"
fi
SEALED_TRANSPORT_FILE="$DATA_DIR/sealed-transport.json"
printf '%s' "$SEALED_MESSAGE" >"$SEALED_TRANSPORT_FILE"
[ -s "$SEALED_TRANSPORT_FILE" ] && pass "mock transport persisted sealed sender message JSON" || fail "mock transport did not persist sealed message JSON"
for forbidden in "$MESSAGE_MARKER" "$MESSAGE_B64" "$SENDER@example.test" "$SENDER"; do
  if grep -Fq -- "$forbidden" "$SEALED_TRANSPORT_FILE"; then
    fail "sealed transport leaked forbidden marker $forbidden"
  else
    pass "sealed transport did not leak $forbidden"
  fi
done
if [ -n "$SEALED_BYTES" ] && [ "$SEALED_BYTES" != "null" ]; then
  if printf '%s' "$SEALED_BYTES" | base64_decode 2>/dev/null | grep -a -Fq -- "$SENDER@example.test"; then
    fail "decoded sealed wire bytes exposed sender id"
  else
    pass "decoded sealed wire bytes did not expose sender id"
  fi
else
  fail "sealed response did not include sealed wire bytes"
fi

WRONG_PRINCIPAL_BODY="$(jq -cn --arg principal "principal://$THIRD_PARTY" --argjson sealed_message "$SEALED_MESSAGE" --arg trust_root_public_key "$TRUST_ROOT" \
  '{principal:$principal,sealed_message:$sealed_message,trust_root_public_key:$trust_root_public_key}')" || WRONG_PRINCIPAL_BODY=""
WRONG_PRINCIPAL="$(curl -fsS -X POST "$BASE_URL/participants/$RECIPIENT/sealed/unseal" -H 'Content-Type: application/json' -d "$WRONG_PRINCIPAL_BODY")" \
  && pass "wrong-principal unseal returned Workflow response" \
  || fail "wrong-principal unseal API failed"
if [ "$(printf '%s' "$WRONG_PRINCIPAL" | jq -r '.denied // empty' 2>/dev/null)" = "true" ] &&
   [ -z "$(printf '%s' "$WRONG_PRINCIPAL" | jq -r '.sender_id // empty' 2>/dev/null)" ] &&
   [ -z "$(printf '%s' "$WRONG_PRINCIPAL" | jq -r '.envelope // empty' 2>/dev/null)" ]; then
  pass "wrong-principal unseal denied without sender or envelope"
else
  fail "wrong-principal unseal leaked sender or envelope: $WRONG_PRINCIPAL"
fi

DECRYPT_BODY="$(jq -cn --arg principal "principal://$RECIPIENT" --argjson sealed_message "$SEALED_MESSAGE" --arg trust_root_public_key "$TRUST_ROOT" \
  '{principal:$principal,sealed_message:$sealed_message,trust_root_public_key:$trust_root_public_key}')" || DECRYPT_BODY=""
DECRYPTED="$(curl -fsS -X POST "$BASE_URL/participants/$RECIPIENT/sealed/decrypt" -H 'Content-Type: application/json' -d "$DECRYPT_BODY")" \
  && pass "recipient unsealed and decrypted through Workflow API" \
  || fail "recipient sealed decrypt API failed"
if [ "$(printf '%s' "$DECRYPTED" | jq -r '.sender_id // empty' 2>/dev/null)" = "$SENDER@example.test" ]; then
  pass "recipient learned sender identity only after unseal"
else
  fail "recipient did not recover sender identity after unseal: $DECRYPTED"
fi
DECRYPTED_B64="$(printf '%s' "$DECRYPTED" | jq -r '.plaintext // empty' 2>/dev/null)"
DECRYPTED_TEXT="$(printf '%s' "$DECRYPTED_B64" | base64_decode 2>/dev/null || true)"
if [ "$DECRYPTED_TEXT" = "$MESSAGE_TEXT" ]; then
  pass "recipient recovered original plaintext"
else
  fail "recipient plaintext mismatch: $DECRYPTED"
fi

TAMPERED_MESSAGE="$(printf '%s' "$SEALED_MESSAGE" | jq -c '.sealed_message = (.sealed_message[0:-2] + "AA")' 2>/dev/null || true)"
TAMPERED_BODY="$(jq -cn --arg principal "principal://$RECIPIENT" --argjson sealed_message "$TAMPERED_MESSAGE" --arg trust_root_public_key "$TRUST_ROOT" \
  '{principal:$principal,sealed_message:$sealed_message,trust_root_public_key:$trust_root_public_key}')" || TAMPERED_BODY=""
TAMPERED_STATUS="$(http_status POST "$BASE_URL/participants/$RECIPIENT/sealed/decrypt" "$TAMPERED_BODY")"
case "$TAMPERED_STATUS" in
  000|2*) fail "tampered sealed bytes were accepted with status $TAMPERED_STATUS" ;;
  *) pass "tampered sealed bytes were rejected with status $TAMPERED_STATUS" ;;
esac

WRONG_RECIPIENT_BODY="$(jq -cn --arg principal "principal://$THIRD_PARTY" --argjson sealed_message "$SEALED_MESSAGE" --arg trust_root_public_key "$TRUST_ROOT" \
  '{principal:$principal,sealed_message:$sealed_message,trust_root_public_key:$trust_root_public_key}')" || WRONG_RECIPIENT_BODY=""
WRONG_RECIPIENT_STATUS="$(http_status POST "$BASE_URL/participants/$THIRD_PARTY/sealed/decrypt" "$WRONG_RECIPIENT_BODY")"
case "$WRONG_RECIPIENT_STATUS" in
  000|2*) fail "wrong recipient unsealed message with status $WRONG_RECIPIENT_STATUS" ;;
  *) pass "wrong recipient was rejected with status $WRONG_RECIPIENT_STATUS" ;;
esac

ROUTING_TAMPERED="$(printf '%s' "$SEALED_MESSAGE" | jq -c --arg recipient_id "$THIRD_PARTY@example.test" '.recipient_id = $recipient_id' 2>/dev/null || true)"
ROUTING_TAMPERED_BODY="$(jq -cn --arg principal "principal://$RECIPIENT" --argjson sealed_message "$ROUTING_TAMPERED" --arg trust_root_public_key "$TRUST_ROOT" \
  '{principal:$principal,sealed_message:$sealed_message,trust_root_public_key:$trust_root_public_key}')" || ROUTING_TAMPERED_BODY=""
ROUTING_TAMPERED_STATUS="$(http_status POST "$BASE_URL/participants/$RECIPIENT/sealed/decrypt" "$ROUTING_TAMPERED_BODY")"
case "$ROUTING_TAMPERED_STATUS" in
  000|2*) fail "tampered visible recipient routing was accepted with status $ROUTING_TAMPERED_STATUS" ;;
  *) pass "tampered visible recipient routing was rejected with status $ROUTING_TAMPERED_STATUS" ;;
esac

WRONG_ROOT_CERT="$(curl -fsS -X POST "$BASE_URL/participants/$SENDER/certificate" -H 'Content-Type: application/json' -d '{}')" \
  && pass "sender issued a second local trust root through Workflow API" \
  || fail "sender second certificate API failed"
WRONG_ROOT="$(printf '%s' "$WRONG_ROOT_CERT" | jq -r '.trust_root_public_key // empty' 2>/dev/null)"
WRONG_ROOT_BODY="$(jq -cn --arg principal "principal://$RECIPIENT" --argjson sealed_message "$SEALED_MESSAGE" --arg trust_root_public_key "$WRONG_ROOT" \
  '{principal:$principal,sealed_message:$sealed_message,trust_root_public_key:$trust_root_public_key}')" || WRONG_ROOT_BODY=""
WRONG_ROOT_STATUS="$(http_status POST "$BASE_URL/participants/$RECIPIENT/sealed/decrypt" "$WRONG_ROOT_BODY")"
case "$WRONG_ROOT_STATUS" in
  000|2*) fail "wrong trust root validated sealed message with status $WRONG_ROOT_STATUS" ;;
  *) pass "wrong trust root was rejected with status $WRONG_ROOT_STATUS" ;;
esac

ALT_RECIPIENT="${ALT_RECIPIENT:-tenant-b}"
ALT_SENDER="${ALT_SENDER:-tenant-a}"
ALT_SESSION="$(curl -fsS -X POST "$BASE_URL/participants/$ALT_RECIPIENT/session" -H 'Content-Type: application/json' -d '{}')" \
  && pass "alternate recipient published a bundle through the same app route" \
  || fail "alternate recipient session prepare API failed"
ALT_BUNDLE="$(printf '%s' "$ALT_SESSION" | jq -c '.bundle // empty' 2>/dev/null)"
ALT_TEXT="$(jq -cn --arg marker "$MESSAGE_MARKER-alt" --arg sender "$ALT_SENDER" --arg recipient "$ALT_RECIPIENT" \
  '{kind:"sealed-message",marker:$marker,sender:$sender,recipient:$recipient}')"
ALT_B64="$(printf '%s' "$ALT_TEXT" | base64_encode)"
ALT_SEAL_BODY="$(jq -cn --arg plaintext "$ALT_B64" --argjson remote_bundle "$ALT_BUNDLE" \
  '{plaintext:$plaintext,remote_bundle:$remote_bundle,content_hint:"implicit"}')" || ALT_SEAL_BODY=""
ALT_SEALED="$(curl -fsS -X POST "$BASE_URL/participants/$ALT_SENDER/sealed/$ALT_RECIPIENT" -H 'Content-Type: application/json' -d "$ALT_SEAL_BODY")" \
  && pass "alternate sender sealed through the same participant-parametric route" \
  || fail "alternate sealed-message API failed"
ALT_MESSAGE="$(printf '%s' "$ALT_SEALED" | jq -c '.sealed_message // empty' 2>/dev/null)"
ALT_ROOT="$(printf '%s' "$ALT_SEALED" | jq -r '.trust_root_public_key // empty' 2>/dev/null)"
ALT_DECRYPT_BODY="$(jq -cn --arg principal "principal://$ALT_RECIPIENT" --argjson sealed_message "$ALT_MESSAGE" --arg trust_root_public_key "$ALT_ROOT" \
  '{principal:$principal,sealed_message:$sealed_message,trust_root_public_key:$trust_root_public_key}')" || ALT_DECRYPT_BODY=""
ALT_DECRYPTED="$(curl -fsS -X POST "$BASE_URL/participants/$ALT_RECIPIENT/sealed/decrypt" -H 'Content-Type: application/json' -d "$ALT_DECRYPT_BODY")" \
  && pass "alternate recipient decrypted through the same Workflow API" \
  || fail "alternate sealed decrypt API failed"
ALT_DECRYPTED_TEXT="$(printf '%s' "$ALT_DECRYPTED" | jq -r '.plaintext // empty' 2>/dev/null | base64_decode 2>/dev/null || true)"
if [ "$ALT_DECRYPTED_TEXT" = "$ALT_TEXT" ]; then
  pass "alternate participant pair recovered its own plaintext"
else
  fail "alternate participant pair plaintext mismatch: $ALT_DECRYPTED"
fi

finish
