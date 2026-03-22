#!/usr/bin/env bash
# Scenario 49: Security Scanning — test script
# Verifies scan steps with mock SecurityScannerProvider

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${BASE_URL:-http://localhost:18049}"

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1"; }

# ----------------------------------------------------------------
# Wait for health
# ----------------------------------------------------------------
echo "=== Waiting for service ==="
for i in $(seq 1 30); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/healthz" 2>/dev/null || echo "000")
  [ "$STATUS" = "200" ] && break
  sleep 1
done

HEALTH=$(curl -s "$BASE_URL/healthz")
SCENARIO=$(echo "$HEALTH" | jq -r '.scenario // empty')
if [ "$SCENARIO" = "49-security-scanning" ]; then
  pass "health check returns correct scenario"
else
  fail "health check: expected scenario=49-security-scanning, got $SCENARIO"
fi

# ----------------------------------------------------------------
# Test 1: SAST scan — should pass (threshold=high, findings=medium+low)
# ----------------------------------------------------------------
echo ""
echo "=== Test 1: SAST scan (should pass) ==="
SAST_RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/scan/sast")
SAST_STATUS=$(echo "$SAST_RESP" | tail -1)
SAST_BODY=$(echo "$SAST_RESP" | sed '$d')

if [ "$SAST_STATUS" = "200" ]; then
  pass "SAST scan returns 200"
else
  fail "SAST scan: expected 200, got $SAST_STATUS"
fi

SAST_PASSED=$(echo "$SAST_BODY" | jq -r '.passed // empty')
if [ "$SAST_PASSED" = "true" ]; then
  pass "SAST scan gate passed"
else
  fail "SAST scan gate: expected true, got $SAST_PASSED"
fi

SAST_SCANNER=$(echo "$SAST_BODY" | jq -r '.scanner // empty')
if [ "$SAST_SCANNER" = "semgrep" ]; then
  pass "SAST scanner = semgrep"
else
  fail "SAST scanner: expected semgrep, got $SAST_SCANNER"
fi

SAST_FINDINGS=$(echo "$SAST_BODY" | jq '.findings | length')
if [ "$SAST_FINDINGS" = "2" ]; then
  pass "SAST findings count = 2"
else
  fail "SAST findings count: expected 2, got $SAST_FINDINGS"
fi

SAST_MEDIUM=$(echo "$SAST_BODY" | jq '.summary.medium // 0')
SAST_LOW=$(echo "$SAST_BODY" | jq '.summary.low // 0')
if [ "$SAST_MEDIUM" = "1" ] && [ "$SAST_LOW" = "1" ]; then
  pass "SAST summary: 1 medium, 1 low"
else
  fail "SAST summary: expected medium=1 low=1, got medium=$SAST_MEDIUM low=$SAST_LOW"
fi

# ----------------------------------------------------------------
# Test 2: SAST scan strict — should fail (threshold=low, has medium+low)
# ----------------------------------------------------------------
echo ""
echo "=== Test 2: SAST scan strict (should fail gate) ==="
SAST_STRICT_RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/scan/sast-strict")
SAST_STRICT_STATUS=$(echo "$SAST_STRICT_RESP" | tail -1)

if [ "$SAST_STRICT_STATUS" = "500" ]; then
  pass "SAST strict scan returns 500 (gate failed)"
else
  fail "SAST strict scan: expected 500, got $SAST_STRICT_STATUS"
fi

SAST_STRICT_BODY=$(echo "$SAST_STRICT_RESP" | sed '$d')
if echo "$SAST_STRICT_BODY" | grep -qi "severity gate failed"; then
  pass "SAST strict error mentions severity gate"
else
  fail "SAST strict error: expected 'severity gate failed' message"
fi

# ----------------------------------------------------------------
# Test 3: Container scan — should fail (threshold=high, has critical+high)
# ----------------------------------------------------------------
echo ""
echo "=== Test 3: Container scan (should fail gate) ==="
CONTAINER_RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/scan/container")
CONTAINER_STATUS=$(echo "$CONTAINER_RESP" | tail -1)

if [ "$CONTAINER_STATUS" = "500" ]; then
  pass "Container scan returns 500 (gate failed)"
else
  fail "Container scan: expected 500, got $CONTAINER_STATUS"
fi

CONTAINER_BODY=$(echo "$CONTAINER_RESP" | sed '$d')
if echo "$CONTAINER_BODY" | grep -qi "severity gate failed\|scan_container"; then
  pass "Container scan error message present"
else
  fail "Container scan error: expected gate failure message"
fi

# ----------------------------------------------------------------
# Test 4: Deps scan — should pass (threshold=critical, has high+medium+low)
# ----------------------------------------------------------------
echo ""
echo "=== Test 4: Deps scan (should pass) ==="
DEPS_RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/scan/deps")
DEPS_STATUS=$(echo "$DEPS_RESP" | tail -1)
DEPS_BODY=$(echo "$DEPS_RESP" | sed '$d')

if [ "$DEPS_STATUS" = "200" ]; then
  pass "Deps scan returns 200"
else
  fail "Deps scan: expected 200, got $DEPS_STATUS"
fi

DEPS_PASSED=$(echo "$DEPS_BODY" | jq -r '.passed // empty')
if [ "$DEPS_PASSED" = "true" ]; then
  pass "Deps scan gate passed"
else
  fail "Deps scan gate: expected true, got $DEPS_PASSED"
fi

DEPS_SCANNER=$(echo "$DEPS_BODY" | jq -r '.scanner // empty')
if [ "$DEPS_SCANNER" = "grype" ]; then
  pass "Deps scanner = grype"
else
  fail "Deps scanner: expected grype, got $DEPS_SCANNER"
fi

DEPS_FINDINGS=$(echo "$DEPS_BODY" | jq '.findings | length')
if [ "$DEPS_FINDINGS" = "3" ]; then
  pass "Deps findings count = 3"
else
  fail "Deps findings count: expected 3, got $DEPS_FINDINGS"
fi

DEPS_HIGH=$(echo "$DEPS_BODY" | jq '.summary.high // 0')
DEPS_MEDIUM=$(echo "$DEPS_BODY" | jq '.summary.medium // 0')
DEPS_LOW=$(echo "$DEPS_BODY" | jq '.summary.low // 0')
if [ "$DEPS_HIGH" = "1" ] && [ "$DEPS_MEDIUM" = "1" ] && [ "$DEPS_LOW" = "1" ]; then
  pass "Deps summary: 1 high, 1 medium, 1 low"
else
  fail "Deps summary: expected high=1 medium=1 low=1, got high=$DEPS_HIGH medium=$DEPS_MEDIUM low=$DEPS_LOW"
fi

# Verify specific finding details
DEPS_FIRST_RULE=$(echo "$DEPS_BODY" | jq -r '.findings[0].rule_id // empty')
if [ "$DEPS_FIRST_RULE" = "GHSA-2024-0001" ]; then
  pass "Deps first finding rule_id correct"
else
  fail "Deps first finding: expected GHSA-2024-0001, got $DEPS_FIRST_RULE"
fi

# ----------------------------------------------------------------
# Test 5: Deps scan strict — should fail (threshold=medium, has high+medium)
# ----------------------------------------------------------------
echo ""
echo "=== Test 5: Deps scan strict (should fail gate) ==="
DEPS_STRICT_RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/api/scan/deps-strict")
DEPS_STRICT_STATUS=$(echo "$DEPS_STRICT_RESP" | tail -1)

if [ "$DEPS_STRICT_STATUS" = "500" ]; then
  pass "Deps strict scan returns 500 (gate failed)"
else
  fail "Deps strict scan: expected 500, got $DEPS_STRICT_STATUS"
fi

# ----------------------------------------------------------------
# Summary
# ----------------------------------------------------------------
echo ""
echo "========================================"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "========================================"

[ "$FAIL_COUNT" -eq 0 ]
