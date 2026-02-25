#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 09: E-Commerce Order Management
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

# Test 3: Create order - verify pending state
CREATE=$(curl -sf -X POST "$BASE/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d '{"customer_email":"test@example.com","items":[{"sku":"PROD-001","qty":1,"price":99.99}],"shipping_address":"456 Test Ave","total":99.99}' 2>/dev/null || echo "")
ORDER_ID=$(echo "$CREATE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
if [ -n "$ORDER_ID" ] && echo "$CREATE" | grep -q '"pending"'; then
    pass "Create order returns pending state with ID"
else
    fail "Create order failed: $CREATE"
fi

# Test 4: Get order details
if [ -n "$ORDER_ID" ]; then
    GET=$(curl -sf "$BASE/api/v1/orders/$ORDER_ID" 2>/dev/null || echo "")
    if echo "$GET" | grep -q '"pending"' && echo "$GET" | grep -q "$ORDER_ID"; then
        pass "Get order returns correct state and ID"
    else
        fail "Get order failed: $GET"
    fi
else
    fail "Cannot test get order (no order ID from create)"
fi

# Test 5: List orders contains created order
LIST=$(curl -sf "$BASE/api/v1/orders" 2>/dev/null || echo "")
if echo "$LIST" | grep -q "test@example.com"; then
    pass "List orders contains created order"
else
    fail "List orders missing created order: $LIST"
fi

# Test 6: Fail to ship unpaid order
if [ -n "$ORDER_ID" ]; then
    SHIP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/orders/$ORDER_ID/ship" 2>/dev/null || echo "000")
    if [ "$SHIP_CODE" = "422" ]; then
        pass "Cannot ship unpaid order (422)"
    else
        fail "Ship unpaid order returned $SHIP_CODE (expected 422)"
    fi
else
    fail "Cannot test ship without order ID"
fi

# Test 7: Pay order transitions to paid
if [ -n "$ORDER_ID" ]; then
    PAY=$(curl -sf -X POST "$BASE/api/v1/orders/$ORDER_ID/pay" 2>/dev/null || echo "")
    if echo "$PAY" | grep -q '"paid"'; then
        pass "Pay order transitions to paid state"
    else
        fail "Pay order failed: $PAY"
    fi
else
    fail "Cannot test pay without order ID"
fi

# Test 8: Ship paid order transitions to shipped
if [ -n "$ORDER_ID" ]; then
    SHIP=$(curl -sf -X POST "$BASE/api/v1/orders/$ORDER_ID/ship" 2>/dev/null || echo "")
    if echo "$SHIP" | grep -q '"shipped"'; then
        pass "Ship paid order transitions to shipped state"
    else
        fail "Ship order failed: $SHIP"
    fi
else
    fail "Cannot test ship without order ID"
fi

# Test 9: Fail to cancel shipped order
if [ -n "$ORDER_ID" ]; then
    CANCEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/orders/$ORDER_ID/cancel" 2>/dev/null || echo "000")
    if [ "$CANCEL_CODE" = "422" ]; then
        pass "Cannot cancel shipped order (422)"
    else
        fail "Cancel shipped order returned $CANCEL_CODE (expected 422)"
    fi
else
    fail "Cannot test cancel shipped without order ID"
fi

# Test 10: Deliver shipped order
if [ -n "$ORDER_ID" ]; then
    DELIVER=$(curl -sf -X POST "$BASE/api/v1/orders/$ORDER_ID/deliver" 2>/dev/null || echo "")
    if echo "$DELIVER" | grep -q '"delivered"'; then
        pass "Deliver shipped order transitions to delivered state"
    else
        fail "Deliver order failed: $DELIVER"
    fi
else
    fail "Cannot test deliver without order ID"
fi

# Test 11: Refund delivered order
if [ -n "$ORDER_ID" ]; then
    REFUND=$(curl -sf -X POST "$BASE/api/v1/orders/$ORDER_ID/refund" 2>/dev/null || echo "")
    if echo "$REFUND" | grep -q '"refunded"'; then
        pass "Refund delivered order transitions to refunded state"
    else
        fail "Refund order failed: $REFUND"
    fi
else
    fail "Cannot test refund without order ID"
fi

# Test 12: Cancel from pending state
CANCEL_ORDER=$(curl -sf -X POST "$BASE/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d '{"customer_email":"cancel@example.com","items":[{"sku":"PROD-002","qty":1,"price":10.00}],"shipping_address":"789 Cancel Rd","total":10.00}' 2>/dev/null || echo "")
CANCEL_ID=$(echo "$CANCEL_ORDER" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
if [ -n "$CANCEL_ID" ]; then
    CANCEL_RESP=$(curl -sf -X POST "$BASE/api/v1/orders/$CANCEL_ID/cancel" 2>/dev/null || echo "")
    if echo "$CANCEL_RESP" | grep -q '"cancelled"'; then
        pass "Cancel from pending state succeeds"
    else
        fail "Cancel from pending failed: $CANCEL_RESP"
    fi
else
    fail "Cannot test cancel-pending (no order ID)"
fi

# Test 13: Cancel from paid state
PAID_ORDER=$(curl -sf -X POST "$BASE/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d '{"customer_email":"paidcancel@example.com","items":[{"sku":"PROD-003","qty":1,"price":20.00}],"shipping_address":"101 Paid Lane","total":20.00}' 2>/dev/null || echo "")
PAID_ID=$(echo "$PAID_ORDER" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
if [ -n "$PAID_ID" ]; then
    curl -sf -X POST "$BASE/api/v1/orders/$PAID_ID/pay" > /dev/null 2>&1 || true
    PAID_CANCEL=$(curl -sf -X POST "$BASE/api/v1/orders/$PAID_ID/cancel" 2>/dev/null || echo "")
    if echo "$PAID_CANCEL" | grep -q '"cancelled"'; then
        pass "Cancel from paid state succeeds"
    else
        fail "Cancel from paid failed: $PAID_CANCEL"
    fi
else
    fail "Cannot test cancel-paid (no order ID)"
fi

# Test 14: Invalid order (missing required fields)
BAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d '{"customer_email":"bad@example.com"}' 2>/dev/null || echo "000")
if [ "$BAD_CODE" = "400" ] || [ "$BAD_CODE" = "422" ] || [ "$BAD_CODE" = "500" ]; then
    pass "Invalid order (missing items/shipping_address) returns error ($BAD_CODE)"
else
    fail "Invalid order returned $BAD_CODE (expected 400/422/500)"
fi

# Test 15: Cannot refund non-delivered order
FRESH=$(curl -sf -X POST "$BASE/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d '{"customer_email":"fresh@example.com","items":[{"sku":"PROD-004","qty":1,"price":5.00}],"shipping_address":"Fresh St","total":5.00}' 2>/dev/null || echo "")
FRESH_ID=$(echo "$FRESH" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
if [ -n "$FRESH_ID" ]; then
    REFUND_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/orders/$FRESH_ID/refund" 2>/dev/null || echo "000")
    if [ "$REFUND_CODE" = "422" ]; then
        pass "Cannot refund pending order (422)"
    else
        fail "Refund pending order returned $REFUND_CODE (expected 422)"
    fi
else
    fail "Cannot test refund-pending (no order ID)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
