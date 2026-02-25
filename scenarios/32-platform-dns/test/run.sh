#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 32: Platform DNS
# Tests plan/apply/status lifecycle using the in-memory mock backend.

NS="${NAMESPACE:-wf-scenario-32}"
PORT=18032
BASE="http://localhost:$PORT"

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

echo ""
echo "=== Scenario 32: Platform DNS (in-memory mock backend) ==="
echo ""

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
if echo "$RESP" | grep -q "32-platform-dns"; then
    pass "Health check identifies scenario 32-platform-dns"
else
    fail "Health check missing scenario identifier: $RESP"
fi

# ====================================================================
# Test 3: Plan returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/dns/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/dns/plan returns 200"
else
    fail "POST /api/v1/dns/plan returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 4: Plan response contains changes
# ====================================================================
PLAN_RESP=$(curl -sf -X POST "$BASE/api/v1/dns/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$PLAN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('changes'), list)" 2>/dev/null; then
    pass "Plan response contains changes list"
else
    fail "Plan response missing changes list: $PLAN_RESP"
fi

# ====================================================================
# Test 5: Plan response contains records
# ====================================================================
if echo "$PLAN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('records'), list)" 2>/dev/null; then
    pass "Plan response contains records list"
else
    fail "Plan response missing records list: $PLAN_RESP"
fi

# ====================================================================
# Test 6: Plan contains zone information
# ====================================================================
if echo "$PLAN_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
plan = d.get('plan', {})
assert isinstance(plan, dict), 'plan not a dict'
assert plan.get('zone', {}).get('name') == 'example.com', f'expected zone=example.com, got {plan.get(\"zone\")}'
" 2>/dev/null; then
    pass "Plan response contains zone name=example.com"
else
    fail "Plan response missing zone name: $PLAN_RESP"
fi

# ====================================================================
# Test 7: Plan initial changes mention zone creation
# ====================================================================
if echo "$PLAN_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
changes = d.get('changes', [])
assert len(changes) > 0, 'no changes'
assert any('example.com' in c for c in changes), 'no change mentioning example.com'
" 2>/dev/null; then
    pass "Plan changes mention example.com zone creation"
else
    fail "Plan changes do not mention example.com: $PLAN_RESP"
fi

# ====================================================================
# Test 8: Apply returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/dns/apply" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/dns/apply returns 200"
else
    fail "POST /api/v1/dns/apply returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 9: Apply response status=active
# ====================================================================
APPLY_RESP=$(curl -sf -X POST "$BASE/api/v1/dns/apply" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$APPLY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('status') == 'active'" 2>/dev/null; then
    pass "Apply response status=active"
else
    fail "Apply response status not active: $APPLY_RESP"
fi

# ====================================================================
# Test 10: Apply response contains zoneId
# ====================================================================
if echo "$APPLY_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('zoneId'), 'missing zoneId'
" 2>/dev/null; then
    pass "Apply response contains non-empty zoneId"
else
    fail "Apply response missing zoneId: $APPLY_RESP"
fi

# ====================================================================
# Test 11: Apply response contains records
# ====================================================================
if echo "$APPLY_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
records = d.get('records', [])
assert len(records) >= 3, f'expected 3 records, got {len(records)}'
" 2>/dev/null; then
    pass "Apply response contains 3 DNS records"
else
    fail "Apply response missing records: $APPLY_RESP"
fi

# ====================================================================
# Test 12: Status returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/v1/dns/status" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "GET /api/v1/dns/status returns 200"
else
    fail "GET /api/v1/dns/status returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 13: Status shows active after apply
# ====================================================================
STATUS_RESP=$(curl -sf "$BASE/api/v1/dns/status" 2>/dev/null || echo "")
if echo "$STATUS_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('status') == 'active', f'expected active, got {d.get(\"status\")!r}'
" 2>/dev/null; then
    pass "Status shows status=active after apply"
else
    fail "Status not active after apply: $STATUS_RESP"
fi

# ====================================================================
# Test 14: Plan after apply returns no-changes
# ====================================================================
PLAN2_RESP=$(curl -sf -X POST "$BASE/api/v1/dns/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$PLAN2_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
changes = d.get('changes', [])
assert len(changes) == 1 and changes[0] == 'no changes', f'expected no changes, got {changes}'
" 2>/dev/null; then
    pass "Plan after apply returns 'no changes'"
else
    fail "Plan after apply not 'no changes': $PLAN2_RESP"
fi

# ====================================================================
# Test 15: Status contains zone name
# ====================================================================
if echo "$STATUS_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
st = d.get('state', {})
assert isinstance(st, dict) and st.get('zoneName') == 'example.com', f'missing zoneName in state'
" 2>/dev/null; then
    pass "Status contains zoneName=example.com"
else
    fail "Status missing zoneName: $STATUS_RESP"
fi

# ====================================================================
# Summary
# ====================================================================
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED"
    exit 1
fi
