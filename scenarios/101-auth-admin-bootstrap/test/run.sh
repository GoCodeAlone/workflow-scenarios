#!/usr/bin/env bash
# Scenario 101 — Auth Admin Bootstrap test runner (deterministic curl smoke).
# Assumes seed.sh has brought the stack up at $BASE_URL.
#
# Proves the durable first-run bootstrap flow end-to-end against the live
# engine + workflow-plugin-auth (gRPC) + Postgres stack:
#   status(open) → bad code 403 → good code 200+token → gate 401/200 →
#   credential exists → status(closed) → re-redeem 403 bootstrap_closed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
WORKFLOW_REPO="${WORKFLOW_REPO:-$(cd "$SCENARIOS_ROOT/.." && pwd)/workflow}"
PLUGIN_AUTH_REPO="${PLUGIN_AUTH_REPO:-$(cd "$SCENARIOS_ROOT/.." && pwd)/workflow-plugin-auth}"
BASE_URL="${BASE_URL:-http://127.0.0.1:18101}"
CODE="${AUTH_BOOTSTRAP_CODE:-scenario-101-bootstrap-code-do-not-use-in-prod}"
PGEXEC=(docker compose -f "$SCENARIO_DIR/docker-compose.yml" exec -T postgres psql -U scenario101 -d scenario101 -tAc)

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""; echo "=== Scenario 101 — Auth Admin Bootstrap ==="; echo ""

# --- Phase 1: config validation (with plugin manifest) -----------------------
WFCTL=""
for c in "$(which wfctl 2>/dev/null)" "$WORKFLOW_REPO/wfctl" "$WORKFLOW_REPO/bin/wfctl"; do
    [ -n "$c" ] && [ -x "$c" ] && { WFCTL="$c"; break; }
done
[ -z "$WFCTL" ] && { (cd "$WORKFLOW_REPO" && GOWORK=off go build -o wfctl ./cmd/wfctl) && WFCTL="$WORKFLOW_REPO/wfctl"; }
if "$WFCTL" validate --plugin-manifest "$PLUGIN_AUTH_REPO/plugin.json" "$SCENARIO_DIR/config/app.yaml" >/dev/null 2>&1; then
    pass "wfctl validate accepts app.yaml (with auth plugin manifest)"
else
    fail "wfctl validate rejected app.yaml"
fi

# --- Phase 2: live smoke ------------------------------------------------------
curl -fs "$BASE_URL/healthz" >/dev/null 2>&1 && pass "GET /healthz 200" || fail "GET /healthz (is seed.sh up?)"

# 1. fresh DB → bootstrap open
st=$(curl -fs "$BASE_URL/admin/bootstrap/status" 2>/dev/null)
echo "$st" | grep -q '"open":true' && pass "status open on fresh DB" || fail "status not open (got: $st)"

# 2. wrong code → 403 invalid_code
body=$(curl -s -o /tmp/s101-bad.json -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d '{"code":"wrong-code"}' "$BASE_URL/admin/bootstrap/redeem")
{ [ "$body" = "403" ] && grep -q 'invalid_code' /tmp/s101-bad.json; } \
    && pass "wrong code → 403 invalid_code" || fail "wrong code got $body $(cat /tmp/s101-bad.json)"

# 3. correct code → 200 + bearer token; super-admin row created
code=$(curl -s -o /tmp/s101-ok.json -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "{\"code\":\"$CODE\"}" "$BASE_URL/admin/bootstrap/redeem")
TOKEN=$(jq -r '.token // empty' /tmp/s101-ok.json 2>/dev/null)
{ [ "$code" = "200" ] && [ -n "$TOKEN" ]; } \
    && pass "correct code → 200 + bearer token" || fail "redeem got $code $(cat /tmp/s101-ok.json)"
ucount=$("${PGEXEC[@]}" "SELECT count(*) FROM users;" 2>/dev/null | tr -d '[:space:]')
[ "$ucount" = "1" ] && pass "super-admin user row created" || fail "users count=$ucount (want 1)"

# 4. server-side gate: authed passkey/register/begin 200; unauth 401
unauth=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/admin/credentials/passkey/register/begin")
[ "$unauth" = "401" ] && pass "unauth passkey/register/begin → 401 (auth_validate gate)" || fail "unauth got $unauth (want 401)"
authed=$(curl -s -o /tmp/s101-pk.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/admin/credentials/passkey/register/begin")
[ "$authed" = "200" ] && pass "authed passkey/register/begin → 200 challenge" || fail "authed got $authed $(cat /tmp/s101-pk.json)"

# 5. simulate enrolment (deterministic path): insert a passkey credential row,
#    then bootstrap must be CLOSED (the full WebAuthn ceremony is covered by Playwright).
"${PGEXEC[@]}" "INSERT INTO credentials(user_email,kind,external_id,device_name) SELECT email,'passkey','smoke-cred-1','smoke' FROM users LIMIT 1;" >/dev/null 2>&1
st2=$(curl -fs "$BASE_URL/admin/bootstrap/status" 2>/dev/null)
echo "$st2" | grep -q '"open":false' && pass "status closed after credential enrolled" || fail "status not closed (got: $st2)"
rc=$(curl -s -o /tmp/s101-closed.json -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "{\"code\":\"$CODE\"}" "$BASE_URL/admin/bootstrap/redeem")
{ [ "$rc" = "403" ] && grep -q 'bootstrap_closed' /tmp/s101-closed.json; } \
    && pass "re-redeem after close → 403 bootstrap_closed (V-B4)" || fail "re-redeem got $rc $(cat /tmp/s101-closed.json)"

echo ""; echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
