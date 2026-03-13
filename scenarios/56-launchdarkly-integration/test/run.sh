#!/usr/bin/env bash
# Scenario 56: LaunchDarkly Integration
# Tests workflow-plugin-launchdarkly step types against a mock LaunchDarkly API server.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:18056}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 56: LaunchDarkly Integration ==="
echo ""

# Test 1: Health check
RESULT=$(curl -s "$BASE_URL/healthz")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$STATUS" = "ok" ] && pass "Health check returns ok" || fail "Health check failed (got: $STATUS)"

SCENARIO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scenario',''))" 2>/dev/null || echo "")
[ "$SCENARIO" = "56-launchdarkly-integration" ] && pass "Health check identifies scenario 56" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# ----------------------------------------------------------------
# Flag Tests
# ----------------------------------------------------------------

# Test 3: Create flag
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/ld/flags/create" \
  -H "Content-Type: application/json" \
  -d '{"projectKey":"default","flagKey":"test-flag-1","name":"Test Flag One","kind":"boolean","description":"A test flag"}')
FLAG_KEY=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")
FLAG_KIND=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('kind',''))" 2>/dev/null || echo "")
[ "$FLAG_KEY" = "test-flag-1" ] && pass "Create flag returns correct key" || fail "Create flag key mismatch (got: $FLAG_KEY)"
[ "$FLAG_KIND" = "boolean" ] && pass "Create flag returns correct kind" || fail "Create flag kind mismatch (got: $FLAG_KIND)"

# Test 5: Get flag
RESULT=$(curl -s "$BASE_URL/api/v1/ld/flags/test-flag-1")
GET_KEY=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")
GET_KIND=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('kind',''))" 2>/dev/null || echo "")
[ "$GET_KEY" = "test-flag-1" ] && pass "Get flag returns correct key" || fail "Get flag key mismatch (got: $GET_KEY)"
[ "$GET_KIND" = "boolean" ] && pass "Get flag returns correct kind" || fail "Get flag kind mismatch (got: $GET_KIND)"

# Test 7: List flags
RESULT=$(curl -s "$BASE_URL/api/v1/ld/flags")
FLAG_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('items',[])))" 2>/dev/null || echo "0")
[ "$FLAG_COUNT" -ge 1 ] && pass "List flags returns non-empty items" || fail "List flags returned no items (got count: $FLAG_COUNT)"

TOTAL_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalCount',0))" 2>/dev/null || echo "0")
[ "$TOTAL_COUNT" -ge 1 ] && pass "List flags has totalCount field" || fail "List flags missing totalCount (got: $TOTAL_COUNT)"

# Test 9: Toggle flag (update)
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/ld/flags/test-flag-1/toggle" \
  -H "Content-Type: application/json" \
  -d '{}')
TOGGLED_ON=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('on',''))" 2>/dev/null || echo "")
TOGGLED_VER=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('_version',0))" 2>/dev/null || echo "0")
[ "$TOGGLED_ON" = "True" ] && pass "Toggle flag sets on to true" || fail "Toggle flag on mismatch (got: $TOGGLED_ON)"
[ "$TOGGLED_VER" -ge 2 ] && pass "Toggle flag increments version" || fail "Toggle flag version not incremented (got: $TOGGLED_VER)"

# Test 11: Delete flag
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/ld/flags/test-flag-1/delete")
DEL_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',0))" 2>/dev/null || echo "0")
[ "$DEL_STATUS" = "204" ] && pass "Delete flag returns 204 status" || fail "Delete flag status mismatch (got: $DEL_STATUS)"

# ----------------------------------------------------------------
# Project Tests
# ----------------------------------------------------------------

# Test 12: Create project
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/ld/projects/create" \
  -H "Content-Type: application/json" \
  -d '{"projectKey":"test-project","name":"Test Project"}')
PROJ_KEY=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")
PROJ_NAME=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
[ "$PROJ_KEY" = "test-project" ] && pass "Create project returns correct key" || fail "Create project key mismatch (got: $PROJ_KEY)"
[ "$PROJ_NAME" = "Test Project" ] && pass "Create project returns correct name" || fail "Create project name mismatch (got: $PROJ_NAME)"

# Test 14: List projects
RESULT=$(curl -s "$BASE_URL/api/v1/ld/projects")
PROJ_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('items',[])))" 2>/dev/null || echo "0")
[ "$PROJ_COUNT" -ge 1 ] && pass "List projects returns non-empty items" || fail "List projects returned no items (got count: $PROJ_COUNT)"

# Test 15: Get project
RESULT=$(curl -s "$BASE_URL/api/v1/ld/projects/my-project")
GET_PROJ_KEY=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")
[ "$GET_PROJ_KEY" = "my-project" ] && pass "Get project returns correct key" || fail "Get project key mismatch (got: $GET_PROJ_KEY)"

# ----------------------------------------------------------------
# Environment Tests
# ----------------------------------------------------------------

# Test 16: List environments
RESULT=$(curl -s "$BASE_URL/api/v1/ld/environments/default")
ENV_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('items',[])))" 2>/dev/null || echo "0")
[ "$ENV_COUNT" -ge 2 ] && pass "List environments returns multiple items" || fail "List environments returned too few items (got count: $ENV_COUNT)"

ENV_KEY=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['items'][0].get('key',''))" 2>/dev/null || echo "")
[ -n "$ENV_KEY" ] && [ "$ENV_KEY" != "null" ] && pass "List environments has key field" || fail "List environments missing key (got: $ENV_KEY)"

# ----------------------------------------------------------------
# Segment Tests
# ----------------------------------------------------------------

# Test 18: Create segment
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/ld/segments/create" \
  -H "Content-Type: application/json" \
  -d '{"projectKey":"default","environmentKey":"production","segmentKey":"vip-users","name":"VIP Users","description":"VIP customer segment"}')
SEG_KEY=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")
SEG_NAME=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
[ "$SEG_KEY" = "vip-users" ] && pass "Create segment returns correct key" || fail "Create segment key mismatch (got: $SEG_KEY)"
[ "$SEG_NAME" = "VIP Users" ] && pass "Create segment returns correct name" || fail "Create segment name mismatch (got: $SEG_NAME)"

# Test 20: List segments
RESULT=$(curl -s "$BASE_URL/api/v1/ld/segments")
SEG_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('items',[])))" 2>/dev/null || echo "0")
[ "$SEG_COUNT" -ge 1 ] && pass "List segments returns non-empty items" || fail "List segments returned no items (got count: $SEG_COUNT)"

SEG_TOTAL=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalCount',0))" 2>/dev/null || echo "0")
[ "$SEG_TOTAL" -ge 1 ] && pass "List segments has totalCount field" || fail "List segments missing totalCount (got: $SEG_TOTAL)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
