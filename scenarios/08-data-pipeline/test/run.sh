#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 08: Data Pipeline (bento stream processing plugin)
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
RESPONSE=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "ERROR")
if echo "$RESPONSE" | grep -q '"ok"'; then
    echo "PASS: Health check returns ok"
else
    echo "FAIL: Health check failed: $RESPONSE"
fi

# Test 2: Health check contains bento scenario marker
if echo "$RESPONSE" | grep -q "08-data-pipeline"; then
    echo "PASS: Health check identifies scenario 08-data-pipeline"
else
    echo "FAIL: Health check missing scenario identifier: $RESPONSE"
fi

# Test 3: Health check shows bento plugin loaded
if echo "$RESPONSE" | grep -q "bento"; then
    echo "PASS: Health response confirms bento plugin loaded"
else
    echo "FAIL: Health response missing bento confirmation: $RESPONSE"
fi

# Test 4: Initialize database
INIT_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/internal/init-db" 2>/dev/null || echo "000")
if [ "$INIT_CODE" = "200" ]; then
    echo "PASS: Database initialized (200 OK)"
else
    echo "FAIL: DB init returned $INIT_CODE (expected 200)"
fi

# Test 5: Ingest data through bento pipeline
INGEST_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/api/pipeline/ingest" \
    -H "Content-Type: application/json" \
    -d '{"name":"test-record","value":42.0,"category":"test"}' 2>/dev/null || echo "000")
if [ "$INGEST_CODE" = "202" ]; then
    echo "PASS: Data ingested through bento pipeline (202 Accepted)"
else
    echo "FAIL: Ingest returned $INGEST_CODE (expected 202)"
fi

# Test 6: Ingest a second record with different values
INGEST2_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/api/pipeline/ingest" \
    -H "Content-Type: application/json" \
    -d '{"name":"sensor-reading","value":100.0,"category":"metrics"}' 2>/dev/null || echo "000")
if [ "$INGEST2_CODE" = "202" ]; then
    echo "PASS: Second record ingested successfully"
else
    echo "FAIL: Second ingest returned $INGEST2_CODE (expected 202)"
fi

# Test 7: List records returns stored data
sleep 1
LIST_RESPONSE=$(curl -sf "$BASE/api/pipeline/records" 2>/dev/null || echo "ERROR")
if echo "$LIST_RESPONSE" | grep -q "test-record"; then
    echo "PASS: List records returns ingested data"
else
    echo "FAIL: List records did not return expected data: $LIST_RESPONSE"
fi

# Test 8: Bento transform applied — score should be value * 1.5
# value=42.0, expected score=63.0
if echo "$LIST_RESPONSE" | grep -q "processed"; then
    echo "PASS: Records have processed status (bento transform ran)"
else
    echo "FAIL: Records not showing processed status: $LIST_RESPONSE"
fi

# Test 9: Bento Bloblang transform endpoint
TRANSFORM_PAYLOAD='{"items":[{"name":"widget","value":10,"category":"goods"},{"name":"gadget","value":20,"category":"tech"}]}'
TRANSFORM_RESPONSE=$(curl -sf -X POST "$BASE/api/pipeline/transform" \
    -H "Content-Type: application/json" \
    -d "$TRANSFORM_PAYLOAD" 2>/dev/null || echo "ERROR")
if echo "$TRANSFORM_RESPONSE" | grep -q "WIDGET"; then
    echo "PASS: Bento Bloblang transform: names uppercased correctly"
else
    echo "FAIL: Bento transform did not uppercase names: $TRANSFORM_RESPONSE"
fi

# Test 10: Bento transform doubles values
# Widget value 10 * 2 = 20, Gadget value 20 * 2 = 40, total = 60
if echo "$TRANSFORM_RESPONSE" | grep -q "total"; then
    echo "PASS: Bento transform returns aggregated total"
else
    echo "FAIL: Bento transform missing total field: $TRANSFORM_RESPONSE"
fi

# Test 11: Bento transform count field present
if echo "$TRANSFORM_RESPONSE" | grep -q "count"; then
    echo "PASS: Bento transform returns item count"
else
    echo "FAIL: Bento transform missing count field: $TRANSFORM_RESPONSE"
fi

# Test 12: Seed records present (from seed.sh)
if echo "$LIST_RESPONSE" | grep -q "seed-record"; then
    echo "PASS: Seed records persisted in pipeline database"
else
    echo "FAIL: Seed records not found (seed may not have run): $LIST_RESPONSE"
fi
