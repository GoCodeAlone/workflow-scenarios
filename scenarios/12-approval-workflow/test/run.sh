#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 12: Multi-Step Approval Workflow
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

# Test 3: Submit request ($99 - below manager threshold)
SMALL=$(curl -sf -X POST "$BASE/api/v1/requests" \
    -H "Content-Type: application/json" \
    -d '{"description":"Office supplies order","category":"supplies","amount":99,"requester":"alice"}' 2>/dev/null || echo "")
SMALL_ID=$(echo "$SMALL" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
if [ -n "$SMALL_ID" ] && echo "$SMALL" | grep -q '"submitted"'; then
    pass "Submit small request (\$99) returns submitted state"
else
    fail "Submit small request failed: $SMALL"
fi

# Test 4: Approve small request at manager level
if [ -n "$SMALL_ID" ]; then
    APPROVE=$(curl -sf -X POST "$BASE/api/v1/requests/$SMALL_ID/approve" \
        -H "Content-Type: application/json" \
        -d '{"approver":"manager-bob","level":"manager","notes":"Approved for Q1 budget"}' 2>/dev/null || echo "")
    if echo "$APPROVE" | grep -q '"approved"' && echo "$APPROVE" | grep -q "manager-bob"; then
        pass "Manager approval of small request succeeds"
    else
        fail "Manager approval failed: $APPROVE"
    fi
else
    fail "Cannot test manager approval (no ID)"
fi

# Test 5: Submit $100 boundary request
BOUNDARY=$(curl -sf -X POST "$BASE/api/v1/requests" \
    -H "Content-Type: application/json" \
    -d '{"description":"Boundary test","category":"test","amount":100,"requester":"carol"}' 2>/dev/null || echo "")
BOUNDARY_ID=$(echo "$BOUNDARY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
if [ -n "$BOUNDARY_ID" ] && echo "$BOUNDARY" | grep -q '"submitted"'; then
    pass "Submit \$100 boundary request succeeds"
else
    fail "Submit \$100 boundary request failed: $BOUNDARY"
fi

# Test 6: Submit $999 boundary request
BOUNDARY2=$(curl -sf -X POST "$BASE/api/v1/requests" \
    -H "Content-Type: application/json" \
    -d '{"description":"Boundary test 999","category":"test","amount":999,"requester":"dan"}' 2>/dev/null || echo "")
BOUNDARY2_ID=$(echo "$BOUNDARY2" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
if [ -n "$BOUNDARY2_ID" ] && echo "$BOUNDARY2" | grep -q '"submitted"'; then
    pass "Submit \$999 boundary request succeeds"
else
    fail "Submit \$999 boundary request failed: $BOUNDARY2"
fi

# Test 7: Submit large request ($1001 - VP level required)
LARGE=$(curl -sf -X POST "$BASE/api/v1/requests" \
    -H "Content-Type: application/json" \
    -d '{"description":"New server hardware","category":"infrastructure","amount":1001,"requester":"eve"}' 2>/dev/null || echo "")
LARGE_ID=$(echo "$LARGE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
if [ -n "$LARGE_ID" ] && echo "$LARGE" | grep -q '"submitted"'; then
    pass "Submit large request (\$1001) returns submitted state"
else
    fail "Submit large request failed: $LARGE"
fi

# Test 8: VP approves large request
if [ -n "$LARGE_ID" ]; then
    VP_APPROVE=$(curl -sf -X POST "$BASE/api/v1/requests/$LARGE_ID/approve" \
        -H "Content-Type: application/json" \
        -d '{"approver":"vp-frank","level":"vp","notes":"Approved at VP level for critical infrastructure"}' 2>/dev/null || echo "")
    if echo "$VP_APPROVE" | grep -q '"approved"' && echo "$VP_APPROVE" | grep -q "vp-frank"; then
        pass "VP approval of large request succeeds"
    else
        fail "VP approval failed: $VP_APPROVE"
    fi
else
    fail "Cannot test VP approval (no ID)"
fi

# Test 9: Reject request at level 1
REJ1=$(curl -sf -X POST "$BASE/api/v1/requests" \
    -H "Content-Type: application/json" \
    -d '{"description":"Unnecessary expense","category":"entertainment","amount":200,"requester":"george"}' 2>/dev/null || echo "")
REJ1_ID=$(echo "$REJ1" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
if [ -n "$REJ1_ID" ]; then
    REJECT=$(curl -sf -X POST "$BASE/api/v1/requests/$REJ1_ID/reject" \
        -H "Content-Type: application/json" \
        -d '{"rejector":"manager-bob","reason":"Outside budget policy for entertainment"}' 2>/dev/null || echo "")
    if echo "$REJECT" | grep -q '"rejected"' && echo "$REJECT" | grep -q "budget policy"; then
        pass "Reject request at manager level with reason"
    else
        fail "Reject at level 1 failed: $REJECT"
    fi
else
    fail "Cannot test level 1 rejection (no ID)"
fi

# Test 10: Cannot approve already-rejected request
if [ -n "$REJ1_ID" ]; then
    DBL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/requests/$REJ1_ID/approve" \
        -H "Content-Type: application/json" \
        -d '{"approver":"manager-bob","level":"manager"}' 2>/dev/null || echo "000")
    if [ "$DBL_CODE" = "409" ]; then
        pass "Cannot approve already-rejected request (409)"
    else
        fail "Approve rejected returned $DBL_CODE (expected 409)"
    fi
else
    fail "Cannot test double-approve (no ID)"
fi

# Test 11: View approval history contains submitted + approved events
if [ -n "$SMALL_ID" ]; then
    HISTORY=$(curl -sf "$BASE/api/v1/requests/$SMALL_ID/history" 2>/dev/null || echo "")
    if echo "$HISTORY" | grep -q '"submitted"' && echo "$HISTORY" | grep -q '"approved"'; then
        pass "Approval history contains submitted and approved events"
    else
        fail "Approval history missing events: $HISTORY"
    fi
else
    fail "Cannot test history (no ID)"
fi

# Test 12: View rejection history
if [ -n "$REJ1_ID" ]; then
    REJ_HIST=$(curl -sf "$BASE/api/v1/requests/$REJ1_ID/history" 2>/dev/null || echo "")
    if echo "$REJ_HIST" | grep -q '"rejected"' && echo "$REJ_HIST" | grep -q "budget policy"; then
        pass "Rejection history contains rejection reason"
    else
        fail "Rejection history missing data: $REJ_HIST"
    fi
else
    fail "Cannot test rejection history (no ID)"
fi

# Test 13: List requests contains all submitted requests
LIST=$(curl -sf "$BASE/api/v1/requests" 2>/dev/null || echo "")
if echo "$LIST" | grep -q "alice" && echo "$LIST" | grep -q "eve"; then
    pass "List requests returns all submitted requests"
else
    fail "List requests missing entries: $LIST"
fi

# Test 14: Invalid request (missing required fields)
BAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/requests" \
    -H "Content-Type: application/json" \
    -d '{"description":"Missing fields"}' 2>/dev/null || echo "000")
if [ "$BAD_CODE" = "400" ] || [ "$BAD_CODE" = "422" ] || [ "$BAD_CODE" = "500" ]; then
    pass "Missing required fields returns error ($BAD_CODE)"
else
    fail "Missing fields returned $BAD_CODE (expected 400/422/500)"
fi

# Test 15: Get request details
if [ -n "$LARGE_ID" ]; then
    GET=$(curl -sf "$BASE/api/v1/requests/$LARGE_ID" 2>/dev/null || echo "")
    if echo "$GET" | grep -q '"approved"' && echo "$GET" | grep -q "vp-frank"; then
        pass "Get request details returns approval information"
    else
        fail "Get request details failed: $GET"
    fi
else
    fail "Cannot test get request details (no ID)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
