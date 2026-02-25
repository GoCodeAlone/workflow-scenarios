#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 33: API Gateway and Autoscaling
# Tests plan/apply/status/destroy lifecycle for both modules using in-memory mock backends.

NS="${NAMESPACE:-wf-scenario-33}"
PORT=18033
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
echo "=== Scenario 33: API Gateway and Autoscaling (in-memory mock backends) ==="
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
if echo "$RESP" | grep -q "33-apigateway-autoscaling"; then
    pass "Health check identifies scenario 33-apigateway-autoscaling"
else
    fail "Health check missing scenario identifier: $RESP"
fi

# ====================================================================
# Test 3: Gateway plan returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/gateway/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/gateway/plan returns 200"
else
    fail "POST /api/v1/gateway/plan returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 4: Gateway plan response contains changes
# ====================================================================
PLAN_RESP=$(curl -sf -X POST "$BASE/api/v1/gateway/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$PLAN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('changes'), list) and len(d['changes']) > 0" 2>/dev/null; then
    pass "Gateway plan response contains changes list"
else
    fail "Gateway plan response missing changes list: $PLAN_RESP"
fi

# ====================================================================
# Test 5: Gateway plan response contains routes
# ====================================================================
if echo "$PLAN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('routes'), list)" 2>/dev/null; then
    pass "Gateway plan response contains routes list"
else
    fail "Gateway plan response missing routes: $PLAN_RESP"
fi

# ====================================================================
# Test 6: Gateway plan response contains stage
# ====================================================================
if echo "$PLAN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('stage') == 'prod'" 2>/dev/null; then
    pass "Gateway plan response contains stage=prod"
else
    fail "Gateway plan response missing stage=prod: $PLAN_RESP"
fi

# ====================================================================
# Test 7: Gateway apply returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/gateway/apply" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/gateway/apply returns 200"
else
    fail "POST /api/v1/gateway/apply returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 8: Gateway apply response status=active
# ====================================================================
APPLY_RESP=$(curl -sf -X POST "$BASE/api/v1/gateway/apply" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$APPLY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('status') == 'active'" 2>/dev/null; then
    pass "Gateway apply response status=active"
else
    fail "Gateway apply response status not active: $APPLY_RESP"
fi

# ====================================================================
# Test 9: Gateway apply response contains endpoint
# ====================================================================
if echo "$APPLY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('endpoint'), str) and len(d['endpoint']) > 0" 2>/dev/null; then
    pass "Gateway apply response contains non-empty endpoint"
else
    fail "Gateway apply response missing endpoint: $APPLY_RESP"
fi

# ====================================================================
# Test 10: Gateway status returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/v1/gateway/status" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "GET /api/v1/gateway/status returns 200"
else
    fail "GET /api/v1/gateway/status returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 11: Gateway status shows active after apply
# ====================================================================
STATUS_RESP=$(curl -sf "$BASE/api/v1/gateway/status" 2>/dev/null || echo "")
if echo "$STATUS_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
st = d.get('status', {})
status_val = st.get('status') if isinstance(st, dict) else None
assert status_val == 'active', f'expected active, got {status_val!r}'
" 2>/dev/null; then
    pass "Gateway status=active after apply"
else
    fail "Gateway status not active after apply: $STATUS_RESP"
fi

# ====================================================================
# Test 12: Gateway destroy returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/api/v1/gateway" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "DELETE /api/v1/gateway returns 200"
else
    fail "DELETE /api/v1/gateway returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 13: Gateway destroy response destroyed=true
# ====================================================================
DESTROY_RESP=$(curl -sf -X DELETE "$BASE/api/v1/gateway" 2>/dev/null || echo "")
if echo "$DESTROY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('destroyed') is True" 2>/dev/null; then
    pass "Gateway destroy response destroyed=true"
else
    fail "Gateway destroy response destroyed not true: $DESTROY_RESP"
fi

# ====================================================================
# Test 14: Scaling plan returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/scaling/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/scaling/plan returns 200"
else
    fail "POST /api/v1/scaling/plan returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 15: Scaling plan response contains changes
# ====================================================================
SCALE_PLAN_RESP=$(curl -sf -X POST "$BASE/api/v1/scaling/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$SCALE_PLAN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('changes'), list) and len(d['changes']) > 0" 2>/dev/null; then
    pass "Scaling plan response contains changes list"
else
    fail "Scaling plan response missing changes: $SCALE_PLAN_RESP"
fi

# ====================================================================
# Test 16: Scaling plan response contains policies
# ====================================================================
if echo "$SCALE_PLAN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('policies'), list) and len(d['policies']) == 2" 2>/dev/null; then
    pass "Scaling plan response contains 2 policies"
else
    fail "Scaling plan response missing 2 policies: $SCALE_PLAN_RESP"
fi

# ====================================================================
# Test 17: Scaling apply returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/scaling/apply" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/scaling/apply returns 200"
else
    fail "POST /api/v1/scaling/apply returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 18: Scaling apply response status=active
# ====================================================================
SCALE_APPLY_RESP=$(curl -sf -X POST "$BASE/api/v1/scaling/apply" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$SCALE_APPLY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('status') == 'active'" 2>/dev/null; then
    pass "Scaling apply response status=active"
else
    fail "Scaling apply response status not active: $SCALE_APPLY_RESP"
fi

# ====================================================================
# Test 19: Scaling status returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/v1/scaling/status" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "GET /api/v1/scaling/status returns 200"
else
    fail "GET /api/v1/scaling/status returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 20: Scaling status shows active after apply
# ====================================================================
SCALE_STATUS_RESP=$(curl -sf "$BASE/api/v1/scaling/status" 2>/dev/null || echo "")
if echo "$SCALE_STATUS_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
st = d.get('status', {})
status_val = st.get('status') if isinstance(st, dict) else None
assert status_val == 'active', f'expected active, got {status_val!r}'
" 2>/dev/null; then
    pass "Scaling status=active after apply"
else
    fail "Scaling status not active after apply: $SCALE_STATUS_RESP"
fi

# ====================================================================
# Test 21: Scaling destroy returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/api/v1/scaling" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "DELETE /api/v1/scaling returns 200"
else
    fail "DELETE /api/v1/scaling returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 22: Scaling destroy response destroyed=true
# ====================================================================
SCALE_DESTROY_RESP=$(curl -sf -X DELETE "$BASE/api/v1/scaling" 2>/dev/null || echo "")
if echo "$SCALE_DESTROY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('destroyed') is True" 2>/dev/null; then
    pass "Scaling destroy response destroyed=true"
else
    fail "Scaling destroy response destroyed not true: $SCALE_DESTROY_RESP"
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
