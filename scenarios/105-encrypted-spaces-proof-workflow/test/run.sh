#!/usr/bin/env bash
# Scenario 105 - Encrypted Spaces Proof Workflow.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-encrypted-spaces subprocess from data/plugins, and drives a
# space/member API through separate HTTP calls. Storage is an in-memory plugin
# module, not S3.
set -uo pipefail

PLUGIN_NAME="workflow-plugin-encrypted-spaces"
BASE_URL="${BASE_URL:-http://127.0.0.1:18105}"
SPACE_ID="${SPACE_ID:-space-1}"
MEMBER_ID="${MEMBER_ID:-member-1}"
DEVICE_ID="${DEVICE_ID:-device-1}"
OPERATION_ID="${OPERATION_ID:-verified-op}"
MEMBERSHIP_DIGEST="sha256:2f99cb90ee710be078aaf1b8cb9a22942c10f5965e5e39c1607a930fd6df7874"
CHECKPOINT_DIGEST="sha256:479338417f33b12df048fbe2180f58638636b2618d90ac6f807ed436ff881d8c"

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
  plugin_repo="$(find_repo "${ENCRYPTED_SPACES_PLUGIN_REPO:-}" "$REPO_ROOT/../workflow-plugin-encrypted-spaces" "$REPO_ROOT/../../../workflow-plugin-encrypted-spaces")" || return 1

  mkdir -p "$plugin_dir/$PLUGIN_NAME" || return 1
  cp "$plugin_repo/plugin.json" "$plugin_dir/$PLUGIN_NAME/plugin.json" || return 1
  (cd "$plugin_repo" && GOWORK=off go build \
    -ldflags "-X github.com/GoCodeAlone/workflow-plugin-encrypted-spaces/internal.Version=${PLUGIN_VERSION:-0.0.0}" \
    -o "$plugin_dir/$PLUGIN_NAME/$PLUGIN_NAME" ./cmd/workflow-plugin-encrypted-spaces) >/dev/null 2>&1 || return 1
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
echo "=== Scenario 105 - Encrypted Spaces Proof Workflow ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if grep -q 'operation_id: verified-op' "$CONFIG"; then
  fail "Workflow pipelines should not hard-code the scenario operation id"
else
  pass "Workflow API accepts operation/proof inputs from clients"
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
  pass "built workflow-plugin-encrypted-spaces external plugin"
else
  fail "could not build workflow-plugin-encrypted-spaces; set ENCRYPTED_SPACES_PLUGIN_REPO"
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

OPERATION="$(jq -cn \
  --arg space "$SPACE_ID" \
  --arg member "$MEMBER_ID" \
  --arg device "$DEVICE_ID" \
  --arg operation "$OPERATION_ID" \
  '{operation:{space_id:$space,member_id:$member,device_id:$device,operation_id:$operation,key_epoch:1,membership_epoch:1,ciphertext:"c2VhbGVkLWNvbGxhYi1wYXlsb2Fk",nonce:"bm9uY2UtMTIzNDU2Nzg5MDEy",associated_data:"c3BhY2UtMS9yb29tLTE=",created_at_unix_nano:1783000000000000000}}')" || OPERATION=""
APPENDED="$(curl -fsS -X POST "$BASE_URL/spaces/$SPACE_ID/operations" -H 'Content-Type: application/json' -d "$OPERATION")" \
  && pass "client appended an encrypted operation through Workflow API" \
  || fail "operation append API failed"

COMMITMENT="$(printf '%s' "$APPENDED" | jq -c '.commitment // empty' 2>/dev/null)"
if [ -n "$COMMITMENT" ] && [ "$COMMITMENT" != "null" ]; then
  pass "append response contained an operation commitment"
else
  fail "append response did not contain a commitment: $APPENDED"
fi

PROOF_REQUEST="$(jq -cn \
  --argjson operation "$(printf '%s' "$OPERATION" | jq -c '.operation')" \
  --argjson expected_commitment "$COMMITMENT" \
  --arg member "$MEMBER_ID" \
  --arg membership_digest "$MEMBERSHIP_DIGEST" \
  --arg checkpoint_digest "$CHECKPOINT_DIGEST" \
  '{operation:$operation,expected_commitment:$expected_commitment,membership:{group_id:"space-1",member_id:$member,issuer:"issuer-1",expires_at:1893456000,proof_digest:$membership_digest,upstream_path:"java/shared/java/org/signal/libsignal/zkgroup/groups"},checkpoint:{checkpoint_id:"checkpoint-1",tree_head:"tree-head-1",tree_size:42,proof_digest:$checkpoint_digest,upstream_path:"rust/keytrans/src/verify.rs",previous_tree_size:0}}')" || PROOF_REQUEST=""
PROOF="$(curl -fsS -X POST "$BASE_URL/spaces/$SPACE_ID/proof" -H 'Content-Type: application/json' -d "$PROOF_REQUEST")" \
  && pass "proof client verified the operation through Workflow API" \
  || fail "proof verification API failed"

if printf '%s' "$PROOF" | jq -e '.reports[] | select(.domain=="operationlog.commitment" and .accepted==true)' >/dev/null 2>&1; then
  pass "proof response contains accepted operationlog commitment report"
else
  fail "proof response missing accepted operationlog report: $PROOF"
fi

if printf '%s' "$PROOF" | jq -e '.reports[] | select(.domain=="zkgroup.membership" and .production_ready==true)' >/dev/null 2>&1; then
  pass "proof response contains vector-backed membership report"
else
  fail "proof response missing vector-backed membership report: $PROOF"
fi

if printf '%s' "$PROOF" | jq -e '.json.reports[] | select(.domain=="operationlog.commitment")' >/dev/null 2>&1; then
  pass "redacted proof evidence JSON was returned by the app"
else
  fail "proof evidence JSON missing operationlog domain: $PROOF"
fi

if printf '%s' "$PROOF" | grep -q 'c2VhbGVkLWNvbGxhYi1wYXlsb2Fk'; then
  fail "proof response leaked ciphertext payload"
else
  pass "proof response did not leak ciphertext payload"
fi

finish
