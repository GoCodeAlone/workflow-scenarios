#!/usr/bin/env bash
# Scenario 54: Okta Integration
# Tests workflow-plugin-okta step types against a mock Okta API server.
set -euo pipefail

PORT=18054
NAMESPACE="${NAMESPACE:-wf-scenario-54}"
BASE_URL="${BASE_URL:-http://localhost:${PORT}}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 54: Okta Integration ==="

# Start port-forward if not already reachable
if ! curl -sf --max-time 2 "${BASE_URL}/healthz" &>/dev/null; then
    kubectl port-forward -n "$NAMESPACE" svc/workflow-server "${PORT}:8080" &>/dev/null &
    PF_PID=$!
    trap "kill $PF_PID 2>/dev/null || true" EXIT
    for i in $(seq 1 30); do
        if curl -sf --max-time 2 "${BASE_URL}/healthz" &>/dev/null; then break; fi
        sleep 1
    done
fi

echo ""

# ----------------------------------------------------------------
# Health Check (2 tests)
# ----------------------------------------------------------------

RESULT=$(curl -s "$BASE_URL/healthz")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$STATUS" = "ok" ] && pass "Health check returns ok" || fail "Health check failed (got: $STATUS)"

SCENARIO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scenario',''))" 2>/dev/null || echo "")
[ "$SCENARIO" = "54-okta-integration" ] && pass "Health check identifies scenario 54" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# ----------------------------------------------------------------
# User CRUD (7 tests)
# ----------------------------------------------------------------

# Test 3: Create user
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/okta/users" \
  -H "Content-Type: application/json" \
  -d '{"firstName":"Jane","lastName":"Doe","email":"jane.doe@example.com","login":"jane.doe@example.com"}')
USER_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
USER_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ -n "$USER_ID" ] && [ "$USER_ID" != "null" ] && pass "Create user returns id ($USER_ID)" || fail "Create user missing id (got: $USER_ID)"
[ "$USER_STATUS" = "STAGED" ] && pass "Create user status is STAGED" || fail "Create user status mismatch (got: $USER_STATUS)"

# Test 5: Get user
RESULT=$(curl -s "$BASE_URL/api/v1/okta/users/$USER_ID")
GET_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
GET_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$GET_ID" = "$USER_ID" ] && pass "Get user returns correct id" || fail "Get user id mismatch (got: $GET_ID, expected: $USER_ID)"
[ "$GET_STATUS" = "ACTIVE" ] && pass "Get user status is ACTIVE" || fail "Get user status mismatch (got: $GET_STATUS)"

# Test 7: List users
RESULT=$(curl -s "$BASE_URL/api/v1/okta/users")
USER_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$USER_COUNT" -ge 1 ] && pass "List users returns count >= 1 (got: $USER_COUNT)" || fail "List users returned zero (got: $USER_COUNT)"

# Test 8: Update user
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/okta/users/$USER_ID/update" \
  -H "Content-Type: application/json" \
  -d '{"firstName":"Updated","lastName":"User","email":"updated@example.com"}')
UPD_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
[ "$UPD_ID" = "$USER_ID" ] && pass "Update user returns correct id" || fail "Update user id mismatch (got: $UPD_ID)"

# Test 9: Delete user
RESULT=$(curl -s -X DELETE "$BASE_URL/api/v1/okta/users/$USER_ID")
DELETED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('deleted',False))" 2>/dev/null || echo "")
[ "$DELETED" = "True" ] && pass "Delete user returns deleted=true" || fail "Delete user mismatch (got: $DELETED)"

# ----------------------------------------------------------------
# Group Operations (5 tests)
# ----------------------------------------------------------------

# Test 10: Create group
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/okta/groups" \
  -H "Content-Type: application/json" \
  -d '{"name":"Engineering","description":"Engineering team"}')
GROUP_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
GROUP_TYPE=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type',''))" 2>/dev/null || echo "")
[ -n "$GROUP_ID" ] && [ "$GROUP_ID" != "null" ] && pass "Create group returns id ($GROUP_ID)" || fail "Create group missing id (got: $GROUP_ID)"
[ "$GROUP_TYPE" = "OKTA_GROUP" ] && pass "Create group type is OKTA_GROUP" || fail "Create group type mismatch (got: $GROUP_TYPE)"

# Test 12: List groups
RESULT=$(curl -s "$BASE_URL/api/v1/okta/groups")
GROUP_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$GROUP_COUNT" -ge 1 ] && pass "List groups returns count >= 1 (got: $GROUP_COUNT)" || fail "List groups returned zero (got: $GROUP_COUNT)"

# Test 13: Add user to group
RESULT=$(curl -s -X PUT "$BASE_URL/api/v1/okta/groups/$GROUP_ID/users/00u1abcdef1234567890")
ADDED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('added',False))" 2>/dev/null || echo "")
[ "$ADDED" = "True" ] && pass "Add user to group returns added=true" || fail "Add user to group mismatch (got: $ADDED)"

# Test 14: List group members
RESULT=$(curl -s "$BASE_URL/api/v1/okta/groups/$GROUP_ID/users")
MEMBER_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$MEMBER_COUNT" -ge 1 ] && pass "List group members returns count >= 1 (got: $MEMBER_COUNT)" || fail "List group members returned zero (got: $MEMBER_COUNT)"

# ----------------------------------------------------------------
# App Operations (2 tests)
# ----------------------------------------------------------------

# Test 15: List apps
RESULT=$(curl -s "$BASE_URL/api/v1/okta/apps")
APP_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$APP_COUNT" -ge 1 ] && pass "List apps returns count >= 1 (got: $APP_COUNT)" || fail "List apps returned zero (got: $APP_COUNT)"

HAS_APPS=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('apps',[])))" 2>/dev/null || echo "0")
[ "$HAS_APPS" -ge 1 ] && pass "List apps has apps array with entries" || fail "List apps missing apps array (got: $HAS_APPS)"

# ----------------------------------------------------------------
# Deactivate User (1 test)
# ----------------------------------------------------------------

# Test 17: Deactivate user
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/okta/users/00u1abcdef1234567890/deactivate")
DEACTIVATED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('deactivated',False))" 2>/dev/null || echo "")
[ "$DEACTIVATED" = "True" ] && pass "Deactivate user returns deactivated=true" || fail "Deactivate user mismatch (got: $DEACTIVATED)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
