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

# Test 2: Login with seeded admin user
TOKEN=$(curl -sf -X POST "$BASE/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@example.com","password":"TestPassword123!"}' 2>/dev/null || echo "")
# Clean token (may be wrapped in {"token":"..."})
TOKEN=$(echo "$TOKEN" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || echo "")
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    echo "PASS: Login returns JWT token"
else
    echo "FAIL: Login failed, no token returned. Response: $TOKEN"
fi

# Test 3: Access profile with valid token
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
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

# Test 4: Access profile without token returns 401
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/auth/profile" 2>/dev/null)
if [ "$HTTP_CODE" = "401" ]; then
    echo "PASS: Unauthenticated profile request returns 401"
else
    echo "FAIL: Unauthenticated profile request returned $HTTP_CODE (expected 401)"
fi

# Test 5: Setup endpoint returns 403 when users already exist
SETUP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/auth/setup" \
    -H "Content-Type: application/json" \
    -d '{"email":"new@example.com","password":"TestPassword123!"}' 2>/dev/null)
if [ "$SETUP_CODE" = "403" ]; then
    echo "PASS: Setup endpoint returns 403 when users already exist"
else
    echo "FAIL: Setup endpoint returned $SETUP_CODE (expected 403 after setup)"
fi

# Test 6: Login with wrong password fails
WRONG_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@example.com","password":"wrongpassword"}' 2>/dev/null)
if [ "$WRONG_CODE" = "401" ]; then
    echo "PASS: Wrong password returns 401"
else
    echo "FAIL: Wrong password returned $WRONG_CODE (expected 401)"
fi

# Test 7: Admin can create a new user
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    NEW_USER_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/auth/users" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -d "{\"email\":\"newuser-$(date +%s)@example.com\",\"password\":\"TestPass123!\",\"name\":\"New User\"}" 2>/dev/null || echo "000")
    if [ "$NEW_USER_CODE" = "201" ]; then
        echo "PASS: Admin can create new users"
    else
        echo "FAIL: Admin user creation returned $NEW_USER_CODE (expected 201)"
    fi
else
    echo "FAIL: Cannot test user creation (no token from login)"
fi
