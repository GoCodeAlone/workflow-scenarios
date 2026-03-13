#!/usr/bin/env bash
# Scenario 55: Datadog Integration
# Tests workflow-plugin-datadog step types against a mock Datadog API server.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:18055}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 55: Datadog Integration ==="
echo ""

# Test 1: Health check
RESULT=$(curl -s "$BASE_URL/healthz")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$STATUS" = "ok" ] && pass "Health check returns ok" || fail "Health check failed (got: $STATUS)"

SCENARIO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scenario',''))" 2>/dev/null || echo "")
[ "$SCENARIO" = "55-datadog-integration" ] && pass "Health check identifies scenario 55" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# ----------------------------------------------------------------
# Metric Tests
# ----------------------------------------------------------------

# Test 3: Submit metric
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/datadog/metric" \
  -H "Content-Type: application/json" \
  -d '{"metric":"cpu.usage","value":"42.5","type":"gauge"}')
SUBMITTED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('submitted',''))" 2>/dev/null || echo "")
[ "$SUBMITTED" = "True" ] && pass "Submit metric returns submitted=true" || fail "Submit metric failed (got: $SUBMITTED, full: $RESULT)"

METRIC_NAME=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('metric',''))" 2>/dev/null || echo "")
[ "$METRIC_NAME" = "cpu.usage" ] && pass "Submit metric returns correct metric name" || fail "Submit metric name mismatch (got: $METRIC_NAME)"

# ----------------------------------------------------------------
# Event Tests
# ----------------------------------------------------------------

# Test 5: Create event
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/datadog/event" \
  -H "Content-Type: application/json" \
  -d '{"title":"Deploy v1.2","text":"Deployed to production"}')
EVENT_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',0))" 2>/dev/null || echo "0")
EVENT_TITLE=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title',''))" 2>/dev/null || echo "")
[ "$EVENT_ID" != "0" ] && [ "$EVENT_ID" != "" ] && pass "Create event returns non-zero id" || fail "Create event id invalid (got: $EVENT_ID, full: $RESULT)"
[ "$EVENT_TITLE" = "Deploy v1.2" ] && pass "Create event returns correct title" || fail "Create event title mismatch (got: $EVENT_TITLE)"

# Test 7: Get event by ID
RESULT=$(curl -s "$BASE_URL/api/v1/datadog/event/1234567890")
FOUND=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('found',''))" 2>/dev/null || echo "")
GET_TITLE=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title',''))" 2>/dev/null || echo "")
[ "$FOUND" = "True" ] && pass "Get event returns found=true" || fail "Get event found is not true (got: $FOUND, full: $RESULT)"
[ -n "$GET_TITLE" ] && [ "$GET_TITLE" != "None" ] && pass "Get event returns title" || fail "Get event missing title (got: $GET_TITLE)"

# Test 9: List events
RESULT=$(curl -s "$BASE_URL/api/v1/datadog/events")
EVENT_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$EVENT_COUNT" -ge 1 ] 2>/dev/null && pass "List events returns non-empty events array" || fail "List events returned no events (got count: $EVENT_COUNT, full: $RESULT)"

# ----------------------------------------------------------------
# Monitor Tests
# ----------------------------------------------------------------

# Test 10: Create monitor
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/datadog/monitor" \
  -H "Content-Type: application/json" \
  -d '{"name":"CPU Alert","query":"avg(last_5m):avg:cpu.usage{*} > 90","message":"CPU is high"}')
MON_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',0))" 2>/dev/null || echo "0")
MON_NAME=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
[ "$MON_ID" != "0" ] && [ "$MON_ID" != "" ] && pass "Create monitor returns non-zero id" || fail "Create monitor id invalid (got: $MON_ID, full: $RESULT)"
[ "$MON_NAME" = "CPU Alert" ] && pass "Create monitor returns correct name" || fail "Create monitor name mismatch (got: $MON_NAME)"

# Test 12: List monitors
RESULT=$(curl -s "$BASE_URL/api/v1/datadog/monitors")
MON_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$MON_COUNT" -ge 1 ] 2>/dev/null && pass "List monitors returns non-empty monitors array" || fail "List monitors returned no monitors (got count: $MON_COUNT, full: $RESULT)"

# ----------------------------------------------------------------
# Dashboard Tests
# ----------------------------------------------------------------

# Test 13: Create dashboard
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/datadog/dashboard" \
  -H "Content-Type: application/json" \
  -d '{"title":"Test Dashboard","layout_type":"ordered","description":"My dashboard"}')
DASH_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
DASH_TITLE=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title',''))" 2>/dev/null || echo "")
[ -n "$DASH_ID" ] && [ "$DASH_ID" != "None" ] && pass "Create dashboard returns id" || fail "Create dashboard id invalid (got: $DASH_ID, full: $RESULT)"
[ "$DASH_TITLE" = "Test Dashboard" ] && pass "Create dashboard returns correct title" || fail "Create dashboard title mismatch (got: $DASH_TITLE)"

# Test 15: List dashboards
RESULT=$(curl -s "$BASE_URL/api/v1/datadog/dashboards")
DASH_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$DASH_COUNT" -ge 1 ] 2>/dev/null && pass "List dashboards returns non-empty dashboards array" || fail "List dashboards returned no dashboards (got count: $DASH_COUNT, full: $RESULT)"

# ----------------------------------------------------------------
# Host Tests
# ----------------------------------------------------------------

# Test 16: List hosts
RESULT=$(curl -s "$BASE_URL/api/v1/datadog/hosts")
HOST_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$HOST_COUNT" -ge 1 ] 2>/dev/null && pass "List hosts returns non-empty hosts array" || fail "List hosts returned no hosts (got count: $HOST_COUNT, full: $RESULT)"

# ----------------------------------------------------------------
# Log Tests
# ----------------------------------------------------------------

# Test 17: Submit log
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/datadog/log" \
  -H "Content-Type: application/json" \
  -d '{"message":"Application started","service":"myapp","source":"go"}')
LOG_SUBMITTED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('submitted',''))" 2>/dev/null || echo "")
[ "$LOG_SUBMITTED" = "True" ] && pass "Submit log returns submitted=true" || fail "Submit log failed (got: $LOG_SUBMITTED, full: $RESULT)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
