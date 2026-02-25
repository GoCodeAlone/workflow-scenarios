#!/usr/bin/env bash
# Test script for Scenario 07: No-Code Workflow
# Tests the workflow-plugin-admin visual builder running inside the workflow engine.
# Validates the admin UI, auth, and workflow management APIs.
set -euo pipefail

NAMESPACE="${NAMESPACE:-wf-scenario-07}"
ADMIN_PORT="${ADMIN_PORT:-18081}"
PRIMARY_PORT="${PRIMARY_PORT:-18080}"
ADMIN_BASE="http://localhost:${ADMIN_PORT}"
PRIMARY_BASE="http://localhost:${PRIMARY_PORT}"

# Port-forward to both ports
PF_PID=""

if ! curl -sf "${PRIMARY_BASE}/healthz" >/dev/null 2>&1 || ! curl -s "${ADMIN_BASE}/api/v1/auth/setup-status" >/dev/null 2>&1; then
    kubectl port-forward svc/workflow-server "${PRIMARY_PORT}:8080" "${ADMIN_PORT}:8081" -n "$NAMESPACE" >/tmp/pf-scenario07.log 2>&1 &
    PF_PID=$!
    sleep 5
fi

cleanup() {
    [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Helper: extract token from admin auth response (handles access_token or token field)
extract_token() {
    python3 -c "
import json,sys
d=json.load(sys.stdin)
# Try access_token (admin plugin format) then token (workflow-cloud format)
t = d.get('access_token','') or d.get('token','')
print(t if t and t != 'null' else '')
" 2>/dev/null || echo ""
}

# ── Test 1: Primary server health check ──────────────────────────────────────
HEALTH=$(curl -sf "${PRIMARY_BASE}/healthz" 2>/dev/null || echo "")
if echo "$HEALTH" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('status')=='ok'" 2>/dev/null; then
    echo "PASS: Primary server health check returns ok"
else
    echo "FAIL: Primary server health check failed: $HEALTH"
fi

# ── Test 2: Admin setup status endpoint is reachable ─────────────────────────
SETUP_STATUS=$(curl -sf "${ADMIN_BASE}/api/v1/auth/setup-status" 2>/dev/null || \
               curl -s "${ADMIN_BASE}/api/v1/auth/setup-status" 2>/dev/null || echo "")
if [ -n "$SETUP_STATUS" ]; then
    echo "PASS: Admin setup-status endpoint is reachable"
else
    echo "FAIL: Admin setup-status endpoint not reachable"
fi

# ── Test 3: Admin UI serves HTML ──────────────────────────────────────────────
ADMIN_ROOT=$(curl -s "${ADMIN_BASE}/" 2>/dev/null || echo "")
if echo "$ADMIN_ROOT" | grep -qi "html"; then
    echo "PASS: Admin UI root serves HTML"
else
    echo "FAIL: Admin UI root did not return HTML: ${ADMIN_ROOT:0:100}"
fi

# ── Test 4: Admin setup (create first admin user) ─────────────────────────────
SETUP_RESP=$(curl -s -X POST "${ADMIN_BASE}/api/v1/auth/setup" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@scenario07.com","password":"TestPass123x","name":"Admin"}' 2>/dev/null || echo "")
ADMIN_TOKEN=$(echo "$SETUP_RESP" | extract_token)
# If setup already done (409 / setup disabled), try login
if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
    LOGIN_RESP=$(curl -s -X POST "${ADMIN_BASE}/api/v1/auth/login" \
        -H "Content-Type: application/json" \
        -d '{"email":"admin@scenario07.com","password":"TestPass123x"}' 2>/dev/null || echo "")
    ADMIN_TOKEN=$(echo "$LOGIN_RESP" | extract_token)
fi
if [ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ]; then
    echo "PASS: Admin setup/login returns JWT token"
else
    echo "FAIL: Admin setup/login failed: $SETUP_RESP"
fi

# ── Test 5: Admin auth — get current user profile ────────────────────────────
if [ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ]; then
    ME=$(curl -s "${ADMIN_BASE}/api/v1/auth/me" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "")
    if echo "$ME" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'admin@scenario07.com' in str(d)" 2>/dev/null; then
        echo "PASS: Admin profile returns user data"
    else
        echo "FAIL: Admin profile returned unexpected data: $ME"
    fi
else
    echo "FAIL: Cannot test admin profile (no token)"
fi

# ── Test 6: Admin engine status ───────────────────────────────────────────────
if [ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ]; then
    STATUS=$(curl -s "${ADMIN_BASE}/api/v1/admin/engine/status" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "")
    if [ -n "$STATUS" ] && echo "$STATUS" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
        echo "PASS: Admin engine status returns JSON"
    else
        echo "FAIL: Admin engine status failed: ${STATUS:0:100}"
    fi
else
    echo "FAIL: Cannot test engine status (no token)"
fi

# ── Test 7: Admin engine modules list ────────────────────────────────────────
if [ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ]; then
    MODULES=$(curl -s "${ADMIN_BASE}/api/v1/admin/engine/modules" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "")
    if echo "$MODULES" | python3 -c "import json,sys; d=json.load(sys.stdin); assert len(d)>=1" 2>/dev/null; then
        echo "PASS: Admin modules list returns at least one module"
    else
        echo "FAIL: Admin modules list failed: ${MODULES:0:100}"
    fi
else
    echo "FAIL: Cannot test modules list (no token)"
fi

# ── Test 8: Admin unauthorized access returns 401 ────────────────────────────
UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${ADMIN_BASE}/api/v1/admin/engine/status")
if [ "$UNAUTH_CODE" = "401" ]; then
    echo "PASS: Admin endpoint without token returns 401"
else
    echo "FAIL: Admin endpoint without token returned $UNAUTH_CODE (expected 401)"
fi

# ── Test 9: Admin engine config is accessible ─────────────────────────────────
if [ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ]; then
    ENGINE_CONFIG=$(curl -s "${ADMIN_BASE}/api/v1/admin/engine/config" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "")
    if [ -n "$ENGINE_CONFIG" ] && echo "$ENGINE_CONFIG" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
        echo "PASS: Engine config endpoint returns JSON"
    else
        echo "FAIL: Engine config endpoint failed: ${ENGINE_CONFIG:0:100}"
    fi
else
    echo "FAIL: Cannot test engine config (no token)"
fi

# ── Test 10: Admin plugin loaded (engine has more than 5 modules loaded) ─────
if [ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ]; then
    STATUS=$(curl -s "${ADMIN_BASE}/api/v1/admin/engine/status" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "")
    if echo "$STATUS" | python3 -c "
import json,sys
d=json.load(sys.stdin)
count = d.get('moduleCount', 0)
# The admin plugin adds 20+ modules; base server has ~3; combined should be >10
assert count > 10, f'Expected >10 modules, got {count}'
" 2>/dev/null; then
        echo "PASS: Engine has >10 modules loaded (admin plugin is active)"
    else
        echo "FAIL: Engine module count too low (admin plugin may not be loaded): $STATUS"
    fi
else
    echo "FAIL: Cannot test plugin modules (no token)"
fi
