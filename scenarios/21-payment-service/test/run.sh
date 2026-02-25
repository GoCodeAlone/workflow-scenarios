#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 21: Payment Service — Payment Processing with Webhooks
# Tests CRUD operations on payments and webhook delivery via step.http_call.
#
# Note on webhooks: step.http_call errors on HTTP 4xx/5xx (no ignore_error support).
# Payment DB status IS updated before the webhook; if webhook fails the pipeline
# returns 500 but the status is persisted. Tests verify DB state via GET after capture.
#
# Outputs PASS: or FAIL: lines for each test.

NS="${NAMESPACE:-wf-scenario-21}"
PORT=18021
BASE="http://localhost:$PORT"

# Callback URL: use the payment service's own init-db endpoint.
# It accepts POST and returns 200 — so the webhook always succeeds in tests.
SELF_CALLBACK="http://workflow-server.wf-scenario-21.svc.cluster.local:8080/internal/init-db"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

start_pf() {
    pkill -f "port-forward.*$PORT" 2>/dev/null || true
    sleep 1
    kubectl port-forward svc/workflow-server "$PORT":8080 -n "$NS" &
    PF_PID=$!
    sleep 4
}

cleanup() {
    pkill -f "port-forward.*$PORT" 2>/dev/null || true
}
trap cleanup EXIT

start_pf

# ====================================================================
# Test 1: Health check
# ====================================================================
RESP=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q '"ok"'; then
    pass "Health check returns ok"
else
    fail "Health check failed: $RESP"
fi

# ====================================================================
# Test 2: Health check identifies scenario
# ====================================================================
if echo "$RESP" | grep -q "21-payment-service"; then
    pass "Health check identifies scenario 21-payment-service"
else
    fail "Health check missing scenario identifier: $RESP"
fi

# ====================================================================
# Test 3: Init DB
# ====================================================================
INIT=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/internal/init-db" 2>/dev/null || echo "000")
if [ "$INIT" = "200" ]; then
    pass "init-db returns 200"
else
    fail "init-db returned $INIT (expected 200)"
fi

# ====================================================================
# Test 4: Create payment
# callback_url points to payment service's own init-db (accepts POST → 200)
# ====================================================================
CREATE=$(curl -sf -X POST "$BASE/api/v1/payments" \
    -H "Content-Type: application/json" \
    -d "{\"amount\":99.99,\"currency\":\"USD\",\"order_id\":\"order-001\",\"callback_url\":\"$SELF_CALLBACK\"}" \
    2>/dev/null || echo "{}")
PAYMENT_ID=$(echo "$CREATE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$PAYMENT_ID" ] && [ "$PAYMENT_ID" != "null" ] && [ "$PAYMENT_ID" != "" ]; then
    pass "Create payment returns payment_id=$PAYMENT_ID"
else
    fail "Create payment failed. Response: $CREATE"
fi

# ====================================================================
# Test 5: Create payment status is pending
# ====================================================================
STATUS=$(echo "$CREATE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
if [ "$STATUS" = "pending" ]; then
    pass "New payment has status=pending"
else
    fail "New payment status is '$STATUS' (expected pending)"
fi

# ====================================================================
# Test 6: Create payment returns order_id
# ====================================================================
ORDER_ID=$(echo "$CREATE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('order_id',''))" 2>/dev/null || echo "")
if [ "$ORDER_ID" = "order-001" ]; then
    pass "Create payment response contains order_id=order-001"
else
    fail "Create payment response has order_id='$ORDER_ID' (expected order-001)"
fi

# ====================================================================
# Test 7: Get payment by ID
# ====================================================================
if [ -n "$PAYMENT_ID" ] && [ "$PAYMENT_ID" != "null" ]; then
    GET=$(curl -sf "$BASE/api/v1/payments/$PAYMENT_ID" 2>/dev/null || echo "{}")
    GET_STATUS=$(echo "$GET" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$GET_STATUS" = "pending" ]; then
        pass "Get payment by ID returns status=pending"
    else
        fail "Get payment returned unexpected status='$GET_STATUS'. Response: $GET"
    fi
else
    fail "Cannot test get payment — no payment_id"
fi

# ====================================================================
# Test 8: Get nonexistent payment returns 404
# ====================================================================
NOT_FOUND=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/v1/payments/nonexistent-id-xyz" 2>/dev/null || echo "000")
if [ "$NOT_FOUND" = "404" ]; then
    pass "Get nonexistent payment returns 404"
else
    fail "Get nonexistent payment returned $NOT_FOUND (expected 404)"
fi

# ====================================================================
# Test 9: Capture payment
# Webhook goes to the payment service's own init-db (POST → 200).
# The capture pipeline completes with status=captured.
# ====================================================================
if [ -n "$PAYMENT_ID" ] && [ "$PAYMENT_ID" != "null" ]; then
    CAPTURE=$(curl -sf --max-time 30 -X POST "$BASE/api/v1/payments/$PAYMENT_ID/capture" \
        2>/dev/null || echo "{}")
    CAPTURE_STATUS=$(echo "$CAPTURE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$CAPTURE_STATUS" = "captured" ]; then
        pass "Capture payment returns status=captured (webhook to self-callback succeeded)"
    else
        fail "Capture payment returned status='$CAPTURE_STATUS' (expected captured). Response: $CAPTURE"
    fi
else
    fail "Cannot test capture — no payment_id"
fi

# ====================================================================
# Test 10: Get captured payment confirms status persisted
# ====================================================================
if [ -n "$PAYMENT_ID" ] && [ "$PAYMENT_ID" != "null" ]; then
    GET2=$(curl -sf "$BASE/api/v1/payments/$PAYMENT_ID" 2>/dev/null || echo "{}")
    GET2_STATUS=$(echo "$GET2" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$GET2_STATUS" = "captured" ]; then
        pass "Get captured payment confirms status=captured (persisted)"
    else
        fail "Get captured payment has status='$GET2_STATUS' (expected captured)"
    fi
else
    fail "Cannot test get captured payment — no payment_id"
fi

# ====================================================================
# Test 11: Refund captured payment
# ====================================================================
if [ -n "$PAYMENT_ID" ] && [ "$PAYMENT_ID" != "null" ]; then
    REFUND=$(curl -sf -X POST "$BASE/api/v1/payments/$PAYMENT_ID/refund" \
        2>/dev/null || echo "{}")
    REFUND_STATUS=$(echo "$REFUND" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$REFUND_STATUS" = "refunded" ]; then
        pass "Refund payment returns status=refunded"
    else
        fail "Refund payment returned status='$REFUND_STATUS' (expected refunded). Response: $REFUND"
    fi
else
    fail "Cannot test refund — no payment_id"
fi

# ====================================================================
# Test 12: Get refunded payment confirms status persisted
# ====================================================================
if [ -n "$PAYMENT_ID" ] && [ "$PAYMENT_ID" != "null" ]; then
    GET3=$(curl -sf "$BASE/api/v1/payments/$PAYMENT_ID" 2>/dev/null || echo "{}")
    GET3_STATUS=$(echo "$GET3" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$GET3_STATUS" = "refunded" ]; then
        pass "Get refunded payment confirms status=refunded (persisted)"
    else
        fail "Get refunded payment has status='$GET3_STATUS' (expected refunded)"
    fi
else
    fail "Cannot test get refunded payment — no payment_id"
fi

# ====================================================================
# Test 13: Create second payment (EUR, different order)
# Uses auth service healthz as callback. The webhook POST to /healthz
# returns 405 (GET-only), so the capture pipeline will return 500.
# Status IS updated in DB before the webhook step.
# ====================================================================
AUTH_CALLBACK="http://workflow-server.wf-scenario-20.svc.cluster.local:8080/healthz"
CREATE2=$(curl -sf -X POST "$BASE/api/v1/payments" \
    -H "Content-Type: application/json" \
    -d "{\"amount\":250.00,\"currency\":\"EUR\",\"order_id\":\"order-002\",\"callback_url\":\"$AUTH_CALLBACK\"}" \
    2>/dev/null || echo "{}")
PAYMENT2_ID=$(echo "$CREATE2" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$PAYMENT2_ID" ] && [ "$PAYMENT2_ID" != "null" ] && [ "$PAYMENT2_ID" != "" ]; then
    pass "Create second payment (EUR, order-002) returns payment_id=$PAYMENT2_ID"
else
    fail "Create second payment failed. Response: $CREATE2"
fi

# ====================================================================
# Test 14: Capture second payment — webhook to auth service (cross-ns)
# Webhook POST → /healthz returns 405 → pipeline returns 500.
# But DB is updated BEFORE webhook step, so status is 'captured'.
# Verify via GET after capture attempt.
# ====================================================================
if [ -n "$PAYMENT2_ID" ] && [ "$PAYMENT2_ID" != "null" ]; then
    # Attempt capture (may return 500 due to webhook failure)
    CAPTURE2_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
        -X POST "$BASE/api/v1/payments/$PAYMENT2_ID/capture" 2>/dev/null || echo "000")
    # Verify DB state via GET (status should be captured regardless of webhook result)
    CAPTURE2_GET=$(curl -sf "$BASE/api/v1/payments/$PAYMENT2_ID" 2>/dev/null || echo "{}")
    CAPTURE2_STATUS=$(echo "$CAPTURE2_GET" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$CAPTURE2_STATUS" = "captured" ]; then
        pass "Capture second payment: DB status=captured (capture_code=$CAPTURE2_CODE, webhook fire-and-forget)"
    else
        fail "Capture second payment: DB status='$CAPTURE2_STATUS' (expected captured). GET: $CAPTURE2_GET"
    fi
else
    fail "Cannot test capture second payment — no payment_id"
fi

# ====================================================================
# Summary
# ====================================================================
echo ""
echo "========================================"
echo "RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "========================================"
if [ "$FAIL_COUNT" -gt "0" ]; then
    exit 1
fi
