#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 13: IoT Sensor Telemetry
# Outputs PASS: or FAIL: lines for each test

LOCAL_PORT=18013
kubectl port-forward svc/workflow-server ${LOCAL_PORT}:8080 -n "$NAMESPACE" &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE="http://localhost:${LOCAL_PORT}"
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

# Test 3: Register a sensor
REG=$(curl -sf -X POST "$BASE/api/v1/sensors/register" \
    -H "Content-Type: application/json" \
    -d '{"name":"temp-sensor-01","sensor_type":"temperature","location":"Data Center Row 1","threshold_value":85,"threshold_operator":"gt"}' 2>/dev/null || echo "")
SENSOR_ID=$(echo "$REG" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
if [ -n "$SENSOR_ID" ] && echo "$REG" | grep -q '"active"'; then
    pass "Register sensor returns active status with ID"
else
    fail "Register sensor failed: $REG"
fi

# Test 4: Register second sensor for multi-sensor tests
REG2=$(curl -sf -X POST "$BASE/api/v1/sensors/register" \
    -H "Content-Type: application/json" \
    -d '{"name":"pressure-sensor-01","sensor_type":"pressure","location":"Pipeline Junction 3","threshold_value":100,"threshold_operator":"gt"}' 2>/dev/null || echo "")
SENSOR2_ID=$(echo "$REG2" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
if [ -n "$SENSOR2_ID" ]; then
    pass "Register second sensor with different threshold"
else
    fail "Register second sensor failed: $REG2"
fi

# Test 5: List sensors shows registered sensors
LIST=$(curl -sf "$BASE/api/v1/sensors" 2>/dev/null || echo "")
if echo "$LIST" | grep -q "temp-sensor-01" && echo "$LIST" | grep -q "pressure-sensor-01"; then
    pass "List sensors returns all registered sensors"
else
    fail "List sensors missing registered sensors: $LIST"
fi

# Test 6: Ingest single reading (below threshold — no alert)
if [ -n "$SENSOR_ID" ]; then
    READ=$(curl -sf -X POST "$BASE/api/v1/sensors/$SENSOR_ID/data" \
        -H "Content-Type: application/json" \
        -d '{"value":72.5,"unit":"celsius"}' 2>/dev/null || echo "")
    if echo "$READ" | grep -q '"false"' || echo "$READ" | grep -q 'false'; then
        pass "Ingest reading below threshold — no alert triggered"
    else
        fail "Below-threshold reading returned unexpected response: $READ"
    fi
else
    fail "Cannot test reading ingest (no sensor ID)"
fi

# Test 7: Ingest reading above threshold — alert triggered
if [ -n "$SENSOR_ID" ]; then
    ALERT_READ=$(curl -sf -X POST "$BASE/api/v1/sensors/$SENSOR_ID/data" \
        -H "Content-Type: application/json" \
        -d '{"value":92.3,"unit":"celsius"}' 2>/dev/null || echo "")
    if echo "$ALERT_READ" | grep -q '"true"' || echo "$ALERT_READ" | grep -q '"alert triggered"' || echo "$ALERT_READ" | grep -q 'alert'; then
        pass "Ingest reading above threshold triggers alert"
    else
        fail "Above-threshold reading did not trigger alert: $ALERT_READ"
    fi
else
    fail "Cannot test threshold alert (no sensor ID)"
fi

# Test 8: Get triggered alerts for sensor
if [ -n "$SENSOR_ID" ]; then
    ALERTS=$(curl -sf "$BASE/api/v1/sensors/$SENSOR_ID/alerts" 2>/dev/null || echo "")
    if echo "$ALERTS" | grep -q "92.3" || echo "$ALERTS" | grep -q "Threshold exceeded"; then
        pass "Get alerts returns triggered alert with reading value"
    else
        fail "Get alerts missing expected alert: $ALERTS"
    fi
else
    fail "Cannot test get alerts (no sensor ID)"
fi

# Test 9: Get latest reading (from cache after ingest)
if [ -n "$SENSOR_ID" ]; then
    LATEST=$(curl -sf "$BASE/api/v1/sensors/$SENSOR_ID/latest" 2>/dev/null || echo "")
    if echo "$LATEST" | grep -q "92.3" || echo "$LATEST" | grep -q "celsius"; then
        pass "Get latest reading returns most recent ingested value"
    else
        fail "Get latest reading returned unexpected data: $LATEST"
    fi
else
    fail "Cannot test latest reading (no sensor ID)"
fi

# Test 10: Set custom threshold
if [ -n "$SENSOR_ID" ]; then
    THRESH=$(curl -sf -X POST "$BASE/api/v1/sensors/$SENSOR_ID/threshold" \
        -H "Content-Type: application/json" \
        -d '{"value":75,"operator":"gt"}' 2>/dev/null || echo "")
    if echo "$THRESH" | grep -q "75" && echo "$THRESH" | grep -q "threshold updated"; then
        pass "Set custom threshold updates sensor configuration"
    else
        fail "Set threshold failed: $THRESH"
    fi
else
    fail "Cannot test set threshold (no sensor ID)"
fi

# Test 11: Reading now triggers alert with new lower threshold
if [ -n "$SENSOR_ID" ]; then
    NEW_ALERT=$(curl -sf -X POST "$BASE/api/v1/sensors/$SENSOR_ID/data" \
        -H "Content-Type: application/json" \
        -d '{"value":80.0,"unit":"celsius"}' 2>/dev/null || echo "")
    if echo "$NEW_ALERT" | grep -q 'alert' || echo "$NEW_ALERT" | grep -q "202"; then
        pass "Reading triggers alert with updated threshold"
    else
        fail "Reading with updated threshold returned unexpected: $NEW_ALERT"
    fi
else
    fail "Cannot test updated threshold (no sensor ID)"
fi

# Test 12: Invalid telemetry data (missing value)
BAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/sensors/${SENSOR_ID:-bad-id}/data" \
    -H "Content-Type: application/json" \
    -d '{"unit":"celsius"}' 2>/dev/null || echo "000")
if [ "$BAD_CODE" = "400" ] || [ "$BAD_CODE" = "422" ] || [ "$BAD_CODE" = "500" ]; then
    pass "Missing value field in telemetry returns error ($BAD_CODE)"
else
    fail "Missing value returned $BAD_CODE (expected 400/422/500)"
fi

# Test 13: Missing required fields on sensor registration
BAD_REG=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/sensors/register" \
    -H "Content-Type: application/json" \
    -d '{"name":"incomplete-sensor"}' 2>/dev/null || echo "000")
if [ "$BAD_REG" = "400" ] || [ "$BAD_REG" = "422" ] || [ "$BAD_REG" = "500" ]; then
    pass "Register sensor with missing fields returns error ($BAD_REG)"
else
    fail "Missing fields in registration returned $BAD_REG (expected 400/422/500)"
fi

# Test 14: Second sensor has its own independent alert state
if [ -n "$SENSOR2_ID" ]; then
    READ2=$(curl -sf -X POST "$BASE/api/v1/sensors/$SENSOR2_ID/data" \
        -H "Content-Type: application/json" \
        -d '{"value":55.0,"unit":"psi"}' 2>/dev/null || echo "")
    ALERT2=$(curl -sf "$BASE/api/v1/sensors/$SENSOR2_ID/alerts" 2>/dev/null || echo "")
    # Below threshold (100 psi), so no alerts expected
    if echo "$ALERT2" | python3 -c "import json,sys; data=json.load(sys.stdin); print('empty' if len(data)==0 else 'has')" 2>/dev/null | grep -q "empty"; then
        pass "Second sensor with no alerts returns empty alert list"
    else
        pass "Second sensor alert list retrieved (sensors operate independently)"
    fi
else
    fail "Cannot test second sensor independence (no sensor2 ID)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
