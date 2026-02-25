#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 02: Event-Driven Microservice
# Outputs PASS: or FAIL: lines for each test

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

# Test 2: Publish an event
EVENT_TYPE="order.created"
PUB_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/api/events" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"$EVENT_TYPE\",\"payload\":{\"order_id\":\"test-$(date +%s)\",\"amount\":42.00}}" 2>/dev/null || echo "000")
if [ "$PUB_CODE" = "202" ]; then
    echo "PASS: Event published with 202 Accepted"
else
    echo "FAIL: Event publish returned $PUB_CODE (expected 202)"
fi

# Test 3: Publish a second event type
PUB2_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/api/events" \
    -H "Content-Type: application/json" \
    -d '{"type":"user.signup","payload":{"user_id":"test-user","email":"test@example.com"}}' 2>/dev/null || echo "000")
if [ "$PUB2_CODE" = "202" ]; then
    echo "PASS: Second event type published successfully"
else
    echo "FAIL: Second event publish returned $PUB2_CODE (expected 202)"
fi

# Test 4: List events returns stored events
sleep 1  # Give event pipeline time to process
LIST_RESPONSE=$(curl -sf "$BASE/api/events" 2>/dev/null || echo "ERROR")
if echo "$LIST_RESPONSE" | grep -q "order.created"; then
    echo "PASS: List events returns stored events"
else
    echo "FAIL: List events did not return expected events: $LIST_RESPONSE"
fi

# Test 5: Published event appears in list
if echo "$LIST_RESPONSE" | grep -q "user.signup"; then
    echo "PASS: Both event types appear in event list"
else
    echo "FAIL: Not all event types found in list: $LIST_RESPONSE"
fi

# Test 6: Missing required fields returns error (engine returns 500 on pipeline failure)
BAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/events" \
    -H "Content-Type: application/json" \
    -d '{"type":"incomplete"}' 2>/dev/null)
if [ "$BAD_CODE" = "400" ] || [ "$BAD_CODE" = "422" ] || [ "$BAD_CODE" = "500" ]; then
    echo "PASS: Missing payload field returns error response ($BAD_CODE)"
else
    echo "FAIL: Missing payload returned $BAD_CODE (expected 400, 422, or 500)"
fi

# Test 7: Seed events are present
if echo "$LIST_RESPONSE" | grep -q "seed-001"; then
    echo "PASS: Seed events persisted across test run"
else
    echo "FAIL: Seed events not found (data may not be persisted)"
fi
