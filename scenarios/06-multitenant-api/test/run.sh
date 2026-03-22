#!/usr/bin/env bash
# Test script for Scenario 06: Multi-Tenant API
# Tests workflow-cloud's multitenant endpoints.
# workflow-cloud runs in the default namespace; no pod deploy needed here.
# The test harness port-forwards via WORKFLOW_CLOUD_PORT (default 8082).
set -euo pipefail

PORT="${WORKFLOW_CLOUD_PORT:-8082}"
BASE="http://localhost:${PORT}"

# Port-forward workflow-cloud if not already available
_PF_PID=""
if ! curl -sf "${BASE}/healthz" >/dev/null 2>&1; then
    kubectl port-forward svc/workflow-cloud "${PORT}:8080" -n default >/tmp/pf-scenario06.log 2>&1 &
    _PF_PID=$!
    sleep 4
fi

cleanup() {
    [ -n "$_PF_PID" ] && kill "$_PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

TS=$(date +%s)
EMAIL1="s06u1-${TS}@example.com"
EMAIL2="s06u2-${TS}@example.com"
PASS="TestPass123x"

# ── Test 1: Health check ──────────────────────────────────────────────────────
HEALTH=$(curl -sf "${BASE}/healthz" 2>/dev/null || echo "")
if echo "$HEALTH" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('status')=='ok'" 2>/dev/null; then
    echo "PASS: Health check returns ok"
else
    echo "FAIL: Health check failed: $HEALTH"
fi

# ── Test 2: Register user 1 ───────────────────────────────────────────────────
REG1_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE}/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    --data "{\"email\":\"${EMAIL1}\",\"password\":\"${PASS}\",\"name\":\"User One\"}")
if [ "$REG1_CODE" = "201" ]; then
    echo "PASS: Register user 1 returns 201"
else
    echo "FAIL: Register user 1 returned $REG1_CODE (expected 201)"
fi

# ── Test 3: Register user 2 ───────────────────────────────────────────────────
REG2_RESP=$(curl -s -X POST "${BASE}/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    --data "{\"email\":\"${EMAIL2}\",\"password\":\"${PASS}\",\"name\":\"User Two\"}" 2>/dev/null || echo "")
USER2_TENANT_ID=$(echo "$REG2_RESP" | python3 -c "import json,sys; v=json.load(sys.stdin); print(v if isinstance(v,str) else v.get('tenant_id',''))" 2>/dev/null || echo "")
if [ -n "$USER2_TENANT_ID" ] && [ "$USER2_TENANT_ID" != "null" ]; then
    echo "PASS: Register user 2 returns user ID"
else
    echo "FAIL: Register user 2 did not return user ID: $REG2_RESP"
fi

# ── Test 4: Login user 1 ──────────────────────────────────────────────────────
LOGIN1=$(curl -s -X POST "${BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    --data "{\"email\":\"${EMAIL1}\",\"password\":\"${PASS}\"}" 2>/dev/null || echo "")
TOKEN1=$(echo "$LOGIN1" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d if isinstance(d,str) else d.get('token',''))" 2>/dev/null || echo "")
if [ -n "$TOKEN1" ] && [ "$TOKEN1" != "null" ]; then
    echo "PASS: Login user 1 returns JWT token"
else
    echo "FAIL: Login user 1 failed: $LOGIN1"
fi

# ── Test 5: Login user 2 ──────────────────────────────────────────────────────
LOGIN2=$(curl -s -X POST "${BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    --data "{\"email\":\"${EMAIL2}\",\"password\":\"${PASS}\"}" 2>/dev/null || echo "")
TOKEN2=$(echo "$LOGIN2" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d if isinstance(d,str) else d.get('token',''))" 2>/dev/null || echo "")
if [ -n "$TOKEN2" ] && [ "$TOKEN2" != "null" ]; then
    echo "PASS: Login user 2 returns JWT token"
else
    echo "FAIL: Login user 2 failed: $LOGIN2"
fi

# ── Test 6: Get profile (authenticated) ──────────────────────────────────────
if [ -n "$TOKEN1" ] && [ "$TOKEN1" != "null" ]; then
    PROFILE=$(curl -s "${BASE}/api/v1/auth/profile" \
        -H "Authorization: Bearer ${TOKEN1}" 2>/dev/null || echo "")
    if echo "$PROFILE" | python3 -c "import json,sys; d=json.load(sys.stdin); assert '${EMAIL1}' in str(d)" 2>/dev/null; then
        echo "PASS: Profile returns user data for authenticated user"
    else
        echo "FAIL: Profile returned unexpected data: $PROFILE"
    fi
else
    echo "FAIL: Cannot test profile (no token)"
fi

# ── Test 7: Profile without token returns 401 ────────────────────────────────
UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE}/api/v1/auth/profile")
if [ "$UNAUTH_CODE" = "401" ]; then
    echo "PASS: Profile without token returns 401"
else
    echo "FAIL: Profile without token returned $UNAUTH_CODE (expected 401)"
fi

# ── Test 8: Login with wrong password returns 401 ────────────────────────────
BAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    --data "{\"email\":\"${EMAIL1}\",\"password\":\"wrongpassword\"}")
if [ "$BAD_CODE" = "401" ]; then
    echo "PASS: Wrong password returns 401"
else
    echo "FAIL: Wrong password returned $BAD_CODE (expected 401)"
fi

# ── Test 9: Create org ────────────────────────────────────────────────────────
ORG_RESP=""
ORG_ID=""
if [ -n "$TOKEN1" ] && [ "$TOKEN1" != "null" ]; then
    ORG_RESP=$(curl -s -X POST "${BASE}/api/v1/orgs" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${TOKEN1}" \
        --data "{\"name\":\"TestOrg-${TS}\"}" 2>/dev/null || echo "")
    ORG_ID=$(echo "$ORG_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
    if [ -n "$ORG_ID" ] && [ "$ORG_ID" != "null" ]; then
        echo "PASS: Create org returns org ID"
    else
        echo "FAIL: Create org failed: $ORG_RESP"
    fi
else
    echo "FAIL: Cannot test create org (no token)"
fi

# ── Test 10: List orgs for user 1 ────────────────────────────────────────────
if [ -n "$TOKEN1" ] && [ "$TOKEN1" != "null" ]; then
    ORGS=$(curl -s "${BASE}/api/v1/orgs" \
        -H "Authorization: Bearer ${TOKEN1}" 2>/dev/null || echo "")
    if echo "$ORGS" | python3 -c "import json,sys; orgs=json.load(sys.stdin); assert len(orgs)>=1" 2>/dev/null; then
        echo "PASS: List orgs returns at least one org for user 1"
    else
        echo "FAIL: List orgs returned unexpected data: $ORGS"
    fi
else
    echo "FAIL: Cannot test list orgs (no token)"
fi

# ── Test 11: Invite user 2 to org ────────────────────────────────────────────
INVITE_CODE=""
if [ -n "$TOKEN1" ] && [ -n "$ORG_ID" ]; then
    INVITE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE}/api/v1/orgs/${ORG_ID}/invitations" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${TOKEN1}" \
        --data "{\"email\":\"${EMAIL2}\",\"role\":\"member\"}")
    if [ "$INVITE_CODE" = "201" ]; then
        echo "PASS: Invite user 2 to org returns 201"
    else
        echo "FAIL: Invite user 2 returned $INVITE_CODE (expected 201)"
    fi
else
    echo "FAIL: Cannot test invite (missing token or org ID)"
fi

# ── Test 12: List org members (user 1 is owner) ──────────────────────────────
if [ -n "$TOKEN1" ] && [ -n "$ORG_ID" ]; then
    MEMBERS=$(curl -s "${BASE}/api/v1/orgs/${ORG_ID}/members" \
        -H "Authorization: Bearer ${TOKEN1}" 2>/dev/null || echo "")
    if echo "$MEMBERS" | python3 -c "import json,sys; m=json.load(sys.stdin); assert any(u.get('role')=='owner' for u in m)" 2>/dev/null; then
        echo "PASS: List org members returns owner"
    else
        echo "FAIL: List org members returned unexpected data: $MEMBERS"
    fi
else
    echo "FAIL: Cannot test list members (missing token or org ID)"
fi

# ── Test 13: Provision tenant for user 1 ─────────────────────────────────────
# Registration already creates a tenant; provisioning a second tenant for the
# same email violates the unique constraint. Use a distinct email here.
TENANT_RESP=""
TENANT_EMAIL="s06tenant-${TS}@example.com"
if [ -n "$TOKEN1" ]; then
    TENANT_RESP=$(curl -s -X POST "${BASE}/api/v1/tenants" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${TOKEN1}" \
        --data "{\"email\":\"${TENANT_EMAIL}\",\"company_name\":\"TestCo-${TS}\"}" 2>/dev/null || echo "")
    TENANT_ID=$(echo "$TENANT_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tenant_id',''))" 2>/dev/null || echo "")
    if [ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "null" ]; then
        echo "PASS: Provision tenant returns tenant ID"
    else
        echo "FAIL: Provision tenant failed: $TENANT_RESP"
    fi
else
    echo "FAIL: Cannot test tenant provision (no token)"
fi

# Re-login to get token with tenant_id claim
TOKEN1=$(curl -s -X POST "${BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    --data "{\"email\":\"${EMAIL1}\",\"password\":\"${PASS}\"}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d if isinstance(d,str) else d.get('token',''))" 2>/dev/null || echo "")

# ── Test 14: Create API key ───────────────────────────────────────────────────
APIKEY_RESP=""
APIKEY_ID=""
if [ -n "$TOKEN1" ]; then
    APIKEY_RESP=$(curl -s -X POST "${BASE}/api/v1/apikeys" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${TOKEN1}" \
        --data '{"name":"scenario-06-test-key","scopes":[]}' 2>/dev/null || echo "")
    APIKEY_ID=$(echo "$APIKEY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
    if [ -n "$APIKEY_ID" ] && [ "$APIKEY_ID" != "null" ]; then
        echo "PASS: Create API key returns key ID"
    else
        echo "FAIL: Create API key failed: $APIKEY_RESP"
    fi
else
    echo "FAIL: Cannot test create API key (no token)"
fi

# ── Test 15: List API keys ────────────────────────────────────────────────────
if [ -n "$TOKEN1" ]; then
    KEYS=$(curl -s "${BASE}/api/v1/apikeys" \
        -H "Authorization: Bearer ${TOKEN1}" 2>/dev/null || echo "")
    if echo "$KEYS" | python3 -c "import json,sys; d=json.load(sys.stdin); assert len(d.get('keys',[]))>=1" 2>/dev/null; then
        echo "PASS: List API keys returns at least one key"
    else
        echo "FAIL: List API keys returned unexpected data: $KEYS"
    fi
else
    echo "FAIL: Cannot test list API keys (no token)"
fi

# ── Test 16: Revoke API key ───────────────────────────────────────────────────
if [ -n "$TOKEN1" ] && [ -n "$APIKEY_ID" ] && [ "$APIKEY_ID" != "null" ]; then
    REVOKE=$(curl -s -X DELETE "${BASE}/api/v1/apikeys/${APIKEY_ID}" \
        -H "Authorization: Bearer ${TOKEN1}" 2>/dev/null || echo "")
    if echo "$REVOKE" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('revoked')==True" 2>/dev/null; then
        echo "PASS: Revoke API key returns revoked=true"
    else
        echo "FAIL: Revoke API key returned: $REVOKE"
    fi
else
    echo "FAIL: Cannot test revoke API key (missing token or key ID)"
fi

# ── Test 17: Search plugins ───────────────────────────────────────────────────
PLUGINS=$(curl -s "${BASE}/api/v1/plugins?q=admin" 2>/dev/null || echo "")
if echo "$PLUGINS" | python3 -c "import json,sys; p=json.load(sys.stdin); assert len(p)>=1 and any('admin' in str(x) for x in p)" 2>/dev/null; then
    echo "PASS: Plugin search returns results for 'admin'"
else
    echo "FAIL: Plugin search returned unexpected data: ${PLUGINS:0:100}"
fi

# ── Test 18: Duplicate registration returns 409 ──────────────────────────────
DUP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE}/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    --data "{\"email\":\"${EMAIL1}\",\"password\":\"${PASS}\",\"name\":\"Duplicate\"}")
if [ "$DUP_CODE" = "409" ]; then
    echo "PASS: Duplicate registration returns 409"
else
    echo "FAIL: Duplicate registration returned $DUP_CODE (expected 409)"
fi
