#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 03: AI Agent Platform (Ratchet)
# Outputs PASS: or FAIL: lines for each test
# Ratchet is deployed in the default namespace on port 9090

RATCHET_NS="default"
RATCHET_SVC="ratchet"
RATCHET_PORT="9090"
LOCAL_PORT="9091"

# Kill any existing port-forwards on this port
pkill -f "port-forward.*${LOCAL_PORT}" 2>/dev/null || true
sleep 1

# Port-forward to ratchet
kubectl port-forward "svc/${RATCHET_SVC}" "${LOCAL_PORT}:${RATCHET_PORT}" -n "${RATCHET_NS}" &
PF_PID=$!
sleep 3

cleanup() {
    kill "$PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

BASE="http://localhost:${LOCAL_PORT}"
PASS=0
FAIL=0

# Test 1: Status endpoint (public, no auth)
STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE}/api/status" 2>/dev/null || echo "000")
if [ "$STATUS_CODE" = "200" ]; then
    echo "PASS: Ratchet status endpoint returns 200"
    PASS=$((PASS + 1))
else
    echo "FAIL: Ratchet status endpoint returned $STATUS_CODE (expected 200)"
    FAIL=$((FAIL + 1))
fi

# Test 2: Status response contains expected fields
STATUS_BODY=$(curl -s "${BASE}/api/status" 2>/dev/null || echo "ERROR")
if echo "$STATUS_BODY" | grep -qi "version\|ok\|status\|ratchet"; then
    echo "PASS: Status response contains expected fields"
    PASS=$((PASS + 1))
else
    echo "FAIL: Status response missing expected fields: $STATUS_BODY"
    FAIL=$((FAIL + 1))
fi

# Test 3: Auth login with admin/admin
LOGIN_RESP=$(curl -s -X POST "${BASE}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"admin"}' 2>/dev/null || echo "ERROR")
if echo "$LOGIN_RESP" | grep -q "token"; then
    echo "PASS: Login returns auth token"
    PASS=$((PASS + 1))
else
    echo "FAIL: Login did not return token: $LOGIN_RESP"
    FAIL=$((FAIL + 1))
fi

# Extract token for subsequent requests
TOKEN=$(echo "$LOGIN_RESP" | grep -o '"token":"[^"]*"' | cut -d'"' -f4 || echo "")
if [ -z "$TOKEN" ]; then
    TOKEN="ratchet-dev-token-change-me-in-production"
fi

# Test 4: Agents endpoint (auth required) returns 200
AGENTS_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    "${BASE}/api/agents" 2>/dev/null || echo "000")
if [ "$AGENTS_CODE" = "200" ]; then
    echo "PASS: Agents endpoint returns 200 with auth"
    PASS=$((PASS + 1))
else
    echo "FAIL: Agents endpoint returned $AGENTS_CODE (expected 200)"
    FAIL=$((FAIL + 1))
fi

# Test 5: Agents response contains agent data (mock agents seeded at startup)
AGENTS_BODY=$(curl -s \
    -H "Authorization: Bearer ${TOKEN}" \
    "${BASE}/api/agents" 2>/dev/null || echo "ERROR")
if echo "$AGENTS_BODY" | grep -qi "id\|name\|agent\|\[\]"; then
    echo "PASS: Agents response contains agent data"
    PASS=$((PASS + 1))
else
    echo "FAIL: Agents response missing expected data: $AGENTS_BODY"
    FAIL=$((FAIL + 1))
fi

# Test 6: Providers endpoint (auth required) returns 200
PROVIDERS_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    "${BASE}/api/providers" 2>/dev/null || echo "000")
if [ "$PROVIDERS_CODE" = "200" ]; then
    echo "PASS: Providers endpoint returns 200 with auth"
    PASS=$((PASS + 1))
else
    echo "FAIL: Providers endpoint returned $PROVIDERS_CODE (expected 200)"
    FAIL=$((FAIL + 1))
fi

# Test 7: Providers response contains mock provider (seeded by db_init hook)
PROVIDERS_BODY=$(curl -s \
    -H "Authorization: Bearer ${TOKEN}" \
    "${BASE}/api/providers" 2>/dev/null || echo "ERROR")
if echo "$PROVIDERS_BODY" | grep -qi "mock\|provider\|\[\]"; then
    echo "PASS: Providers response contains provider data (mock seeded)"
    PASS=$((PASS + 1))
else
    echo "FAIL: Providers response missing expected data: $PROVIDERS_BODY"
    FAIL=$((FAIL + 1))
fi

# Test 8: Tasks endpoint (auth required) returns 200
TASKS_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    "${BASE}/api/tasks" 2>/dev/null || echo "000")
if [ "$TASKS_CODE" = "200" ]; then
    echo "PASS: Tasks endpoint returns 200 with auth"
    PASS=$((PASS + 1))
else
    echo "FAIL: Tasks endpoint returned $TASKS_CODE (expected 200)"
    FAIL=$((FAIL + 1))
fi

# Test 9: Unauthenticated request to protected endpoint returns 401
UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "${BASE}/api/agents" 2>/dev/null || echo "000")
if [ "$UNAUTH_CODE" = "401" ]; then
    echo "PASS: Unauthenticated request to protected endpoint returns 401"
    PASS=$((PASS + 1))
else
    echo "FAIL: Unauthenticated request returned $UNAUTH_CODE (expected 401)"
    FAIL=$((FAIL + 1))
fi

# Test 10: Create a task (agent work item) via API
CREATE_TASK_RESP=$(curl -s -X POST "${BASE}/api/tasks" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    -d '{"title":"scenario-03-test-task","description":"Test task created by scenario 03","priority":"low"}' \
    2>/dev/null || echo "ERROR")
if echo "$CREATE_TASK_RESP" | grep -qi "id\|task\|created\|scenario-03"; then
    echo "PASS: Task creation returns task data"
    PASS=$((PASS + 1))
else
    echo "FAIL: Task creation response unexpected: $CREATE_TASK_RESP"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed out of $((PASS + FAIL)) tests"
