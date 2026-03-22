#!/usr/bin/env bash
# Scenario 48: Payment Processing
# Tests charge lifecycle (pending→captured→refunded) and subscription lifecycle (active→canceled).
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:18048}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 48: Payment Processing ==="
echo ""

# Test 1: Health check
RESULT=$(curl -s "$BASE_URL/healthz")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$STATUS" = "ok" ] && pass "Health check returns ok" || fail "Health check failed (got: $STATUS)"

SCENARIO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scenario',''))" 2>/dev/null || echo "")
[ "$SCENARIO" = "48-payment-processing" ] && pass "Health check identifies scenario 48" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# Test 2: Init DB
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/internal/init-db")
[ "$HTTP_CODE" = "200" ] && pass "init-db returns 200" || fail "init-db returned $HTTP_CODE (expected 200)"

# ----------------------------------------------------------------
# Charge Lifecycle Tests
# ----------------------------------------------------------------

# Test 3: Create a charge
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/charges" \
  -H "Content-Type: application/json" \
  -d '{"amount":50.00,"currency":"USD","description":"Test charge","customer_id":"cust-001"}')
CHARGE_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
[ -n "$CHARGE_ID" ] && [ "$CHARGE_ID" != "null" ] && pass "Create charge returns ID" || fail "Create charge failed (got: $RESULT)"

CHARGE_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$CHARGE_STATUS" = "pending" ] && pass "New charge status is pending" || fail "New charge status is not pending (got: $CHARGE_STATUS)"

CHARGE_AMOUNT=$(echo "$RESULT" | python3 -c "import sys,json; v=json.load(sys.stdin).get('amount',''); print(float(v) if v != '' else '')" 2>/dev/null || echo "")
[ "$CHARGE_AMOUNT" = "50.0" ] && pass "Charge amount stored correctly (50.0)" || fail "Charge amount mismatch (got: $CHARGE_AMOUNT)"

# Test 4: Get charge by ID
RESULT=$(curl -s "$BASE_URL/api/v1/charges/$CHARGE_ID")
FETCHED_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$FETCHED_STATUS" = "pending" ] && pass "Get charge returns pending status" || fail "Get charge status mismatch (got: $FETCHED_STATUS)"

# Test 5: Get non-existent charge returns 404
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/v1/charges/ch-does-not-exist")
[ "$HTTP_CODE" = "404" ] && pass "Get non-existent charge returns 404" || fail "Get non-existent charge returned $HTTP_CODE (expected 404)"

# Test 6: Refund pending charge should fail (must be captured first)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/v1/charges/$CHARGE_ID/refund" \
  -H "Content-Type: application/json" -d '{}')
[ "$HTTP_CODE" = "409" ] && pass "Refund pending charge returns 409" || fail "Refund pending charge returned $HTTP_CODE (expected 409)"

# Test 7: Capture the charge
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/charges/$CHARGE_ID/capture" \
  -H "Content-Type: application/json" -d '{}')
CAPTURED_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$CAPTURED_STATUS" = "captured" ] && pass "Charge transitions to captured" || fail "Capture failed (got: $RESULT)"

# Test 8: Capture again should fail
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/v1/charges/$CHARGE_ID/capture" \
  -H "Content-Type: application/json" -d '{}')
[ "$HTTP_CODE" = "409" ] && pass "Double capture returns 409" || fail "Double capture returned $HTTP_CODE (expected 409)"

# Test 9: Verify captured status persists
RESULT=$(curl -s "$BASE_URL/api/v1/charges/$CHARGE_ID")
PERSISTED_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$PERSISTED_STATUS" = "captured" ] && pass "Captured status persists in DB" || fail "Captured status not persisted (got: $PERSISTED_STATUS)"

# Test 10: Refund the captured charge
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/charges/$CHARGE_ID/refund" \
  -H "Content-Type: application/json" -d '{}')
REFUNDED_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$REFUNDED_STATUS" = "refunded" ] && pass "Charge transitions to refunded" || fail "Refund failed (got: $RESULT)"

# Test 11: Refund again should fail
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/v1/charges/$CHARGE_ID/refund" \
  -H "Content-Type: application/json" -d '{}')
[ "$HTTP_CODE" = "409" ] && pass "Double refund returns 409" || fail "Double refund returned $HTTP_CODE (expected 409)"

# Test 12: Final charge state is refunded
RESULT=$(curl -s "$BASE_URL/api/v1/charges/$CHARGE_ID")
FINAL_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$FINAL_STATUS" = "refunded" ] && pass "Final charge state is refunded" || fail "Final charge state mismatch (got: $FINAL_STATUS)"

# ----------------------------------------------------------------
# Subscription Lifecycle Tests
# ----------------------------------------------------------------

# Test 13: Create a subscription
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/subscriptions" \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"cust-001","plan":"pro","amount":29.99,"currency":"USD","interval":"monthly"}')
SUB_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
[ -n "$SUB_ID" ] && [ "$SUB_ID" != "null" ] && pass "Create subscription returns ID" || fail "Create subscription failed (got: $RESULT)"

SUB_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$SUB_STATUS" = "active" ] && pass "New subscription status is active" || fail "New subscription status is not active (got: $SUB_STATUS)"

SUB_PLAN=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('plan',''))" 2>/dev/null || echo "")
[ "$SUB_PLAN" = "pro" ] && pass "Subscription plan stored correctly" || fail "Subscription plan mismatch (got: $SUB_PLAN)"

# Test 14: Get subscription by ID
RESULT=$(curl -s "$BASE_URL/api/v1/subscriptions/$SUB_ID")
FETCHED_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$FETCHED_STATUS" = "active" ] && pass "Get subscription returns active status" || fail "Get subscription status mismatch (got: $FETCHED_STATUS)"

# Test 15: Get non-existent subscription returns 404
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/v1/subscriptions/sub-does-not-exist")
[ "$HTTP_CODE" = "404" ] && pass "Get non-existent subscription returns 404" || fail "Get non-existent subscription returned $HTTP_CODE (expected 404)"

# Test 16: Cancel the subscription
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/subscriptions/$SUB_ID/cancel" \
  -H "Content-Type: application/json" -d '{}')
CANCELED_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$CANCELED_STATUS" = "canceled" ] && pass "Subscription transitions to canceled" || fail "Cancel failed (got: $RESULT)"

# Test 17: Cancel again should fail
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/v1/subscriptions/$SUB_ID/cancel" \
  -H "Content-Type: application/json" -d '{}')
[ "$HTTP_CODE" = "409" ] && pass "Double cancel returns 409" || fail "Double cancel returned $HTTP_CODE (expected 409)"

# Test 18: Final subscription state is canceled
RESULT=$(curl -s "$BASE_URL/api/v1/subscriptions/$SUB_ID")
FINAL_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$FINAL_STATUS" = "canceled" ] && pass "Final subscription state is canceled" || fail "Final subscription state mismatch (got: $FINAL_STATUS)"

# Test 19: Second charge with different amount
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/charges" \
  -H "Content-Type: application/json" \
  -d '{"amount":150.00,"currency":"EUR","description":"Large charge","customer_id":"cust-002"}')
CHARGE2_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
CHARGE2_CURRENCY=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('currency',''))" 2>/dev/null || echo "")
[ -n "$CHARGE2_ID" ] && pass "Second charge created" || fail "Second charge creation failed"
[ "$CHARGE2_CURRENCY" = "EUR" ] && pass "Second charge currency is EUR" || fail "Second charge currency mismatch (got: $CHARGE2_CURRENCY)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
