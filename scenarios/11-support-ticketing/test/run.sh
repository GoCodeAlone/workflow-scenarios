#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 11: Customer Support Ticketing
# Outputs PASS: or FAIL: lines for each test

kubectl port-forward svc/workflow-server 18080:8080 -n "$NAMESPACE" &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE="http://localhost:18080"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Test 1: Health check
RESPONSE=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "")
if echo "$RESPONSE" | grep -q '"ok"'; then
    pass "Health check returns ok"
else
    fail "Health check failed: $RESPONSE"
fi

# Test 2: Init DB
INIT=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/internal/init-db" 2>/dev/null || echo "000")
if [ "$INIT" = "200" ]; then
    pass "Database initialized"
else
    fail "Database init returned $INIT (expected 200)"
fi

# Test 3: Create low-priority ticket
LOW=$(curl -sf -X POST "$BASE/api/v1/tickets" \
    -H "Content-Type: application/json" \
    -d '{"subject":"Login button not working","description":"Users report the login button is unresponsive on mobile.","priority":"low"}' 2>/dev/null || echo "")
LOW_ID=$(echo "$LOW" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
if [ -n "$LOW_ID" ] && echo "$LOW" | grep -q '"open"'; then
    pass "Create low-priority ticket returns open state"
else
    fail "Create low-priority ticket failed: $LOW"
fi

# Test 4: Create critical priority ticket
CRIT=$(curl -sf -X POST "$BASE/api/v1/tickets" \
    -H "Content-Type: application/json" \
    -d '{"subject":"Payment service down","description":"All payment transactions failing with 503.","priority":"critical"}' 2>/dev/null || echo "")
CRIT_ID=$(echo "$CRIT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
if [ -n "$CRIT_ID" ] && echo "$CRIT" | grep -q '"critical"'; then
    pass "Create critical-priority ticket returns correct priority"
else
    fail "Create critical ticket failed: $CRIT"
fi

# Test 5: List tickets contains created tickets
LIST=$(curl -sf "$BASE/api/v1/tickets" 2>/dev/null || echo "")
if echo "$LIST" | grep -q "Login button" || echo "$LIST" | grep -q "Payment service"; then
    pass "List tickets contains created tickets"
else
    fail "List tickets missing created tickets: $LIST"
fi

# Test 6: Get ticket (cache miss - first fetch from DB)
if [ -n "$LOW_ID" ]; then
    GET=$(curl -sf "$BASE/api/v1/tickets/$LOW_ID" 2>/dev/null || echo "")
    if echo "$GET" | grep -q '"open"' && echo "$GET" | grep -q "Login button"; then
        pass "Get ticket returns correct data (DB fetch)"
    else
        fail "Get ticket failed: $GET"
    fi
else
    fail "Cannot test get ticket (no ID)"
fi

# Test 7: Get ticket (cache hit - second fetch)
if [ -n "$LOW_ID" ]; then
    GET2=$(curl -sf "$BASE/api/v1/tickets/$LOW_ID" 2>/dev/null || echo "")
    if echo "$GET2" | grep -q '"open"'; then
        pass "Get ticket cache hit returns correct data"
    else
        fail "Get ticket cache hit failed: $GET2"
    fi
else
    fail "Cannot test cache hit (no ID)"
fi

# Test 8: Cannot resolve unassigned ticket
if [ -n "$LOW_ID" ]; then
    RES_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/tickets/$LOW_ID/resolve" 2>/dev/null || echo "000")
    if [ "$RES_CODE" = "422" ]; then
        pass "Cannot resolve unassigned ticket (422)"
    else
        fail "Resolve unassigned returned $RES_CODE (expected 422)"
    fi
else
    fail "Cannot test resolve-unassigned (no ID)"
fi

# Test 9: Assign ticket to agent
if [ -n "$LOW_ID" ]; then
    ASSIGN=$(curl -sf -X POST "$BASE/api/v1/tickets/$LOW_ID/assign" \
        -H "Content-Type: application/json" \
        -d '{"agent":"agent-alice"}' 2>/dev/null || echo "")
    if echo "$ASSIGN" | grep -q '"assigned"' && echo "$ASSIGN" | grep -q "agent-alice"; then
        pass "Assign ticket to agent returns assigned state"
    else
        fail "Assign ticket failed: $ASSIGN"
    fi
else
    fail "Cannot test assign (no ID)"
fi

# Test 10: Full lifecycle - create, assign, resolve
FULL=$(curl -sf -X POST "$BASE/api/v1/tickets" \
    -H "Content-Type: application/json" \
    -d '{"subject":"Full lifecycle test","description":"Testing full ticket lifecycle.","priority":"medium"}' 2>/dev/null || echo "")
FULL_ID=$(echo "$FULL" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
if [ -n "$FULL_ID" ]; then
    curl -sf -X POST "$BASE/api/v1/tickets/$FULL_ID/assign" \
        -H "Content-Type: application/json" \
        -d '{"agent":"agent-bob"}' > /dev/null 2>&1 || true
    RESOLVED=$(curl -sf -X POST "$BASE/api/v1/tickets/$FULL_ID/resolve" 2>/dev/null || echo "")
    if echo "$RESOLVED" | grep -q '"resolved"'; then
        pass "Full lifecycle: create → assign → resolve succeeds"
    else
        fail "Full lifecycle resolve failed: $RESOLVED"
    fi
else
    fail "Full lifecycle create failed"
fi

# Test 11: Reopen resolved ticket
if [ -n "$FULL_ID" ]; then
    REOPEN=$(curl -sf -X POST "$BASE/api/v1/tickets/$FULL_ID/reopen" 2>/dev/null || echo "")
    if echo "$REOPEN" | grep -q '"open"'; then
        pass "Reopen resolved ticket transitions back to open"
    else
        fail "Reopen ticket failed: $REOPEN"
    fi
else
    fail "Cannot test reopen (no ID)"
fi

# Test 12: Add comment to ticket
if [ -n "$LOW_ID" ]; then
    COMMENT=$(curl -sf -X POST "$BASE/api/v1/tickets/$LOW_ID/comment" \
        -H "Content-Type: application/json" \
        -d '{"author":"agent-alice","body":"Investigated the issue — reproducing on iOS Safari only."}' 2>/dev/null || echo "")
    if echo "$COMMENT" | grep -q "comment added"; then
        pass "Add comment to ticket succeeds"
    else
        fail "Add comment failed: $COMMENT"
    fi
else
    fail "Cannot test add comment (no ID)"
fi

# Test 13: Escalate ticket to critical priority
if [ -n "$CRIT_ID" ]; then
    ESCALATE=$(curl -sf -X POST "$BASE/api/v1/tickets/$CRIT_ID/escalate" 2>/dev/null || echo "")
    if echo "$ESCALATE" | grep -q '"critical"'; then
        pass "Escalate ticket returns critical priority"
    else
        fail "Escalate ticket failed: $ESCALATE"
    fi
else
    fail "Cannot test escalate (no ID)"
fi

# Test 14: Invalid ticket creation (missing required fields)
BAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/tickets" \
    -H "Content-Type: application/json" \
    -d '{"priority":"high"}' 2>/dev/null || echo "000")
if [ "$BAD_CODE" = "400" ] || [ "$BAD_CODE" = "422" ] || [ "$BAD_CODE" = "500" ]; then
    pass "Create ticket with missing fields returns error ($BAD_CODE)"
else
    fail "Missing fields returned $BAD_CODE (expected 400/422/500)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
