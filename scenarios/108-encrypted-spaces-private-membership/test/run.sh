#!/usr/bin/env bash
# Scenario 108 - Encrypted Spaces Private Membership.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-encrypted-spaces subprocess from data/plugins, and drives
# private membership issue/present/verify APIs through separate HTTP calls.
set -uo pipefail

PLUGIN_NAME="workflow-plugin-encrypted-spaces"
BASE_URL="${BASE_URL:-http://127.0.0.1:18108}"
ENCRYPTED_SPACES_PLUGIN_REF="${ENCRYPTED_SPACES_PLUGIN_REF:-v0.8.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$ENCRYPTED_SPACES_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${ENCRYPTED_SPACES_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$ENCRYPTED_SPACES_PLUGIN_REF" ;;
  esac
fi
SPACE_ID="${SPACE_ID:-space-private-1}"
MEMBER_A_ID="${MEMBER_ID:-participant-a}"
MEMBER_B_ID="${MEMBER_B_ID:-participant-b}"
OPERATION_A_ID="${OPERATION_ID:-private-op-a}"
OPERATION_B_ID="${OPERATION_B_ID:-private-op-b}"
ISSUER_SECRET="${ISSUER_SECRET:-scenario-108-private-membership-secret}"

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

plugin_repo_supports_private_membership() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '.capabilities.stepTypes | index("step.encrypted_space_private_membership_verify")' "$repo/plugin.json" >/dev/null 2>&1 || return 1
  grep -q 'PrivateMembershipVerifyConfig' "$repo/internal/contracts/spaces.proto" 2>/dev/null
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
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_private_membership "$plugin_repo"; then
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

assert_not_contains_secret_material() {
  local label="$1"
  local json="$2"
  if printf '%s' "$json" | grep -Fq "$MEMBER_A_ID" || printf '%s' "$json" | grep -Fq "$MEMBER_B_ID" || printf '%s' "$json" | grep -Fq "$ISSUER_SECRET"; then
    fail "$label leaked plaintext member ID or issuer secret"
  else
    pass "$label did not leak plaintext member IDs or issuer secret"
  fi
}

echo ""
echo "=== Scenario 108 - Encrypted Spaces Private Membership ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if grep -Eq 'participant-a|participant-b|private-op-a|private-op-b' "$CONFIG"; then
  fail "Workflow app config hard-codes default scenario participant or operation IDs"
else
  pass "Workflow app accepts participants and operation IDs from clients"
fi
for step_type in \
  step.encrypted_space_membership_issue \
  step.encrypted_space_membership_present \
  step.encrypted_space_private_membership_verify
do
  if grep -q "type: $step_type" "$CONFIG"; then
    pass "Workflow app config exercises $step_type"
  else
    fail "Workflow app config does not exercise $step_type"
  fi
done
if grep -q 'path: /spaces/{space}/members/{member}/private-credential' "$CONFIG"; then
  pass "Credential issue route is participant-parametric"
else
  fail "Credential issue route does not accept participant IDs from clients"
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
RUNTIME_CONFIG="$DATA_DIR/app.yaml"
if sed "s#__ISSUER_SECRET__#$ISSUER_SECRET#g" "$CONFIG" >"$RUNTIME_CONFIG"; then
  pass "generated Workflow app config with per-run issuer secret"
else
  fail "could not generate runtime Workflow app config"
  finish
  exit 1
fi
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
"$SERVER_BIN" -config "$RUNTIME_CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

if wait_for_server "$BASE_URL"; then
  pass "workflow server started and served /healthz"
else
  fail "workflow server did not become ready; see $SERVER_LOG"
  finish
  exit 1
fi

issue_credential() {
  local slot="$1"
  local label="$2"
  local member="$3"
  local response credential commitment
  response="$(curl -fsS -X POST "$BASE_URL/spaces/$SPACE_ID/members/$member/private-credential" -H 'Content-Type: application/json' -d '{"membership_epoch":2,"expires_at":1893456000}')" \
    && pass "$label obtained private membership credential through Workflow API" \
    || fail "$label credential issue API failed"
  assert_not_contains_secret_material "$label credential response" "$response"
  credential="$(printf '%s' "$response" | jq -c '.credential // empty' 2>/dev/null)"
  if [ -n "$credential" ] && [ "$credential" != "null" ]; then
    pass "$label credential response contained credential envelope"
  else
    fail "$label credential response missing credential: $response"
  fi
  commitment="$(printf '%s' "$credential" | jq -r '.member_commitment // empty' 2>/dev/null)"
  if [ -n "$commitment" ] && [ "$commitment" != "null" ]; then
    pass "$label credential exposed opaque member commitment"
  else
    fail "$label credential missing opaque member commitment: $credential"
  fi
  printf -v "CREDENTIAL_$slot" '%s' "$credential"
  printf -v "COMMITMENT_$slot" '%s' "$commitment"
}

present_and_verify() {
  local slot="$1"
  local label="$2"
  local operation="$3"
  local credential_var="CREDENTIAL_$slot"
  local credential="${!credential_var}"
  local present_request presentation_response presentation verify_request verify_response
  present_request="$(jq -cn --argjson credential "$credential" --arg operation "$operation" '{credential:$credential,operation_id:$operation}')" || present_request=""
  presentation_response="$(curl -fsS -X POST "$BASE_URL/spaces/$SPACE_ID/private-memberships/present" -H 'Content-Type: application/json' -d "$present_request")" \
    && pass "$label presented credential through Workflow API" \
    || fail "$label presentation API failed"
  assert_not_contains_secret_material "$label presentation response" "$presentation_response"
  presentation="$(printf '%s' "$presentation_response" | jq -c '.presentation // empty' 2>/dev/null)"
  if printf '%s' "$presentation" | jq -e --arg operation "$operation" '.operation_id == $operation and .audience == "workflow-scenario-108" and (.proof_digest | startswith("sha256:"))' >/dev/null 2>&1; then
    pass "$label presentation is audience, operation, and proof-digest bound"
  else
    fail "$label presentation missing expected binding: $presentation_response"
  fi
  verify_request="$(jq -cn --argjson presentation "$presentation" --arg operation "$operation" '{presentation:$presentation,operation_id:$operation}')" || verify_request=""
  verify_response="$(curl -fsS -X POST "$BASE_URL/spaces/$SPACE_ID/private-memberships/verify" -H 'Content-Type: application/json' -d "$verify_request")" \
    && pass "$label private membership verification API accepted the presentation" \
    || fail "$label private membership verification API failed"
  assert_not_contains_secret_material "$label verification response" "$verify_response"
  if printf '%s' "$verify_response" | jq -e '.report.accepted == true and .report.domain == "zkgroup.private-membership" and .report.official_zk_equivalent != true and .report.reason == "accepted-local-private-membership-subset" and (.report.member_commitment | startswith("sha256:"))' >/dev/null 2>&1; then
    pass "$label verification report accepted the local private membership subset"
  else
    fail "$label verification report unexpected: $verify_response"
  fi
  printf -v "PRESENTATION_$slot" '%s' "$presentation"
}

CREDENTIAL_A=""
CREDENTIAL_B=""
COMMITMENT_A=""
COMMITMENT_B=""
PRESENTATION_A=""
PRESENTATION_B=""
issue_credential A "member A" "$MEMBER_A_ID"
issue_credential B "member B" "$MEMBER_B_ID"
if [ -n "$COMMITMENT_A" ] && [ -n "$COMMITMENT_B" ] && [ "$COMMITMENT_A" != "$COMMITMENT_B" ]; then
  pass "member A and member B credentials have distinct opaque commitments"
else
  fail "member A and member B credential commitments were not distinct"
fi

present_and_verify A "member A" "$OPERATION_A_ID"
present_and_verify B "member B" "$OPERATION_B_ID"

revoked_request="$(jq -cn --argjson presentation "$PRESENTATION_A" --arg operation "$OPERATION_A_ID" '{presentation:$presentation,operation_id:$operation}')" || revoked_request=""
revoked_body="$(mktemp)"
revoked_status="$(curl -sS -o "$revoked_body" -w '%{http_code}' -X POST "$BASE_URL/spaces/$SPACE_ID/private-memberships/verify-revoked" -H 'Content-Type: application/json' -d "$revoked_request")" \
  || revoked_status=""
if [ "$revoked_status" != "200" ]; then
  pass "revoked member commitment was rejected by Workflow API"
elif jq -e '.report.accepted != true and .report.reason == "member-revoked"' "$revoked_body" >/dev/null 2>&1; then
  pass "revoked member commitment returned a rejected verification report"
else
  fail "revoked member commitment was not rejected: status=$revoked_status body=$(cat "$revoked_body")"
fi
if grep -Fq "$MEMBER_A_ID" "$revoked_body" || grep -Fq "$ISSUER_SECRET" "$revoked_body"; then
  fail "revocation response leaked plaintext member ID or issuer secret"
else
  pass "revocation response did not leak plaintext member ID or issuer secret"
fi
rm -f "$revoked_body"

tampered_request="$(jq -cn --argjson presentation "$PRESENTATION_B" '{presentation:$presentation,operation_id:"wrong-operation"}')" || tampered_request=""
tampered_body="$(mktemp)"
tampered_status="$(curl -sS -o "$tampered_body" -w '%{http_code}' -X POST "$BASE_URL/spaces/$SPACE_ID/private-memberships/verify" -H 'Content-Type: application/json' -d "$tampered_request")" \
  || tampered_status=""
if [ "$tampered_status" != "200" ]; then
  pass "operation-mismatched presentation was rejected by Workflow API"
elif jq -e '.report.accepted != true and .report.reason == "operation-mismatch"' "$tampered_body" >/dev/null 2>&1; then
  pass "operation-mismatched presentation returned a rejected report"
else
  fail "operation-mismatched presentation was not rejected: status=$tampered_status body=$(cat "$tampered_body")"
fi
if grep -Fq "$MEMBER_B_ID" "$tampered_body" || grep -Fq "$ISSUER_SECRET" "$tampered_body"; then
  fail "operation mismatch response leaked plaintext member ID or issuer secret"
else
  pass "operation mismatch response did not leak plaintext member ID or issuer secret"
fi
rm -f "$tampered_body"

finish
