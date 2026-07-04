#!/usr/bin/env bash
# Scenario 115 - Signal sealed-sender fanout.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-signal subprocess from data/plugins, and drives a
# participant-parametric room fanout over HTTP.
set -uo pipefail
export LC_ALL=C
export LANG=C

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.20.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
SENDER="${SENDER:-user-a}"
RECIPIENT_ONE="${RECIPIENT_ONE:-user-b}"
RECIPIENT_TWO="${RECIPIENT_TWO:-user-c}"
THIRD_PARTY="${THIRD_PARTY:-tenant-b}"
ALT_SENDER="${ALT_SENDER:-tenant-a}"
ALT_RECIPIENT_ONE="${ALT_RECIPIENT_ONE:-tenant-b}"
ALT_RECIPIENT_TWO="${ALT_RECIPIENT_TWO:-user-c}"
ROOM="${ROOM:-private-room-115}"
ALT_ROOM="${ALT_ROOM:-private-room-115-alt}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18115}"
MESSAGE_MARKER="${MESSAGE_MARKER:-signal-sealed-fanout-secret-115}"

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

plugin_repo_supports_fanout() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.capabilities.moduleTypes | index("signal.identity_store")) and
    (.capabilities.stepTypes | index("step.signal_session_prepare")) and
    (.capabilities.stepTypes | index("step.signal_encrypt")) and
    (.capabilities.stepTypes | index("step.signal_decrypt")) and
    (.capabilities.stepTypes | index("step.signal_sender_certificate_issue")) and
    (.capabilities.stepTypes | index("step.signal_sender_seal_fanout")) and
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
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_fanout "$plugin_repo"; then
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

prepare_bundle() {
  local participant="$1"
  curl -fsS -X POST "$BASE_URL/participants/$participant/session" -H 'Content-Type: application/json' -d '{}'
}

fanout_body() {
  local plaintext_b64="$1"
  local group_id_b64="$2"
  local recipient_one="$3"
  local bundle_one="$4"
  local recipient_two="$5"
  local bundle_two="$6"
  local content_hint="${7:-resendable}"
  jq -cn \
    --arg plaintext "$plaintext_b64" \
    --arg group_id "$group_id_b64" \
    --arg content_hint "$content_hint" \
    --arg recipient_one "$recipient_one" \
    --arg recipient_two "$recipient_two" \
    --argjson bundle_one "$bundle_one" \
    --argjson bundle_two "$bundle_two" \
    '{
      plaintext: $plaintext,
      group_id: $group_id,
      content_hint: $content_hint,
      recipients: [
        {participant: $recipient_one, bundle: $bundle_one},
        {participant: $recipient_two, bundle: $bundle_two}
      ]
    }'
}

decrypt_body() {
  local principal="$1"
  local sealed_message="$2"
  local trust_root="$3"
  jq -cn --arg principal "principal://$principal" --argjson sealed_message "$sealed_message" --arg trust_root_public_key "$trust_root" \
    '{principal:$principal,sealed_message:$sealed_message,trust_root_public_key:$trust_root_public_key}'
}

run_fanout_round() {
  local label="$1"
  local room="$2"
  local sender="$3"
  local recipient_one="$4"
  local recipient_two="$5"
  local marker="$6"
  local content_hint="${7:-resendable}"

  local session_one session_two bundle_one bundle_two message_text message_b64 group_text group_b64 body response trust_root messages_file
  session_one="$(prepare_bundle "$recipient_one")" && pass "$label recipient one published a bundle" || { fail "$label recipient one session failed"; return 1; }
  session_two="$(prepare_bundle "$recipient_two")" && pass "$label recipient two published a bundle" || { fail "$label recipient two session failed"; return 1; }
  bundle_one="$(printf '%s' "$session_one" | jq -c '.bundle // empty' 2>/dev/null)"
  bundle_two="$(printf '%s' "$session_two" | jq -c '.bundle // empty' 2>/dev/null)"
  if [ -n "$bundle_one" ] && [ "$bundle_one" != "null" ] && [ -n "$bundle_two" ] && [ "$bundle_two" != "null" ]; then
    pass "$label recipient bundles contain public Signal material"
  else
    fail "$label recipient bundle missing: $session_one / $session_two"
    return 1
  fi

  message_text="$(jq -cn --arg marker "$marker" --arg room "$room" --arg sender "$sender" \
    --arg recipient_one "$recipient_one" --arg recipient_two "$recipient_two" \
    '{kind:"sealed-fanout",marker:$marker,room:$room,sender:$sender,recipients:[$recipient_one,$recipient_two]}')"
  message_b64="$(printf '%s' "$message_text" | base64_encode)"
  group_text="room://$room"
  group_b64="$(printf '%s' "$group_text" | base64_encode)"
  body="$(fanout_body "$message_b64" "$group_b64" "$recipient_one" "$bundle_one" "$recipient_two" "$bundle_two" "$content_hint")" || body=""
  response="$(curl -fsS -X POST "$BASE_URL/rooms/$room/participants/$sender/fanout" -H 'Content-Type: application/json' -d "$body")" \
    && pass "$label sender created a two-recipient sealed fanout through Workflow API" \
    || { fail "$label fanout API failed"; return 1; }

  if [ "$(printf '%s' "$response" | jq -r '.message_count // empty' 2>/dev/null)" = "2" ] &&
     [ "$(printf '%s' "$response" | jq '.messages | length' 2>/dev/null)" = "2" ]; then
    pass "$label fanout returned exactly two sealed messages"
  else
    fail "$label fanout did not return two messages: $response"
  fi
  trust_root="$(printf '%s' "$response" | jq -r '.trust_root_public_key // empty' 2>/dev/null)"
  messages_file="$DATA_DIR/$label-mock-transport.json"
  printf '%s' "$response" | jq -c '.messages' >"$messages_file"
  [ -s "$messages_file" ] && pass "$label mock transport persisted sealed message list" || fail "$label mock transport did not persist sealed messages"
  for forbidden in "$marker" "$message_b64" "$sender@example.test" "$sender"; do
    if grep -Fq -- "$forbidden" "$messages_file"; then
      fail "$label sealed fanout transport leaked forbidden marker $forbidden"
    else
      pass "$label sealed fanout transport did not leak $forbidden"
    fi
  done

  local idx recipient sealed_message sealed_bytes wire_file decrypted decrypted_b64 decrypted_text decoded_group
  idx=0
  for recipient in "$recipient_one" "$recipient_two"; do
    sealed_message="$(printf '%s' "$response" | jq -c --argjson idx "$idx" '.messages[$idx].sealed_message' 2>/dev/null)"
    if [ "$(printf '%s' "$response" | jq -r --argjson idx "$idx" '.messages[$idx].recipient_ref // empty' 2>/dev/null)" = "principal://$recipient" ]; then
      pass "$label message $idx recipient_ref matches $recipient"
    else
      fail "$label message $idx recipient_ref mismatch: $response"
    fi
    sealed_bytes="$(printf '%s' "$sealed_message" | jq -r '.sealed_message // empty' 2>/dev/null)"
    wire_file="$DATA_DIR/$label-$recipient-wire.bin"
    if printf '%s' "$sealed_bytes" | base64_decode >"$wire_file" 2>/dev/null; then
      pass "$label decoded sealed wire for $recipient"
    else
      fail "$label could not decode sealed wire for $recipient"
    fi
    if grep -a -Fq -- "$sender@example.test" "$wire_file"; then
      fail "$label sealed wire for $recipient exposed sender id"
    else
      pass "$label sealed wire for $recipient did not expose sender id"
    fi
    decrypted="$(curl -fsS -X POST "$BASE_URL/rooms/$room/participants/$recipient/fanout/decrypt" \
      -H 'Content-Type: application/json' -d "$(decrypt_body "$recipient" "$sealed_message" "$trust_root")")" \
      && pass "$label $recipient unsealed and decrypted through Workflow API" \
      || { fail "$label $recipient decrypt API failed"; idx=$((idx + 1)); continue; }
    if [ "$(printf '%s' "$decrypted" | jq -r '.sender_id // empty' 2>/dev/null)" = "$sender@example.test" ]; then
      pass "$label $recipient learned sender identity only after unseal"
    else
      fail "$label $recipient sender identity mismatch: $decrypted"
    fi
    decoded_group="$(printf '%s' "$decrypted" | jq -r '.group_id // empty' 2>/dev/null)"
    if [ "$decoded_group" = "$group_b64" ]; then
      pass "$label $recipient recovered room group id"
    else
      fail "$label $recipient group id mismatch: $decrypted"
    fi
    decrypted_b64="$(printf '%s' "$decrypted" | jq -r '.plaintext // empty' 2>/dev/null)"
    decrypted_text="$(printf '%s' "$decrypted_b64" | base64_decode 2>/dev/null || true)"
    if [ "$decrypted_text" = "$message_text" ]; then
      pass "$label $recipient recovered original plaintext"
    else
      fail "$label $recipient plaintext mismatch: $decrypted"
    fi
    idx=$((idx + 1))
  done

  FANOUT_RESPONSE="$response"
  FANOUT_TRUST_ROOT="$trust_root"
  FANOUT_GROUP_B64="$group_b64"
  FANOUT_MESSAGE_TEXT="$message_text"
}

echo ""
echo "=== Scenario 115 - Signal Sealed Fanout ==="
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
  step.signal_sender_seal_fanout \
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
  pass "built workflow-plugin-signal external plugin with sealed fanout primitive"
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

SENDER_SESSION="$(prepare_bundle "$SENDER")" \
  && pass "sender identity is reachable through Workflow API" \
  || fail "sender session prepare API failed"
if printf '%s' "$SENDER_SESSION" | jq -e '.bundle.identity_key' >/dev/null 2>&1; then
  pass "sender published public identity material"
else
  fail "sender session response missing identity bundle: $SENDER_SESSION"
fi

if ! run_fanout_round primary "$ROOM" "$SENDER" "$RECIPIENT_ONE" "$RECIPIENT_TWO" "$MESSAGE_MARKER" resendable; then
  finish
  exit 1
fi

FIRST_MESSAGE="$(printf '%s' "$FANOUT_RESPONSE" | jq -c '.messages[0].sealed_message' 2>/dev/null)"
SECOND_MESSAGE="$(printf '%s' "$FANOUT_RESPONSE" | jq -c '.messages[1].sealed_message' 2>/dev/null)"

WRONG_PRINCIPAL="$(curl -fsS -X POST "$BASE_URL/rooms/$ROOM/participants/$RECIPIENT_ONE/fanout/unseal" \
  -H 'Content-Type: application/json' -d "$(decrypt_body "$THIRD_PARTY" "$FIRST_MESSAGE" "$FANOUT_TRUST_ROOT")")" \
  && pass "wrong-principal fanout unseal returned Workflow response" \
  || fail "wrong-principal fanout unseal API failed"
if [ "$(printf '%s' "$WRONG_PRINCIPAL" | jq -r '.denied // empty' 2>/dev/null)" = "true" ] &&
   [ -z "$(printf '%s' "$WRONG_PRINCIPAL" | jq -r '.sender_id // empty' 2>/dev/null)" ] &&
   [ -z "$(printf '%s' "$WRONG_PRINCIPAL" | jq -r '.envelope // empty' 2>/dev/null)" ]; then
  pass "wrong-principal fanout unseal denied without sender or envelope"
else
  fail "wrong-principal fanout unseal leaked sender or envelope: $WRONG_PRINCIPAL"
fi

WRONG_RECIPIENT_STATUS="$(http_status POST "$BASE_URL/rooms/$ROOM/participants/$RECIPIENT_TWO/fanout/decrypt" "$(decrypt_body "$RECIPIENT_TWO" "$FIRST_MESSAGE" "$FANOUT_TRUST_ROOT")")"
case "$WRONG_RECIPIENT_STATUS" in
  000|2*) fail "wrong recipient decrypted first fanout message with status $WRONG_RECIPIENT_STATUS" ;;
  *) pass "wrong recipient was rejected for first fanout message with status $WRONG_RECIPIENT_STATUS" ;;
esac

if TAMPERED_MESSAGE="$(printf '%s' "$FIRST_MESSAGE" | jq -ec '.sealed_message = (.sealed_message[0:-2] + "AA")' 2>/dev/null)" &&
   [ -n "$TAMPERED_MESSAGE" ] && [ "$TAMPERED_MESSAGE" != "$FIRST_MESSAGE" ]; then
  pass "constructed tampered fanout sealed-byte payload"
else
  fail "could not construct tampered fanout sealed-byte payload"
  finish
  exit 1
fi
TAMPERED_STATUS="$(http_status POST "$BASE_URL/rooms/$ROOM/participants/$RECIPIENT_ONE/fanout/decrypt" "$(decrypt_body "$RECIPIENT_ONE" "$TAMPERED_MESSAGE" "$FANOUT_TRUST_ROOT")")"
case "$TAMPERED_STATUS" in
  000|2*) fail "tampered fanout sealed bytes were accepted with status $TAMPERED_STATUS" ;;
  *) pass "tampered fanout sealed bytes were rejected with status $TAMPERED_STATUS" ;;
esac

DUP_BODY="$(printf '%s' "$FANOUT_RESPONSE" >/dev/null; fanout_body "$(printf '%s' "$FANOUT_MESSAGE_TEXT" | base64_encode)" "$FANOUT_GROUP_B64" "$RECIPIENT_ONE" "$(prepare_bundle "$RECIPIENT_ONE" | jq -c '.bundle')" "$RECIPIENT_ONE" "$(prepare_bundle "$RECIPIENT_TWO" | jq -c '.bundle')" resendable)" || DUP_BODY=""
DUP_STATUS="$(http_status POST "$BASE_URL/rooms/$ROOM/participants/$SENDER/fanout" "$DUP_BODY")"
case "$DUP_STATUS" in
  000|2*) fail "duplicate-recipient fanout was accepted with status $DUP_STATUS" ;;
  *) pass "duplicate-recipient fanout was rejected with status $DUP_STATUS" ;;
esac

if ! run_fanout_round alternate "$ALT_ROOM" "$ALT_SENDER" "$ALT_RECIPIENT_ONE" "$ALT_RECIPIENT_TWO" "$MESSAGE_MARKER-alt" implicit; then
  finish
  exit 1
fi
ALT_TRUST_ROOT="$FANOUT_TRUST_ROOT"
WRONG_ROOT_STATUS="$(http_status POST "$BASE_URL/rooms/$ROOM/participants/$RECIPIENT_ONE/fanout/decrypt" "$(decrypt_body "$RECIPIENT_ONE" "$FIRST_MESSAGE" "$ALT_TRUST_ROOT")")"
case "$WRONG_ROOT_STATUS" in
  000|2*) fail "wrong trust root validated fanout sealed message with status $WRONG_ROOT_STATUS" ;;
  *) pass "wrong trust root was rejected with status $WRONG_ROOT_STATUS" ;;
esac

if [ "$(printf '%s' "$SECOND_MESSAGE" | jq -r '.recipient_id // empty' 2>/dev/null)" = "$RECIPIENT_TWO@example.test" ]; then
  pass "second fanout message visible routing belongs to second recipient"
else
  fail "second fanout message visible routing mismatch: $SECOND_MESSAGE"
fi

finish
