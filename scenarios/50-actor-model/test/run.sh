#!/usr/bin/env bash
# Scenario 50 — Actor Model Tests
# Tests auto-managed actors (order lifecycle) and permanent workers (jobs, events)

set -euo pipefail

PORT=18050
NAMESPACE="${NAMESPACE:-wf-scenario-50}"
BASE_URL="${BASE_URL:-http://localhost:${PORT}}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 (expected=$2 got=$3)"; FAIL=$((FAIL + 1)); }
check() { [ "$3" = "$2" ] && pass "$1" || fail "$1" "$2" "$3"; }
check_not_empty() { [ -n "$2" ] && [ "$2" != "null" ] && pass "$1" || fail "$1" "non-empty" "$2"; }
json_val() { python3 -c "import sys,json; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null; }

echo ""
echo "=== Scenario 50: Actor Model ==="
echo ""

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

# --- Health check ---
echo "--- Health Check ---"
RESP=$(curl -s "$BASE_URL/healthz")
check "healthz status" "ok" "$(echo "$RESP" | json_val status)"
check "healthz scenario" "50-actor-model" "$(echo "$RESP" | json_val scenario)"

# --- Create Order (auto-managed pool, sticky routing) ---
echo ""
echo "--- Create Order (auto-managed actor) ---"
RESP=$(curl -s -X POST "$BASE_URL/api/orders" \
  -H "Content-Type: application/json" \
  -d '{"order_id":"order-001","customer":"Alice","items":["widget","gadget"]}')
check "create order-001 order_id" "order-001" "$(echo "$RESP" | json_val order_id)"
check "create order-001 status" "confirmed" "$(echo "$RESP" | json_val status)"
check "create order-001 customer" "Alice" "$(echo "$RESP" | json_val customer)"
check_not_empty "create order-001 created_at" "$(echo "$RESP" | json_val created_at)"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/orders" \
  -H "Content-Type: application/json" \
  -d '{"order_id":"order-001","customer":"Alice","items":["widget"]}')
check "create order returns 201" "201" "$HTTP_CODE"

# Create a second order for isolation testing
curl -s -X POST "$BASE_URL/api/orders" \
  -H "Content-Type: application/json" \
  -d '{"order_id":"order-002","customer":"Bob","items":["thing"]}' > /dev/null

# --- Get Order Status (same actor via sticky routing) ---
echo ""
echo "--- Get Order Status (actor state persistence) ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/orders/order-001")
check "get order returns 200" "200" "$HTTP_CODE"

RESP=$(curl -s "$BASE_URL/api/orders/order-001")
check "get order status confirmed" "confirmed" "$(echo "$RESP" | json_val status)"
check "get order correct id" "order-001" "$(echo "$RESP" | json_val order_id)"

# --- Cancel Order (state transition) ---
echo ""
echo "--- Cancel Order (actor state transition) ---"
RESP=$(curl -s -X DELETE "$BASE_URL/api/orders/order-001")
check "cancel order status" "cancelled" "$(echo "$RESP" | json_val status)"
check_not_empty "cancel order cancelled_at" "$(echo "$RESP" | json_val cancelled_at)"

# --- Get Cancelled Order (verify state persisted) ---
echo ""
echo "--- Verify Cancelled State Persisted ---"
RESP=$(curl -s "$BASE_URL/api/orders/order-001")
check "cancelled order shows cancelled" "cancelled" "$(echo "$RESP" | json_val status)"

# --- Second Order (different actor instance, should be independent) ---
echo ""
echo "--- Actor Isolation (order-002 unaffected) ---"
RESP=$(curl -s "$BASE_URL/api/orders/order-002")
check "second order still confirmed" "confirmed" "$(echo "$RESP" | json_val status)"
check "second order correct id" "order-002" "$(echo "$RESP" | json_val order_id)"

# --- Submit Job (permanent pool, round-robin) ---
echo ""
echo "--- Submit Job (permanent worker pool) ---"
RESP=$(curl -s -X POST "$BASE_URL/api/jobs" \
  -H "Content-Type: application/json" \
  -d '{"job_id":"job-001","task":"generate-report"}')

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/jobs" \
  -H "Content-Type: application/json" \
  -d '{"job_id":"job-002","task":"send-email"}')
check "job returns 200" "200" "$HTTP_CODE"
check "job has job_id" "job-001" "$(echo "$RESP" | json_val job_id)"
check "job status completed" "completed" "$(echo "$RESP" | json_val status)"
check_not_empty "job has worker identity" "$(echo "$RESP" | json_val worker)"

# --- Fire Event (fire-and-forget via actor_send) ---
echo ""
echo "--- Fire Event (fire-and-forget) ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/events" \
  -H "Content-Type: application/json" \
  -d '{"event_type":"user.signup"}')
check "event returns 202" "202" "$HTTP_CODE"

RESP=$(curl -s -X POST "$BASE_URL/api/events" \
  -H "Content-Type: application/json" \
  -d '{"event_type":"order.shipped"}')
check "event accepted" "True" "$(echo "$RESP" | json_val accepted)"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
