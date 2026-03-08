#!/bin/bash
# Scenario 50 — Actor Model Tests
# Tests auto-managed actors (order lifecycle) and permanent workers (jobs, events)

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
PASS=0
FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc (expected=$expected actual=$actual)"
    ((FAIL++))
  fi
}

check_contains() {
  local desc="$1" expected="$2" actual="$3"
  if echo "$actual" | grep -q "$expected"; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc (expected to contain '$expected', got '$actual')"
    ((FAIL++))
  fi
}

check_not_empty() {
  local desc="$1" actual="$2"
  if [ -n "$actual" ] && [ "$actual" != "null" ]; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc (expected non-empty, got '$actual')"
    ((FAIL++))
  fi
}

echo "=== Scenario 50: Actor Model ==="
echo ""

# --- Health check ---
echo "--- Health Check ---"
RESP=$(curl -s "$BASE_URL/healthz")
check "healthz status" "ok" "$(echo "$RESP" | jq -r '.status')"
check "healthz scenario" "50-actor-model" "$(echo "$RESP" | jq -r '.scenario')"

# --- Create Order (auto-managed pool, sticky routing) ---
echo ""
echo "--- Create Order (auto-managed actor) ---"
RESP=$(curl -s -X POST "$BASE_URL/api/orders" \
  -H "Content-Type: application/json" \
  -d '{"order_id":"order-001","customer":"Alice","items":["widget","gadget"]}')
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/orders" \
  -H "Content-Type: application/json" \
  -d '{"order_id":"order-002","customer":"Bob","items":["thing"]}')

check "create order returns 201" "201" "$HTTP_CODE"
check "create order has order_id" "order-001" "$(echo "$RESP" | jq -r '.order_id')"
check "create order status confirmed" "confirmed" "$(echo "$RESP" | jq -r '.status')"
check "create order has customer" "Alice" "$(echo "$RESP" | jq -r '.customer')"
check_not_empty "create order has created_at" "$(echo "$RESP" | jq -r '.created_at')"

# --- Get Order Status (same actor via sticky routing) ---
echo ""
echo "--- Get Order Status (actor state persistence) ---"
RESP=$(curl -s "$BASE_URL/api/orders/order-001")
check "get order status 200" "200" "$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/orders/order-001")"
check "get order returns confirmed" "confirmed" "$(echo "$RESP" | jq -r '.status')"
check "get order returns correct id" "order-001" "$(echo "$RESP" | jq -r '.order_id')"

# --- Cancel Order (state transition) ---
echo ""
echo "--- Cancel Order (actor state transition) ---"
RESP=$(curl -s -X DELETE "$BASE_URL/api/orders/order-001")
check "cancel order status" "cancelled" "$(echo "$RESP" | jq -r '.status')"
check_not_empty "cancel order has cancelled_at" "$(echo "$RESP" | jq -r '.cancelled_at')"

# --- Get Cancelled Order (verify state persisted) ---
echo ""
echo "--- Get Cancelled Order (verify state updated) ---"
RESP=$(curl -s "$BASE_URL/api/orders/order-001")
check "cancelled order shows cancelled" "cancelled" "$(echo "$RESP" | jq -r '.status')"

# --- Second Order (different actor instance) ---
echo ""
echo "--- Second Order (separate actor instance) ---"
RESP=$(curl -s "$BASE_URL/api/orders/order-002")
check "second order is independent" "confirmed" "$(echo "$RESP" | jq -r '.status')"
check "second order correct id" "order-002" "$(echo "$RESP" | jq -r '.order_id')"

# --- Submit Job (permanent pool, round-robin) ---
echo ""
echo "--- Submit Job (permanent worker pool) ---"
RESP=$(curl -s -X POST "$BASE_URL/api/jobs" \
  -H "Content-Type: application/json" \
  -d '{"job_id":"job-001","task":"generate-report"}')
check "job returns 200" "200" "$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/jobs" \
  -H "Content-Type: application/json" \
  -d '{"job_id":"job-002","task":"send-email"}')"
check "job has job_id" "job-001" "$(echo "$RESP" | jq -r '.job_id')"
check "job status completed" "completed" "$(echo "$RESP" | jq -r '.status')"
check_not_empty "job has worker identity" "$(echo "$RESP" | jq -r '.worker')"

# --- Fire Event (fire-and-forget) ---
echo ""
echo "--- Fire Event (fire-and-forget via actor_send) ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/events" \
  -H "Content-Type: application/json" \
  -d '{"event_type":"user.signup"}')
check "event returns 202" "202" "$HTTP_CODE"

RESP=$(curl -s -X POST "$BASE_URL/api/events" \
  -H "Content-Type: application/json" \
  -d '{"event_type":"order.shipped"}')
check "event accepted" "true" "$(echo "$RESP" | jq -r '.accepted')"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
