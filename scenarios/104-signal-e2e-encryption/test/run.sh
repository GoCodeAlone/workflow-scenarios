#!/usr/bin/env bash
# Scenario 104 - Signal E2E Encryption.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-signal subprocess from data/plugins, and drives independent
# HTTP clients through participant-parametric API routes.
set -uo pipefail

PLUGIN_NAME="workflow-plugin-signal"
CLIENT_A="${CLIENT_A:-user-a}"
CLIENT_B="${CLIENT_B:-user-b}"
PLAINTEXT_B64="${PLAINTEXT_B64:-cHJpdmF0ZSB3b3JrZmxvdyBtZXNzYWdl}"
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
  plugin_repo="$(find_repo "${SIGNAL_PLUGIN_REPO:-}" "$REPO_ROOT/../workflow-plugin-signal" "$REPO_ROOT/../../../workflow-plugin-signal")" || return 1

  mkdir -p "$plugin_dir/$PLUGIN_NAME" || return 1
  cp "$plugin_repo/plugin.json" "$plugin_dir/$PLUGIN_NAME/plugin.json" || return 1
  (cd "$plugin_repo" && GOWORK=off go build \
    -ldflags "-X github.com/GoCodeAlone/workflow-plugin-signal/internal.Version=${PLUGIN_VERSION:-0.0.0}" \
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

DATA_DIR="$(mktemp -d)"
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

finish
