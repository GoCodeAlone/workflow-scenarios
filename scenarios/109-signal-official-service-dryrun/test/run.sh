#!/usr/bin/env bash
# Scenario 109 - Signal Official Service Dry-Run Boundary.
#
# Demonstration-fidelity: this starts the real Workflow server, loads the real
# workflow-plugin-signal subprocess from data/plugins, and drives service
# approval/submit routes through separate HTTP calls.
set -uo pipefail

PLUGIN_NAME="workflow-plugin-signal"
BASE_URL="${BASE_URL:-http://127.0.0.1:18109}"
SIGNAL_PLUGIN_REF="${SIGNAL_PLUGIN_REF:-v0.14.0}"
if [ -z "${PLUGIN_VERSION:-}" ]; then
  case "$SIGNAL_PLUGIN_REF" in
    v[0-9]*) PLUGIN_VERSION="${SIGNAL_PLUGIN_REF#v}" ;;
    *) PLUGIN_VERSION="$SIGNAL_PLUGIN_REF" ;;
  esac
fi
ACCOUNT_REF="${ACCOUNT_REF:-account://tenant-a}"
SECOND_ACCOUNT_REF="${SECOND_ACCOUNT_REF:-account://tenant-b}"
RECIPIENT_REF="${RECIPIENT_REF:-phone:+15551234567}"
PAYLOAD_REF="${PAYLOAD_REF:-plaintext service payload}"
OPERATION="${OPERATION:-send}"
REQUEST_ID="${REQUEST_ID:-scenario-109-request}"
SANDBOX_ENDPOINT="${SANDBOX_ENDPOINT:-https://signal-sandbox.invalid}"
RAW_CREDENTIAL_REF="${RAW_CREDENTIAL_REF:-credential-raw-secret}"

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

plugin_repo_supports_dryrun_contract() {
  local repo="$1"
  [ -f "$repo/plugin.json" ] || return 1
  jq -e '.capabilities.stepTypes | index("step.signal_service_live_submit")' "$repo/plugin.json" >/dev/null 2>&1 || return 1
  grep -q 'approval_ready = 14' "$repo/internal/contracts/signal.proto" 2>/dev/null || return 1
  grep -q 'dry_run_accepted' "$repo/internal/service_transport.go" 2>/dev/null
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
  if [ -z "$plugin_repo" ] || ! plugin_repo_supports_dryrun_contract "$plugin_repo"; then
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

post_json() {
  local path="$1"
  local body="$2"
  curl -fsS -X POST "$BASE_URL$path" -H 'Content-Type: application/json' -d "$body"
}

complete_approval() {
  local account="$1"
  local dry_run="$2"
  jq -cn \
    --arg account "$account" \
    --argjson dry_run "$dry_run" \
    '{
      operator_approval_id: "approval://signal-live/operator",
      operator_approval_scope: "signal-live",
      operator_approval_expires_unix: 1893456000,
      service_authorization_type: "official-test-endpoint",
      service_authorization_evidence_ref: "evidence://signal/service-auth",
      service_authorization_expires_unix: 1893456000,
      account_ref: $account,
      account_consent_evidence_ref: "consent://signal/account-owner",
      account_consent_expires_unix: 1893456000,
      custody_backend: "workflow-host",
      custody_key_handle_ref: "kms://signal/dryrun/device-1",
      custody_backup_ref: "backup://signal/dryrun/device-1",
      custody_rotation_ref: "rotation://signal/dryrun/device-1",
      abuse_idempotency_required: true,
      abuse_rate_limit_ref: "policy://signal/rate-limit",
      abuse_recipient_allowlist_ref: "policy://signal/recipients",
      abuse_challenge_policy_ref: "policy://signal/challenge",
      abuse_backoff_policy_ref: "policy://signal/backoff",
      egress_endpoint_allowlist: ["https://signal-sandbox.invalid"],
      egress_tls_policy_ref: "policy://signal/tls",
      egress_dry_run: $dry_run,
      audit_ref: "audit://signal/dryrun",
      audit_retention_ref: "policy://signal/audit-retention",
      audit_redaction_ref: "policy://signal/audit-redaction"
    }'
}

submit_body() {
  local mode="$1"
  local account="$2"
  local request_suffix="$3"
  local approval_json="${4:-null}"
  local sandbox_endpoint="${5:-}"
  local challenge_ref="${6:-}"
  jq -cn \
    --arg mode "$mode" \
    --arg account "$account" \
    --arg operation "$OPERATION" \
    --arg request_id "$REQUEST_ID-$request_suffix" \
    --arg recipient "$RECIPIENT_REF" \
    --arg payload "$PAYLOAD_REF" \
    --arg credential "$RAW_CREDENTIAL_REF" \
    --arg sandbox_endpoint "$sandbox_endpoint" \
    --arg challenge_ref "$challenge_ref" \
    --argjson approval "$approval_json" \
    '{
      mode: $mode,
      operation: $operation,
      account_ref: $account,
      idempotency_key: $request_id,
      recipient_ref: $recipient,
      payload_ref: $payload,
      credential_ref: $credential,
      sandbox_endpoint: (if $sandbox_endpoint == "" then null else $sandbox_endpoint end),
      challenge_ref: (if $challenge_ref == "" then null else $challenge_ref end),
      approval: $approval
    }'
}

assert_no_raw_service_data() {
  local label="$1"
  local json="$2"
  for raw in "$RECIPIENT_REF" "$PAYLOAD_REF" "$RAW_CREDENTIAL_REF"; do
    if [ -n "$raw" ] && printf '%s' "$json" | grep -Fq "$raw"; then
      fail "$label leaked raw service input $raw"
      return
    fi
  done
  pass "$label did not leak raw recipient, payload, or credential refs"
}

assert_raw_credential_redacted() {
  local label="$1"
  local json="$2"
  if printf '%s' "$RAW_CREDENTIAL_REF" | grep -Fq '://'; then
    pass "$label used a host-managed credential reference"
    return
  fi
  if printf '%s' "$json" | jq -e '.credential_ref == "redacted" and .secret_refs.credential == "redacted"' >/dev/null 2>&1; then
    pass "$label redacted raw credential material"
  else
    fail "$label did not redact raw credential material: $json"
  fi
}

assert_status() {
  local label="$1"
  local json="$2"
  local want="$3"
  if printf '%s' "$json" | jq -e --arg want "$want" '.status == $want' >/dev/null 2>&1; then
    pass "$label status is $want"
  else
    fail "$label status unexpected: $json"
  fi
}

echo ""
echo "=== Scenario 109 - Signal Official Service Dry-Run Boundary ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
pipeline_block="$(awk '/^pipelines:/ {capture=1} capture {print}' "$CONFIG")"
for step_type in step.signal_service_approval_validate step.signal_service_live_submit; do
  if grep -q "type: $step_type" "$CONFIG"; then
    pass "Workflow app config exercises $step_type"
  else
    fail "Workflow app config does not exercise $step_type"
  fi
done
if printf '%s' "$pipeline_block" | grep -Eq 'phone:\+15551234567|plaintext service payload|scenario-109-request'; then
  fail "Workflow app pipelines hard-code scenario request values"
else
  pass "Workflow app pipelines accept service request values from clients"
fi
if grep -q 'path: /service/submit' "$CONFIG" && grep -q 'path: /service/approval/validate' "$CONFIG"; then
  pass "Workflow app exposes approval and submit HTTP routes"
else
  fail "Workflow app missing approval or submit HTTP routes"
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

incomplete_validation="$(post_json /service/approval/validate '{"mode":"live","requested_actions":["send"],"approval":{"operator_approval_id":"approval://partial"}}')" \
  && pass "incomplete approval validation API returned a report" \
  || fail "incomplete approval validation API failed"
if printf '%s' "$incomplete_validation" | jq -e '.live_transport_allowed == false and (.denied_reasons | length > 0)' >/dev/null 2>&1; then
  pass "incomplete approval validation denied live readiness"
else
  fail "incomplete approval validation report unexpected: $incomplete_validation"
fi

approval_no_dryrun="$(complete_approval "$ACCOUNT_REF" false)"
approval_dryrun="$(complete_approval "$ACCOUNT_REF" true)"

complete_validation="$(post_json /service/approval/validate "$(jq -cn --argjson approval "$approval_no_dryrun" '{mode:"live",requested_actions:["send"],approval:$approval}')")" \
  && pass "complete approval validation API returned a report" \
  || fail "complete approval validation API failed"
if printf '%s' "$complete_validation" | jq -e '.live_transport_allowed == true and (.denied_reasons | length == 0)' >/dev/null 2>&1; then
  pass "complete approval validation reports live readiness metadata"
else
  fail "complete approval validation report unexpected: $complete_validation"
fi

live_incomplete="$(post_json /service/submit "$(submit_body live "$ACCOUNT_REF" live-incomplete null)")" \
  && pass "live submit with incomplete approval returned denial output" \
  || fail "live submit with incomplete approval failed"
assert_status "live incomplete approval" "$live_incomplete" denied
if printf '%s' "$live_incomplete" | jq -e '.approval_ready == false and .live_egress_attempted == false and (.denied_reasons | length > 0)' >/dev/null 2>&1; then
  pass "live incomplete approval denied without egress"
else
  fail "live incomplete approval output unexpected: $live_incomplete"
fi
assert_no_raw_service_data "live incomplete approval output" "$live_incomplete"

live_no_dryrun="$(post_json /service/submit "$(submit_body live "$ACCOUNT_REF" live-no-dryrun "$approval_no_dryrun")")" \
  && pass "live submit with complete no-dry-run approval returned denial output" \
  || fail "live submit with complete no-dry-run approval failed"
assert_status "live complete approval without dry-run" "$live_no_dryrun" denied
if printf '%s' "$live_no_dryrun" | jq -e '.approval_ready == true and .egress_dry_run == false and .live_egress_attempted == false and (.denied_reasons | index("egress_dry_run_required"))' >/dev/null 2>&1; then
  pass "live complete approval without dry-run denied for dry-run requirement"
else
  fail "live complete approval without dry-run output unexpected: $live_no_dryrun"
fi
assert_no_raw_service_data "live no-dry-run output" "$live_no_dryrun"

live_dryrun="$(post_json /service/submit "$(submit_body live "$ACCOUNT_REF" live-dryrun "$approval_dryrun")")" \
  && pass "live submit with complete dry-run approval returned output" \
  || fail "live submit with complete dry-run approval failed"
assert_status "live complete dry-run approval" "$live_dryrun" dry_run_accepted
if printf '%s' "$live_dryrun" | jq -e '.approval_ready == true and .egress_dry_run == true and .live_egress_attempted == false and (.denied_reasons | length == 0)' >/dev/null 2>&1; then
  pass "live complete dry-run approval accepted without egress"
else
  fail "live complete dry-run output unexpected: $live_dryrun"
fi
assert_no_raw_service_data "live dry-run output" "$live_dryrun"

fake_submit="$(post_json /service/submit "$(submit_body fake "$SECOND_ACCOUNT_REF" fake-send null)")" \
  && pass "fake service submit API returned output" \
  || fail "fake service submit API failed"
assert_status "fake service submit" "$fake_submit" accepted
if printf '%s' "$fake_submit" | jq -e '.transport_mode == "fake" and .live_egress_attempted == false' >/dev/null 2>&1; then
  pass "fake service submit used fake transport without live egress"
else
  fail "fake service submit output unexpected: $fake_submit"
fi
assert_no_raw_service_data "fake service submit output" "$fake_submit"
assert_raw_credential_redacted "fake service submit output" "$fake_submit"

sandbox_submit="$(post_json /service/submit "$(submit_body sandbox "$SECOND_ACCOUNT_REF" sandbox-send null "$SANDBOX_ENDPOINT")")" \
  && pass "sandbox service submit API returned output" \
  || fail "sandbox service submit API failed"
assert_status "sandbox service submit" "$sandbox_submit" accepted
if printf '%s' "$sandbox_submit" | jq -e '.transport_mode == "sandbox" and .live_egress_attempted == false' >/dev/null 2>&1; then
  pass "sandbox service submit used sandbox transport without live egress"
else
  fail "sandbox service submit output unexpected: $sandbox_submit"
fi
assert_no_raw_service_data "sandbox service submit output" "$sandbox_submit"
assert_raw_credential_redacted "sandbox service submit output" "$sandbox_submit"

challenge_ref="challenge://scenario-109/send"
challenge_submit="$(post_json /service/submit "$(submit_body fake "$SECOND_ACCOUNT_REF" challenge null "" "$challenge_ref")")" \
  && pass "challenge service submit API returned output" \
  || fail "challenge service submit API failed"
assert_status "challenge service submit" "$challenge_submit" challenge_required
if printf '%s' "$challenge_submit" | jq -e --arg challenge "$challenge_ref" '.challenge_ref == $challenge and .live_egress_attempted == false' >/dev/null 2>&1; then
  pass "challenge service submit preserved challenge ref without live egress"
else
  fail "challenge service submit output unexpected: $challenge_submit"
fi
assert_no_raw_service_data "challenge service submit output" "$challenge_submit"
assert_raw_credential_redacted "challenge service submit output" "$challenge_submit"

finish
