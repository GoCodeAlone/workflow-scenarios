#!/usr/bin/env bash
# Scenario 105 - Encrypted Spaces Proof Workflow.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-encrypted-spaces subprocess from data/plugins, and drives a
# space/member API through separate HTTP calls. Storage is a local file-backed
# plugin module, not S3.
set -uo pipefail

PLUGIN_NAME="workflow-plugin-encrypted-spaces"
BASE_URL="${BASE_URL:-http://127.0.0.1:18105}"
ENCRYPTED_SPACES_PLUGIN_REF="${ENCRYPTED_SPACES_PLUGIN_REF:-v0.6.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$ENCRYPTED_SPACES_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${ENCRYPTED_SPACES_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$ENCRYPTED_SPACES_PLUGIN_REF" ;;
  esac
fi
# The proof digests below are fixture defaults for the default space/member
# tuples. Override the tuple only with matching proof digest overrides.
SPACE_ID_ENV_SET="${SPACE_ID+x}"
MEMBER_A_ID_ENV_SET="${MEMBER_ID+x}"
MEMBER_B_ID_ENV_SET="${MEMBER_B_ID+x}"
MEMBERSHIP_A_DIGEST_ENV_SET="${MEMBERSHIP_DIGEST+x}"
MEMBERSHIP_B_DIGEST_ENV_SET="${MEMBERSHIP_B_DIGEST+x}"
CHECKPOINT_DIGEST_ENV_SET="${CHECKPOINT_DIGEST+x}"
SPACE_ID="${SPACE_ID:-space-1}"
MEMBER_A_ID="${MEMBER_ID:-member-1}"
MEMBER_B_ID="${MEMBER_B_ID:-member-2}"
UNKNOWN_MEMBER_ID="${UNKNOWN_MEMBER_ID:-member-unknown}"
DEVICE_A_ID="${DEVICE_ID:-device-1}"
DEVICE_B_ID="${DEVICE_B_ID:-device-2}"
OPERATION_A_ID="${OPERATION_ID:-verified-op-a}"
OPERATION_B_ID="${OPERATION_B_ID:-verified-op-b}"
MEMBERSHIP_A_DIGEST="${MEMBERSHIP_DIGEST:-sha256:2f99cb90ee710be078aaf1b8cb9a22942c10f5965e5e39c1607a930fd6df7874}"
MEMBERSHIP_B_DIGEST="${MEMBERSHIP_B_DIGEST:-sha256:c31f6d764ac0dad1b4687f540a4e6d4aa10a7ce30948e5d590ae9134bc16980f}"
CHECKPOINT_DIGEST="${CHECKPOINT_DIGEST:-sha256:479338417f33b12df048fbe2180f58638636b2618d90ac6f807ed436ff881d8c}"

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

plugin_repo_supports_state_store() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '.capabilities.moduleTypes | index("encrypted_space.state_store")' "$repo/plugin.json" >/dev/null 2>&1 || return 1
  grep -q 'allow_file_state_store' "$repo/internal/contracts/spaces.proto" 2>/dev/null
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
  plugin_repo="$(find_repo "${ENCRYPTED_SPACES_PLUGIN_REPO:-}" "$REPO_ROOT/../workflow-plugin-encrypted-spaces" "$REPO_ROOT/../../../workflow-plugin-encrypted-spaces")" || plugin_repo=""
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_state_store "$plugin_repo"; then
    plugin_repo="$DATA_DIR/repos/workflow-plugin-encrypted-spaces"
    mkdir -p "$(dirname "$plugin_repo")" || return 1
    if git ls-remote --exit-code --tags https://github.com/GoCodeAlone/workflow-plugin-encrypted-spaces.git "refs/tags/$ENCRYPTED_SPACES_PLUGIN_REF" >/dev/null 2>&1; then
      git clone --quiet --depth 1 https://github.com/GoCodeAlone/workflow-plugin-encrypted-spaces.git "$plugin_repo" || return 1
      git -C "$plugin_repo" fetch --quiet --depth 1 origin "refs/tags/$ENCRYPTED_SPACES_PLUGIN_REF:refs/tags/$ENCRYPTED_SPACES_PLUGIN_REF" || return 1
      git -C "$plugin_repo" -c advice.detachedHead=false checkout --quiet "$ENCRYPTED_SPACES_PLUGIN_REF^{commit}" || return 1
    else
      git clone --quiet --depth 1 --branch "$ENCRYPTED_SPACES_PLUGIN_REF" \
        https://github.com/GoCodeAlone/workflow-plugin-encrypted-spaces.git "$plugin_repo" || return 1
    fi
  fi

  mkdir -p "$plugin_dir/$PLUGIN_NAME" || return 1
  cp "$plugin_repo/plugin.json" "$plugin_dir/$PLUGIN_NAME/plugin.json" || return 1
  (cd "$plugin_repo" && GOWORK=off go build \
    -ldflags "-X github.com/GoCodeAlone/workflow-plugin-encrypted-spaces/internal.Version=${PLUGIN_VERSION}" \
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
VECTOR_OVERRIDE_COUNT=0
[ -n "$SPACE_ID_ENV_SET" ] && VECTOR_OVERRIDE_COUNT=$((VECTOR_OVERRIDE_COUNT + 1))
[ -n "$MEMBER_A_ID_ENV_SET" ] && VECTOR_OVERRIDE_COUNT=$((VECTOR_OVERRIDE_COUNT + 1))
[ -n "$MEMBER_B_ID_ENV_SET" ] && VECTOR_OVERRIDE_COUNT=$((VECTOR_OVERRIDE_COUNT + 1))
[ -n "$MEMBERSHIP_A_DIGEST_ENV_SET" ] && VECTOR_OVERRIDE_COUNT=$((VECTOR_OVERRIDE_COUNT + 1))
[ -n "$MEMBERSHIP_B_DIGEST_ENV_SET" ] && VECTOR_OVERRIDE_COUNT=$((VECTOR_OVERRIDE_COUNT + 1))
[ -n "$CHECKPOINT_DIGEST_ENV_SET" ] && VECTOR_OVERRIDE_COUNT=$((VECTOR_OVERRIDE_COUNT + 1))
if [ "$VECTOR_OVERRIDE_COUNT" -ne 0 ] && [ "$VECTOR_OVERRIDE_COUNT" -ne 6 ]; then
  fail "SPACE_ID, MEMBER_ID, MEMBER_B_ID, MEMBERSHIP_DIGEST, MEMBERSHIP_B_DIGEST, and CHECKPOINT_DIGEST must be overridden together"
  finish
  exit 1
fi
pass "encrypted-space proof vector inputs are complete"
if grep -q 'operation_id: verified-op' "$CONFIG"; then
  fail "Workflow pipelines should not hard-code the scenario operation id"
else
  pass "Workflow API accepts operation/proof inputs from clients"
fi
for step_type in \
  step.encrypted_space_state_init \
  step.encrypted_space_state_load \
  step.encrypted_space_state_save \
  step.encrypted_space_member_check \
  step.encrypted_space_state_update
do
  if grep -q "type: $step_type" "$CONFIG"; then
    pass "Workflow app config exercises $step_type"
  else
    fail "Workflow app config does not exercise $step_type"
  fi
done
if grep -q 'type: encrypted_space.state_store' "$CONFIG"; then
  pass "Workflow app config owns encrypted-space lifecycle state"
else
  fail "Workflow app config does not declare encrypted_space.state_store"
fi
if grep -q 'path: /spaces/{space}/members/{member}/operations' "$CONFIG"; then
  pass "Workflow operation route is participant-parametric"
else
  fail "Workflow operation route does not accept participant IDs from clients"
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
STATE_FILE="$DATA_DIR/encrypted-space-state.json"
RUNTIME_CONFIG="$DATA_DIR/app.yaml"
sed "s#__STATE_STORE_PATH__#$STATE_FILE#g" "$CONFIG" >"$RUNTIME_CONFIG" \
  && pass "generated Workflow app config with per-run local file state store" \
  || fail "could not generate runtime Workflow app config"
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
start_server() {
  "$SERVER_BIN" -config "$RUNTIME_CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
}

stop_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  SERVER_PID=""
}

start_server

if wait_for_server "$BASE_URL"; then
  pass "workflow server started and served /healthz"
else
  fail "workflow server did not become ready; see $SERVER_LOG"
  finish
  exit 1
fi

operation_payload() {
  local member="$1"
  local device="$2"
  local operation_id="$3"
  local ciphertext="$4"
  local nonce="$5"
  jq -cn \
    --arg space "$SPACE_ID" \
    --arg member "$member" \
    --arg device "$device" \
    --arg operation "$operation_id" \
    --arg ciphertext "$ciphertext" \
    --arg nonce "$nonce" \
    '{operation:{space_id:$space,member_id:$member,device_id:$device,operation_id:$operation,key_epoch:1,membership_epoch:1,ciphertext:$ciphertext,nonce:$nonce,associated_data:"c3BhY2UtMS9yb29tLTE=",created_at_unix_nano:1783000000000000000}}'
}

init_members="$(jq -cn --arg member_a "$MEMBER_A_ID" --arg member_b "$MEMBER_B_ID" '{members:[$member_a,$member_b]}')" || init_members=""
init_response="$(curl -fsS -X POST "$BASE_URL/spaces/$SPACE_ID/members" -H 'Content-Type: application/json' -d "$init_members")" \
  && pass "clients initialized encrypted-space membership through Workflow API" \
  || fail "membership initialization API failed"
if printf '%s' "$init_response" | jq -e --arg member_a "$MEMBER_A_ID" --arg member_b "$MEMBER_B_ID" '.stored == true and (.state.members | index($member_a)) and (.state.members | index($member_b))' >/dev/null 2>&1; then
  pass "Workflow app persisted the initialized member state"
else
  fail "membership initialization did not persist both members: $init_response"
fi

check_member_allowed() {
  local label="$1"
  local member="$2"
  local expected="$3"
  local response
  response="$(curl -fsS -X POST "$BASE_URL/spaces/$SPACE_ID/members/$member/check" -H 'Content-Type: application/json' -d '{}')" \
    && pass "$label membership check API responded" \
    || fail "$label membership check API failed"
  if [ "$expected" = "true" ] && printf '%s' "$response" | jq -e '.member_allowed == true' >/dev/null 2>&1; then
    pass "$label membership check returned member_allowed=$expected"
  elif [ "$expected" = "false" ] && printf '%s' "$response" | jq -e '.member_allowed != true and .member_removed == true' >/dev/null 2>&1; then
    pass "$label membership check returned member_allowed=$expected"
  else
    fail "$label membership check had unexpected result: $response"
  fi
}

check_member_allowed "member A" "$MEMBER_A_ID" true
check_member_allowed "member B" "$MEMBER_B_ID" true

unknown_body="$(mktemp)"
unknown_operation="$(operation_payload "$UNKNOWN_MEMBER_ID" "device-unknown" "unknown-op" "dW5rbm93bi1wYXlsb2Fk" "dW5rbm93bi1ub25jZQ==")" || unknown_operation=""
unknown_status="$(curl -sS -o "$unknown_body" -w '%{http_code}' -X POST "$BASE_URL/spaces/$SPACE_ID/members/$UNKNOWN_MEMBER_ID/operations" -H 'Content-Type: application/json' -d "$unknown_operation")" \
  || unknown_status=""
if [ "$unknown_status" = "403" ]; then
  pass "unknown member append was rejected by Workflow API"
else
  fail "unknown member append status=$unknown_status body=$(cat "$unknown_body")"
fi
rm -f "$unknown_body"

run_collaborator_flow() {
  local slot="$1"
  local label="$2"
  local member="$3"
  local device="$4"
  local operation_id="$5"
  local membership_digest="$6"
  local ciphertext="$7"
  local nonce="$8"
  local operation appended commitment proof_request proof digest

  operation="$(operation_payload "$member" "$device" "$operation_id" "$ciphertext" "$nonce")" || operation=""
  appended="$(curl -fsS -X POST "$BASE_URL/spaces/$SPACE_ID/members/$member/operations" -H 'Content-Type: application/json' -d "$operation")" \
    && pass "$label appended an encrypted operation through Workflow API" \
    || fail "$label operation append API failed"

  if printf '%s' "$appended" | jq -e '.member_allowed == true' >/dev/null 2>&1; then
    pass "$label append was authorized by persisted membership state"
  else
    fail "$label append did not include member authorization evidence: $appended"
  fi

  commitment="$(printf '%s' "$appended" | jq -c '.commitment // empty' 2>/dev/null)"
  if [ -n "$commitment" ] && [ "$commitment" != "null" ]; then
    pass "$label append response contained an operation commitment"
  else
    fail "$label append response did not contain a commitment: $appended"
  fi

  digest="$(printf '%s' "$commitment" | jq -r '.digest // empty' 2>/dev/null)"
  printf -v "COMMITMENT_DIGEST_$slot" '%s' "$digest"

  proof_request="$(jq -cn \
    --argjson operation "$(printf '%s' "$operation" | jq -c '.operation')" \
    --argjson expected_commitment "$commitment" \
    --arg space "$SPACE_ID" \
    --arg member "$member" \
    --arg membership_digest "$membership_digest" \
    --arg checkpoint_digest "$CHECKPOINT_DIGEST" \
    '{operation:$operation,expected_commitment:$expected_commitment,membership:{group_id:$space,member_id:$member,issuer:"issuer-1",expires_at:1893456000,proof_digest:$membership_digest,upstream_path:"java/shared/java/org/signal/libsignal/zkgroup/groups"},checkpoint:{checkpoint_id:"checkpoint-1",tree_head:"tree-head-1",tree_size:42,proof_digest:$checkpoint_digest,upstream_path:"rust/keytrans/src/verify.rs",previous_tree_size:0}}')" || proof_request=""
  proof="$(curl -fsS -X POST "$BASE_URL/spaces/$SPACE_ID/proof" -H 'Content-Type: application/json' -d "$proof_request")" \
    && pass "$label proof client verified the operation through Workflow API" \
    || fail "$label proof verification API failed"

  if printf '%s' "$proof" | jq -e '.reports[] | select(.domain=="operationlog.commitment" and .accepted==true)' >/dev/null 2>&1; then
    pass "$label proof response contains accepted operationlog commitment report"
  else
    fail "$label proof response missing accepted operationlog report: $proof"
  fi

  if printf '%s' "$proof" | jq -e '.json.reports[] | select(.domain=="zkgroup.membership")' >/dev/null 2>&1; then
    pass "$label redacted proof evidence JSON contains membership proof report"
  else
    fail "$label proof evidence JSON missing membership domain: $proof"
  fi

  if printf '%s' "$proof" | jq -e '.reports[] | select(.domain=="zkgroup.membership" and .production_ready==true)' >/dev/null 2>&1; then
    pass "$label proof response contains vector-backed membership report"
  else
    fail "$label proof response missing vector-backed membership report: $proof"
  fi

  if printf '%s' "$proof" | grep -q "$ciphertext"; then
    fail "$label proof response leaked ciphertext payload"
  else
    pass "$label proof response did not leak ciphertext payload"
  fi
}

COMMITMENT_DIGEST_1=""
COMMITMENT_DIGEST_2=""
run_collaborator_flow 1 "member A" "$MEMBER_A_ID" "$DEVICE_A_ID" "$OPERATION_A_ID" "$MEMBERSHIP_A_DIGEST" "c2VhbGVkLWNvbGxhYi1wYXlsb2FkLWE=" "bm9uY2UtYS0xMjM0NTY3ODkw"
run_collaborator_flow 2 "member B" "$MEMBER_B_ID" "$DEVICE_B_ID" "$OPERATION_B_ID" "$MEMBERSHIP_B_DIGEST" "c2VhbGVkLWNvbGxhYi1wYXlsb2FkLWI=" "bm9uY2UtYi0xMjM0NTY3ODkw"

if [ -n "$COMMITMENT_DIGEST_1" ] && [ -n "$COMMITMENT_DIGEST_2" ] && [ "$COMMITMENT_DIGEST_1" != "$COMMITMENT_DIGEST_2" ]; then
  pass "member A and member B produced distinct operation commitments"
else
  fail "member A and member B commitments were not distinct"
fi

remove_response="$(curl -fsS -X POST "$BASE_URL/spaces/$SPACE_ID/members/$MEMBER_B_ID/remove" -H 'Content-Type: application/json' -d '{"reason":"scenario removal"}')" \
  && pass "member B was removed through Workflow API" \
  || fail "member B removal API failed"
if printf '%s' "$remove_response" | jq -e --arg member_b "$MEMBER_B_ID" '.member_allowed != true and (.state.removed_members | index($member_b))' >/dev/null 2>&1; then
  pass "Workflow app persisted member B removal"
else
  fail "member B removal response did not prove persisted removal: $remove_response"
fi
check_member_allowed "member B after removal" "$MEMBER_B_ID" false

denied_body="$(mktemp)"
denied_operation="$(operation_payload "$MEMBER_B_ID" "$DEVICE_B_ID" "denied-op-b" "cmVtb3ZlZC1wYXlsb2FkLWI=" "cmVtb3ZlZC1ub25jZS1i")" || denied_operation=""
denied_status="$(curl -sS -o "$denied_body" -w '%{http_code}' -X POST "$BASE_URL/spaces/$SPACE_ID/members/$MEMBER_B_ID/operations" -H 'Content-Type: application/json' -d "$denied_operation")" \
  || denied_status=""
if [ "$denied_status" = "403" ]; then
  pass "removed member B append was rejected by Workflow API"
else
  fail "removed member B append status=$denied_status body=$(cat "$denied_body")"
fi
rm -f "$denied_body"

if [ -s "$STATE_FILE" ] && jq -e '.schema_version == 1 and .backend == "file" and (.checksum | startswith("sha256:"))' "$STATE_FILE" >/dev/null 2>&1; then
  pass "file state store wrote a schema-versioned checksum snapshot"
else
  fail "file state store did not write expected snapshot: $(cat "$STATE_FILE" 2>/dev/null)"
fi

if grep -Eq 'sealed-collab-payload|proof_digest|private-key|plaintext|nonce' "$STATE_FILE" 2>/dev/null; then
  fail "file state snapshot leaked operation payload or proof material"
else
  pass "file state snapshot contains membership state only"
fi

stop_server
start_server
if wait_for_server "$BASE_URL"; then
  pass "workflow server restarted against existing file state snapshot"
else
  fail "workflow server did not restart against existing file state snapshot; see $SERVER_LOG"
  finish
  exit 1
fi
check_member_allowed "member B after restart/reload" "$MEMBER_B_ID" false
check_member_allowed "member A after restart/reload" "$MEMBER_A_ID" true

finish
