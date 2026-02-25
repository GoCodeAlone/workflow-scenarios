#!/usr/bin/env bash
set -euo pipefail

NS="wf-scenario-23"
BASE="http://localhost:18023"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Port-forward
kubectl port-forward -n "$NS" svc/workflow-server 18023:8080 &
PF_PID=$!
sleep 3

cleanup() { kill $PF_PID 2>/dev/null || true; }
trap cleanup EXIT

echo ""
echo "=== Scenario 23: NoSQL Data Store ==="
echo ""

# Test 1: Health check
RESP=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "")
if echo "$RESP" | grep -q '"ok"'; then
    pass "Health check returns ok"
else
    fail "Health check failed: $RESP"
fi

# Test 2: Create item alpha
CREATE=$(curl -sf -X POST "$BASE/api/items" \
    -H "Content-Type: application/json" \
    -d '{"id":"alpha","name":"Alpha Widget","price":10.99}' 2>/dev/null || echo "")
if echo "$CREATE" | grep -q '"stored":true'; then
    pass "Create item alpha returns stored=true"
else
    fail "Create item alpha failed: $CREATE"
fi

# Test 3: Create item beta
CREATE2=$(curl -sf -X POST "$BASE/api/items" \
    -H "Content-Type: application/json" \
    -d '{"id":"beta","name":"Beta Gadget","price":24.50}' 2>/dev/null || echo "")
if echo "$CREATE2" | grep -q '"stored":true'; then
    pass "Create item beta returns stored=true"
else
    fail "Create item beta failed: $CREATE2"
fi

# Test 4: Create item gamma
CREATE3=$(curl -sf -X POST "$BASE/api/items" \
    -H "Content-Type: application/json" \
    -d '{"id":"gamma","name":"Gamma Device","price":99.00}' 2>/dev/null || echo "")
if echo "$CREATE3" | grep -q '"stored":true'; then
    pass "Create item gamma returns stored=true"
else
    fail "Create item gamma failed: $CREATE3"
fi

# Test 5: List returns all 3 items
LIST=$(curl -sf "$BASE/api/items" 2>/dev/null || echo "")
COUNT=$(echo "$LIST" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")
if [ "$COUNT" = "3" ]; then
    pass "List returns 3 items after creating 3"
else
    fail "List count expected 3, got $COUNT: $LIST"
fi

# Test 6: List response contains items array
if echo "$LIST" | grep -q '"items"'; then
    pass "List response contains items field"
else
    fail "List response missing items field: $LIST"
fi

# Test 7: Get alpha by ID
GET=$(curl -sf "$BASE/api/items/alpha" 2>/dev/null || echo "")
if echo "$GET" | grep -q '"found":true'; then
    pass "Get item alpha returns found=true"
else
    fail "Get item alpha failed: $GET"
fi

# Test 8: Get alpha item has correct name
if echo "$GET" | grep -q '"Alpha Widget"'; then
    pass "Get item alpha has correct name"
else
    fail "Get item alpha name mismatch: $GET"
fi

# Test 9: Get non-existent item returns found=false (miss_ok)
GET_MISSING=$(curl -sf "$BASE/api/items/does-not-exist" 2>/dev/null || echo "")
if echo "$GET_MISSING" | grep -q '"found":false'; then
    pass "Get non-existent item returns found=false"
else
    fail "Get non-existent item unexpected response: $GET_MISSING"
fi

# Test 10: Delete item beta
DELETE=$(curl -sf -X DELETE "$BASE/api/items/beta" 2>/dev/null || echo "")
if echo "$DELETE" | grep -q '"deleted":true'; then
    pass "Delete item beta returns deleted=true"
else
    fail "Delete item beta failed: $DELETE"
fi

# Test 11: List after delete returns 2 items
LIST2=$(curl -sf "$BASE/api/items" 2>/dev/null || echo "")
COUNT2=$(echo "$LIST2" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")
if [ "$COUNT2" = "2" ]; then
    pass "List returns 2 items after deleting 1"
else
    fail "List count after delete expected 2, got $COUNT2"
fi

# Test 12: Get deleted item returns found=false
GET_DELETED=$(curl -sf "$BASE/api/items/beta" 2>/dev/null || echo "")
if echo "$GET_DELETED" | grep -q '"found":false'; then
    pass "Get deleted item returns found=false"
else
    fail "Get deleted item unexpected response: $GET_DELETED"
fi

# Test 13: Create item with unicode name
CREATE_UNI=$(curl -sf -X POST "$BASE/api/items" \
    -H "Content-Type: application/json" \
    -d '{"id":"delta","name":"Delta \u03b4 Item","value":42}' 2>/dev/null || echo "")
if echo "$CREATE_UNI" | grep -q '"stored":true'; then
    pass "Create item with unicode name succeeds"
else
    fail "Create item with unicode name failed: $CREATE_UNI"
fi

# Test 14: Final list count is 3 (alpha + gamma + delta)
LIST3=$(curl -sf "$BASE/api/items" 2>/dev/null || echo "")
COUNT3=$(echo "$LIST3" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")
if [ "$COUNT3" = "3" ]; then
    pass "Final list returns 3 items (alpha, gamma, delta)"
else
    fail "Final list count expected 3, got $COUNT3"
fi

# Test 15: Delete key is returned in response
KEY_VAL=$(echo "$DELETE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('key',''))" 2>/dev/null || echo "")
if [ "$KEY_VAL" = "item:beta" ]; then
    pass "Delete response contains correct key (item:beta)"
else
    fail "Delete response key expected 'item:beta', got '$KEY_VAL'"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

[ "$FAIL" -eq 0 ]
