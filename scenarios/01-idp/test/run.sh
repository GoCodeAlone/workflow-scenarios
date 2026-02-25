#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 01: Identity Provider
# Outputs PASS: or FAIL: lines for each test

# Port-forward
kubectl port-forward svc/workflow-server 18080:8080 -n "$NAMESPACE" &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE="http://localhost:18080"

# Test 1: Health check
RESPONSE=$(curl -sf "$BASE/healthz" 2>/dev/null)
if echo "$RESPONSE" | grep -q "ok"; then
    echo "PASS: Health check returns ok"
else
    echo "FAIL: Health check failed: $RESPONSE"
fi

# Test 2: Register a new user
REGISTER_RESPONSE=$(curl -sf -X POST "$BASE/api/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"test-$(date +%s)@example.com\",\"password\":\"TestPass123!\"}" 2>/dev/null || echo "ERROR")
if [ "$REGISTER_RESPONSE" != "ERROR" ]; then
    echo "PASS: User registration succeeds"
else
    echo "FAIL: User registration failed"
fi

# Test 3: Login with existing user
TOKEN=$(curl -sf -X POST "$BASE/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@example.com","password":"TestPassword123!"}' 2>/dev/null || echo "")
# Clean token (may be quoted)
TOKEN=$(echo "$TOKEN" | tr -d '"' | tr -d '\n')
if [ -n "$TOKEN" ] && [ "$TOKEN" != "ERROR" ]; then
    echo "PASS: Login returns JWT token"
else
    echo "FAIL: Login failed, no token returned"
fi

# Test 4: Access profile with valid token
if [ -n "$TOKEN" ]; then
    PROFILE=$(curl -sf "$BASE/api/auth/profile" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "ERROR")
    if echo "$PROFILE" | grep -q "admin@example.com"; then
        echo "PASS: Profile returns user data"
    else
        echo "FAIL: Profile request failed or wrong data: $PROFILE"
    fi
else
    echo "FAIL: Cannot test profile (no token from login)"
fi

# Test 5: Access profile without token returns 401
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE/api/auth/profile" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "401" ]; then
    echo "PASS: Unauthenticated profile request returns 401"
else
    echo "FAIL: Unauthenticated profile request returned $HTTP_CODE (expected 401)"
fi

# Test 6: Duplicate registration fails
DUP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/api/auth/register" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@example.com","password":"TestPassword123!"}' 2>/dev/null || echo "000")
if [ "$DUP_CODE" = "409" ] || [ "$DUP_CODE" = "400" ]; then
    echo "PASS: Duplicate registration returns error ($DUP_CODE)"
else
    echo "FAIL: Duplicate registration returned $DUP_CODE (expected 400 or 409)"
fi

# Test 7: Login with wrong password fails
WRONG_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@example.com","password":"wrongpassword"}' 2>/dev/null || echo "000")
if [ "$WRONG_CODE" = "401" ]; then
    echo "PASS: Wrong password returns 401"
else
    echo "FAIL: Wrong password returned $WRONG_CODE (expected 401)"
fi
