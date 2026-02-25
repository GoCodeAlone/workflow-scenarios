#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 05: SaaS Web Application
# Tests workflow-cloud REST API: auth, orgs, billing, plugins, API keys
# Outputs PASS: or FAIL: lines for each test
#
# API response format notes (workflow-cloud specifics):
#   - POST /auth/register returns bare JSON string (user ID)
#   - POST /auth/login returns bare JSON string (JWT)
#   - All other endpoints return JSON objects/arrays
#   - API keys require a provisioned tenant (tenant_id auto-injected via JWT after provisioning)

NAMESPACE="${NAMESPACE:-default}"
PORT=18085
BASE="http://localhost:${PORT}"

# Use unique email to avoid conflicts with existing users
TIMESTAMP=$(date +%s)
TEST_EMAIL="scenario05-${TIMESTAMP}@test.local"
TEST_PASSWORD="TestPass05!"
TEST_NAME="Scenario05 User"

# JSON bodies written to temp files to avoid shell quoting issues with -d '$(...)'
TMPDIR_TEST=$(mktemp -d)
cleanup() {
    rm -rf "$TMPDIR_TEST"
    kill "$PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Write JSON helper: usage: write_json <file> <content>
write_json() {
    printf '%s' "$2" > "$1"
}

# Port-forward against workflow-cloud (deployed in default namespace)
kubectl port-forward svc/workflow-cloud "${PORT}:8080" -n "${NAMESPACE}" &
PF_PID=$!
sleep 3

# ─── Test 1: Health check ───────────────────────────────────────────────────
HEALTH=$(curl -sf "${BASE}/healthz" 2>/dev/null || echo "")
if echo "$HEALTH" | grep -q "ok"; then
    echo "PASS: Health check returns ok"
else
    echo "FAIL: Health check failed: ${HEALTH}"
fi

# ─── Test 2: UI serves HTML ─────────────────────────────────────────────────
# Note: cloud-ui plugin must be loaded for / to serve the React SPA.
# Returns 404 if the plugin is not deployed; mark as FAIL since UI is a key feature.
UI_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE}/" 2>/dev/null)
if [ "$UI_CODE" = "200" ]; then
    echo "PASS: Root path returns 200 (cloud-ui serving React SPA)"
elif [ "$UI_CODE" = "404" ]; then
    echo "FAIL: Root path returned 404 (cloud-ui plugin not loaded)"
else
    echo "FAIL: Root path returned ${UI_CODE} (expected 200)"
fi

# ─── Test 3: Unauthorized profile returns 401 ────────────────────────────────
UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE}/api/v1/auth/profile" 2>/dev/null)
if [ "$UNAUTH_CODE" = "401" ]; then
    echo "PASS: Unauthenticated profile request returns 401"
else
    echo "FAIL: Unauthenticated profile returned ${UNAUTH_CODE} (expected 401)"
fi

# ─── Test 4: Invalid login returns error ─────────────────────────────────────
write_json "${TMPDIR_TEST}/bad_login.json" '{"email":"nobody@test.local","password":"wrongpassword"}'
INVALID_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "@${TMPDIR_TEST}/bad_login.json" 2>/dev/null)
if [ "$INVALID_CODE" = "401" ] || [ "$INVALID_CODE" = "400" ]; then
    echo "PASS: Invalid login returns error (HTTP ${INVALID_CODE})"
else
    echo "FAIL: Invalid login returned ${INVALID_CODE} (expected 401 or 400)"
fi

# ─── Test 5: Register new user ───────────────────────────────────────────────
cat > "${TMPDIR_TEST}/register.json" <<ENDJSON
{"email":"${TEST_EMAIL}","password":"${TEST_PASSWORD}","name":"${TEST_NAME}"}
ENDJSON
REG_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE}/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -d "@${TMPDIR_TEST}/register.json" 2>/dev/null)
if [ "$REG_CODE" = "201" ] || [ "$REG_CODE" = "200" ]; then
    echo "PASS: User registration returns success (HTTP ${REG_CODE})"
else
    echo "FAIL: User registration returned ${REG_CODE} (expected 201)"
fi

# ─── Test 6: Login and get JWT ───────────────────────────────────────────────
cat > "${TMPDIR_TEST}/login.json" <<ENDJSON
{"email":"${TEST_EMAIL}","password":"${TEST_PASSWORD}"}
ENDJSON
LOGIN_RESP=$(curl -s -X POST "${BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "@${TMPDIR_TEST}/login.json" 2>/dev/null || echo "")
# API returns JWT as a bare JSON string (e.g. "eyJ..."), strip surrounding quotes
TOKEN=$(echo "$LOGIN_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin))" 2>/dev/null || echo "")

if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && echo "$TOKEN" | grep -q "^eyJ"; then
    echo "PASS: Login returns JWT token"
else
    echo "FAIL: Login failed, no JWT token. Response: ${LOGIN_RESP}"
fi

# ─── Test 7: Get user profile with JWT ──────────────────────────────────────
if [ -n "$TOKEN" ] && echo "$TOKEN" | grep -q "^eyJ"; then
    PROFILE=$(curl -s "${BASE}/api/v1/auth/profile" \
        -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "")
    if echo "$PROFILE" | grep -q "${TEST_EMAIL}"; then
        echo "PASS: Profile returns user data with correct email"
    else
        echo "FAIL: Profile request failed or wrong data: ${PROFILE}"
    fi
else
    echo "FAIL: Cannot test profile (no JWT from login)"
fi

# ─── Test 8: Create an org ───────────────────────────────────────────────────
ORG_ID=""
if [ -n "$TOKEN" ] && echo "$TOKEN" | grep -q "^eyJ"; then
    cat > "${TMPDIR_TEST}/org.json" <<ENDJSON
{"name":"TestOrg-${TIMESTAMP}","slug":"testorg-${TIMESTAMP}"}
ENDJSON
    ORG_RESP=$(curl -s -X POST "${BASE}/api/v1/orgs" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "@${TMPDIR_TEST}/org.json" 2>/dev/null || echo "")
    ORG_ID=$(echo "$ORG_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
    if [ -n "$ORG_ID" ] && [ "$ORG_ID" != "null" ]; then
        echo "PASS: Create org returns org ID"
    else
        echo "FAIL: Create org failed: ${ORG_RESP}"
    fi
else
    echo "FAIL: Cannot test org creation (no token)"
fi

# ─── Test 9: List orgs ───────────────────────────────────────────────────────
if [ -n "$TOKEN" ] && echo "$TOKEN" | grep -q "^eyJ"; then
    ORGS=$(curl -s "${BASE}/api/v1/orgs" \
        -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "")
    if echo "$ORGS" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if isinstance(d, list) and len(d) > 0 else 1)" 2>/dev/null; then
        echo "PASS: List orgs returns non-empty array"
    else
        echo "FAIL: List orgs failed or empty: ${ORGS}"
    fi
else
    echo "FAIL: Cannot test list orgs (no token)"
fi

# ─── Test 10: Get org members ────────────────────────────────────────────────
if [ -n "$TOKEN" ] && echo "$TOKEN" | grep -q "^eyJ" && [ -n "$ORG_ID" ]; then
    MEMBERS=$(curl -s "${BASE}/api/v1/orgs/${ORG_ID}/members" \
        -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "")
    if echo "$MEMBERS" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if isinstance(d, list) and len(d) > 0 else 1)" 2>/dev/null; then
        echo "PASS: Get org members returns member list"
    else
        echo "FAIL: Get org members failed or empty: ${MEMBERS}"
    fi
else
    echo "FAIL: Cannot test org members (no org ID or token)"
fi

# ─── Test 11: Search plugins ─────────────────────────────────────────────────
PLUGINS=$(curl -s "${BASE}/api/v1/plugins" 2>/dev/null || echo "")
if echo "$PLUGINS" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if isinstance(d, (list, dict)) else 1)" 2>/dev/null; then
    echo "PASS: Plugin search returns valid JSON response"
else
    echo "FAIL: Plugin search failed: ${PLUGINS}"
fi

# ─── Test 12-14: API key lifecycle (requires provisioned tenant) ─────────────
# Provision a tenant for this user so the auth step injects auth_tenant_id into JWT context
TENANT_ID=""
if [ -n "$TOKEN" ] && echo "$TOKEN" | grep -q "^eyJ"; then
    cat > "${TMPDIR_TEST}/tenant.json" <<ENDJSON
{"email":"${TEST_EMAIL}","company_name":"TestCo-${TIMESTAMP}","plan":"free"}
ENDJSON
    TENANT_RESP=$(curl -s -X POST "${BASE}/api/v1/tenants" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "@${TMPDIR_TEST}/tenant.json" 2>/dev/null || echo "")
    TENANT_ID=$(echo "$TENANT_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tenant_id',''))" 2>/dev/null || echo "")
fi

# ─── Test 12: Create API key ─────────────────────────────────────────────────
APIKEY_ID=""
if [ -n "$TOKEN" ] && echo "$TOKEN" | grep -q "^eyJ" && [ -n "$TENANT_ID" ]; then
    cat > "${TMPDIR_TEST}/apikey.json" <<ENDJSON
{"name":"test-key-${TIMESTAMP}","tenant_id":"${TENANT_ID}"}
ENDJSON
    APIKEY_RESP=$(curl -s -X POST "${BASE}/api/v1/apikeys" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "@${TMPDIR_TEST}/apikey.json" 2>/dev/null || echo "")
    APIKEY_ID=$(echo "$APIKEY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
    if [ -n "$APIKEY_ID" ] && [ "$APIKEY_ID" != "null" ]; then
        echo "PASS: Create API key returns key ID"
    else
        echo "FAIL: Create API key failed: ${APIKEY_RESP}"
    fi
else
    echo "FAIL: Cannot test API key creation (no token or tenant)"
fi

# ─── Test 13: List API keys ──────────────────────────────────────────────────
if [ -n "$TOKEN" ] && echo "$TOKEN" | grep -q "^eyJ" && [ -n "$TENANT_ID" ]; then
    KEYS=$(curl -s "${BASE}/api/v1/apikeys" \
        -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "")
    if echo "$KEYS" | python3 -c "import json,sys; d=json.load(sys.stdin); keys=d.get('keys',d) if isinstance(d,dict) else d; exit(0 if isinstance(keys, list) else 1)" 2>/dev/null; then
        echo "PASS: List API keys returns array"
    else
        echo "FAIL: List API keys failed: ${KEYS}"
    fi
else
    echo "FAIL: Cannot test list API keys (no token or tenant)"
fi

# ─── Test 14: Revoke API key ─────────────────────────────────────────────────
if [ -n "$TOKEN" ] && echo "$TOKEN" | grep -q "^eyJ" && [ -n "$TENANT_ID" ] && [ -n "$APIKEY_ID" ]; then
    DEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "${BASE}/api/v1/apikeys/${APIKEY_ID}" \
        -H "Authorization: Bearer ${TOKEN}" 2>/dev/null)
    if [ "$DEL_CODE" = "200" ] || [ "$DEL_CODE" = "204" ] || [ "$DEL_CODE" = "202" ]; then
        echo "PASS: Revoke API key returns success (HTTP ${DEL_CODE})"
    else
        echo "FAIL: Revoke API key returned ${DEL_CODE} (expected 200/204)"
    fi
else
    echo "FAIL: Cannot test API key revocation (no key ID, token, or tenant)"
fi
