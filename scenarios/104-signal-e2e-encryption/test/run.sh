#!/usr/bin/env bash
# Scenario 104 - Signal E2E Encryption.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-signal subprocess from data/plugins, and drives independent
# HTTP clients through participant-parametric API routes.
set -uo pipefail

PLUGIN_NAME="workflow-plugin-signal"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.11.0}"
if [ -z "${PLUGIN_VERSION+x}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
CLIENT_A="${CLIENT_A:-user-a}"
CLIENT_B="${CLIENT_B:-user-b}"
PLAINTEXT_B64="${PLAINTEXT_B64:-cHJpdmF0ZSB3b3JrZmxvdyBtZXNzYWdl}"
REPLY_PLAINTEXT_B64="${REPLY_PLAINTEXT_B64:-c2Vjb25kIHByaXZhdGUgd29ya2Zsb3cgbWVzc2FnZQ==}"
SERVICE_REQUEST_ID="${SERVICE_REQUEST_ID:-scenario-104-send-prepare}"
SERVICE_PAYLOAD_REF="${SERVICE_PAYLOAD_REF:-payload://scenario-104/message}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18104}"

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

plugin_repo_supports_service_readiness() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '
    (.capabilities.moduleTypes | index("signal.key_custody")) and
    (.capabilities.moduleTypes | index("signal.account_ref")) and
    (.capabilities.stepTypes | index("step.signal_service_send_prepare"))
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
echo "=== Scenario 104 - Signal E2E Encryption ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if grep -Eiq 'alice|bob' "$CONFIG"; then
  fail "Workflow pipelines should not hard-code Alice/Bob participant names"
else
  pass "Workflow API is participant-parametric"
fi

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
  && pass "client B published a pre-key bundle via Workflow API" \
  || fail "client B session prepare API failed"

BUNDLE="$(printf '%s' "$SESSION_B" | jq -c '.bundle // empty' 2>/dev/null)"
if [ -n "$BUNDLE" ] && [ "$BUNDLE" != "null" ]; then
  pass "client B response contained a bundle"
else
  fail "client B response did not contain a bundle: $SESSION_B"
fi

SESSION_A="$(curl -fsS -X POST "$BASE_URL/participants/$CLIENT_A/session" -H 'Content-Type: application/json' -d '{}')" \
  && pass "client A published a pre-key bundle via Workflow API" \
  || fail "client A session prepare API failed"

BUNDLE_A="$(printf '%s' "$SESSION_A" | jq -c '.bundle // empty' 2>/dev/null)"
if [ -n "$BUNDLE_A" ] && [ "$BUNDLE_A" != "null" ]; then
  pass "client A response contained a bundle"
else
  fail "client A response did not contain a bundle: $SESSION_A"
fi

ENCRYPT_BODY="$(jq -cn --arg plaintext "$PLAINTEXT_B64" --argjson remote_bundle "$BUNDLE" \
  '{plaintext:$plaintext, remote_bundle:$remote_bundle}')" || ENCRYPT_BODY=""
ENCRYPTED="$(curl -fsS -X POST "$BASE_URL/participants/$CLIENT_A/messages" -H 'Content-Type: application/json' -d "$ENCRYPT_BODY")" \
  && pass "client A encrypted a message to client B through Workflow API" \
  || fail "client A encrypt API failed"

ENVELOPE="$(printf '%s' "$ENCRYPTED" | jq -c '.envelope // empty' 2>/dev/null)"
if [ -n "$ENVELOPE" ] && [ "$ENVELOPE" != "null" ]; then
  pass "client A response contained an encrypted envelope"
else
  fail "client A response did not contain an envelope: $ENCRYPTED"
fi

if printf '%s' "$ENVELOPE" | grep -q "$PLAINTEXT_B64"; then
  fail "encrypted envelope leaked plaintext"
else
  pass "encrypted envelope did not contain plaintext"
fi

DECRYPT_BODY="$(jq -cn --arg principal "$CLIENT_B" --argjson envelope "$ENVELOPE" \
  '{principal:$principal, envelope:$envelope}')" || DECRYPT_BODY=""
DECRYPTED="$(curl -fsS -X POST "$BASE_URL/participants/$CLIENT_B/messages/decrypt" -H 'Content-Type: application/json' -d "$DECRYPT_BODY")" \
  && pass "client B decrypted client A message through Workflow API" \
  || fail "client B decrypt API failed"

GOT="$(printf '%s' "$DECRYPTED" | jq -r '.plaintext // empty' 2>/dev/null)"
if [ "$GOT" = "$PLAINTEXT_B64" ]; then
  pass "client B recovered the original plaintext"
else
  fail "client B plaintext mismatch: got '$GOT'"
fi

REPLY_BODY="$(jq -cn --arg plaintext "$REPLY_PLAINTEXT_B64" --argjson remote_bundle "$BUNDLE_A" \
  '{plaintext:$plaintext, remote_bundle:$remote_bundle}')" || REPLY_BODY=""
REPLY_ENCRYPTED="$(curl -fsS -X POST "$BASE_URL/participants/$CLIENT_B/messages" -H 'Content-Type: application/json' -d "$REPLY_BODY")" \
  && pass "client B encrypted a reply to client A through Workflow API" \
  || fail "client B reply encrypt API failed"

REPLY_ENVELOPE="$(printf '%s' "$REPLY_ENCRYPTED" | jq -c '.envelope // empty' 2>/dev/null)"
if [ -n "$REPLY_ENVELOPE" ] && [ "$REPLY_ENVELOPE" != "null" ]; then
  pass "client B reply response contained an encrypted envelope"
else
  fail "client B reply response did not contain an envelope: $REPLY_ENCRYPTED"
fi

if printf '%s' "$REPLY_ENVELOPE" | grep -q "$REPLY_PLAINTEXT_B64"; then
  fail "reply encrypted envelope leaked plaintext"
else
  pass "reply encrypted envelope did not contain plaintext"
fi

REPLY_DECRYPT_BODY="$(jq -cn --arg principal "$CLIENT_A" --argjson envelope "$REPLY_ENVELOPE" \
  '{principal:$principal, envelope:$envelope}')" || REPLY_DECRYPT_BODY=""
REPLY_DECRYPTED="$(curl -fsS -X POST "$BASE_URL/participants/$CLIENT_A/messages/decrypt" -H 'Content-Type: application/json' -d "$REPLY_DECRYPT_BODY")" \
  && pass "client A decrypted client B reply through Workflow API" \
  || fail "client A reply decrypt API failed"

REPLY_GOT="$(printf '%s' "$REPLY_DECRYPTED" | jq -r '.plaintext // empty' 2>/dev/null)"
if [ "$REPLY_GOT" = "$REPLY_PLAINTEXT_B64" ]; then
  pass "client A recovered the reply plaintext"
else
  fail "client A reply plaintext mismatch: got '$REPLY_GOT'"
fi

if [ "$(printf '%s' "$ENVELOPE" | jq -c . 2>/dev/null)" != "$(printf '%s' "$REPLY_ENVELOPE" | jq -c . 2>/dev/null)" ]; then
  pass "two-way exchange produced distinct encrypted envelopes"
else
  fail "two-way exchange reused the same encrypted envelope"
fi

SERVICE_BODY="$(jq -cn \
  --arg idempotency_key "$SERVICE_REQUEST_ID" \
  --arg recipient_ref "participant://$CLIENT_B" \
  --arg payload_ref "$SERVICE_PAYLOAD_REF" \
  '{idempotency_key:$idempotency_key,recipient_ref:$recipient_ref,payload_ref:$payload_ref}')" || SERVICE_BODY=""
SERVICE_READY="$(curl -fsS -X POST "$BASE_URL/participants/$CLIENT_A/service/send-prepare" -H 'Content-Type: application/json' -d "$SERVICE_BODY")" \
  && pass "client A prepared a custody-attested service send through Workflow API" \
  || fail "client A service send prepare API failed"

if [ "$(printf '%s' "$SERVICE_READY" | jq -r '.sender // empty' 2>/dev/null)" = "$CLIENT_A" ]; then
  pass "service send readiness response preserved caller participant"
else
  fail "service send readiness response lost caller participant: $SERVICE_READY"
fi

if [ "$(printf '%s' "$SERVICE_READY" | jq -r '.custody_attested // empty' 2>/dev/null)" = "true" ]; then
  pass "service send readiness returned custody attestation"
else
  fail "service send readiness did not attest custody: $SERVICE_READY"
fi

if [ "$(printf '%s' "$SERVICE_READY" | jq -r '.custody_attestation_ref // empty' 2>/dev/null)" = "attest://signal/custody/custody-signal-service-test-device-1" ]; then
  pass "service send readiness returned stable custody attestation ref"
else
  fail "service send readiness returned unexpected attestation ref: $SERVICE_READY"
fi

READY_RECIPIENT="$(printf '%s' "$SERVICE_READY" | jq -r '.envelope.recipient_ref // empty' 2>/dev/null)"
READY_PAYLOAD="$(printf '%s' "$SERVICE_READY" | jq -r '.envelope.payload_ref // empty' 2>/dev/null)"
if [ "$READY_RECIPIENT" = "participant://$CLIENT_B" ] && [ "$READY_PAYLOAD" = "$SERVICE_PAYLOAD_REF" ]; then
  pass "service send readiness preserved caller-supplied recipient and payload refs"
else
  fail "service send readiness refs mismatch: $SERVICE_READY"
fi

READY_KEY_REF="$(printf '%s' "$SERVICE_READY" | jq -r '.envelope.non_exportable_key_ref // empty' 2>/dev/null)"
if [ "$READY_KEY_REF" = "kms://signal/service-test/device-1" ]; then
  pass "service send readiness inherited non-exportable key custody ref"
else
  fail "service send readiness missing non-exportable key ref: $SERVICE_READY"
fi

finish
