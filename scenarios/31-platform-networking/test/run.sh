#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 31: Platform Networking
# Tests plan/apply/status lifecycle using the in-memory mock backend.

NS="${NAMESPACE:-wf-scenario-31}"
PORT=18031
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
echo "=== Scenario 31: Platform Networking (in-memory mock backend) ==="
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
if echo "$RESP" | grep -q "31-platform-networking"; then
    pass "Health check identifies scenario 31-platform-networking"
else
    fail "Health check missing scenario identifier: $RESP"
fi

# ====================================================================
# Test 3: Plan returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/networks/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/networks/plan returns 200"
else
    fail "POST /api/v1/networks/plan returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 4: Plan response contains changes list
# ====================================================================
PLAN_RESP=$(curl -sf -X POST "$BASE/api/v1/networks/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$PLAN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('changes'), list) and len(d['changes']) > 0" 2>/dev/null; then
    pass "Plan response contains non-empty changes list"
else
    fail "Plan response missing changes list: $PLAN_RESP"
fi

# ====================================================================
# Test 5: Plan response contains vpc field with cidr
# ====================================================================
if echo "$PLAN_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
vpc = d.get('vpc', {})
assert vpc.get('cidr') == '10.0.0.0/16', f'expected 10.0.0.0/16, got {vpc.get(\"cidr\")}'
" 2>/dev/null; then
    pass "Plan response vpc.cidr is 10.0.0.0/16"
else
    fail "Plan response missing or wrong vpc.cidr: $PLAN_RESP"
fi

# ====================================================================
# Test 6: Plan response contains subnets
# ====================================================================
if echo "$PLAN_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
subnets = d.get('plan', {}).get('subnets', [])
assert len(subnets) >= 4, f'expected >=4 subnets, got {len(subnets)}'
" 2>/dev/null; then
    pass "Plan response contains 4 subnets"
else
    fail "Plan response missing subnets: $PLAN_RESP"
fi

# ====================================================================
# Test 7: Plan indicates NAT gateway
# ====================================================================
if echo "$PLAN_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
plan = d.get('plan', {})
assert plan.get('natGateway') is True, f'expected natGateway=true, got {plan.get(\"natGateway\")}'
" 2>/dev/null; then
    pass "Plan response natGateway=true"
else
    fail "Plan response missing natGateway: $PLAN_RESP"
fi

# ====================================================================
# Test 8: Apply returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/networks/apply" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/networks/apply returns 200"
else
    fail "POST /api/v1/networks/apply returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 9: Apply response status=active
# ====================================================================
APPLY_RESP=$(curl -sf -X POST "$BASE/api/v1/networks/apply" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$APPLY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('status') == 'active'" 2>/dev/null; then
    pass "Apply response status=active"
else
    fail "Apply response status not active: $APPLY_RESP"
fi

# ====================================================================
# Test 10: Apply response contains vpcId
# ====================================================================
if echo "$APPLY_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('vpcId'), 'missing vpcId'
" 2>/dev/null; then
    pass "Apply response contains non-empty vpcId"
else
    fail "Apply response missing vpcId: $APPLY_RESP"
fi

# ====================================================================
# Test 11: Apply response contains subnet IDs
# ====================================================================
if echo "$APPLY_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
state = d.get('state', {})
subnet_ids = state.get('subnetIds', {})
assert len(subnet_ids) >= 4, f'expected >=4 subnetIds, got {len(subnet_ids)}'
assert 'public-a' in subnet_ids, 'missing public-a subnet'
assert 'private-a' in subnet_ids, 'missing private-a subnet'
" 2>/dev/null; then
    pass "Apply response contains subnet IDs including public-a and private-a"
else
    fail "Apply response missing subnet IDs: $APPLY_RESP"
fi

# ====================================================================
# Test 12: Apply response contains NAT gateway ID
# ====================================================================
if echo "$APPLY_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
state = d.get('state', {})
assert state.get('natGatewayId'), 'missing natGatewayId'
" 2>/dev/null; then
    pass "Apply response contains natGatewayId"
else
    fail "Apply response missing natGatewayId: $APPLY_RESP"
fi

# ====================================================================
# Test 13: Apply response contains security group IDs
# ====================================================================
if echo "$APPLY_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
state = d.get('state', {})
sg_ids = state.get('securityGroupIds', {})
assert 'web' in sg_ids, f'missing web security group, got {list(sg_ids.keys())}'
" 2>/dev/null; then
    pass "Apply response contains web security group ID"
else
    fail "Apply response missing security group IDs: $APPLY_RESP"
fi

# ====================================================================
# Test 14: Status returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/v1/networks/status" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "GET /api/v1/networks/status returns 200"
else
    fail "GET /api/v1/networks/status returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 15: Status shows network=active after apply
# ====================================================================
STATUS_RESP=$(curl -sf "$BASE/api/v1/networks/status" 2>/dev/null || echo "")
if echo "$STATUS_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
st = d.get('status', {})
status_val = st.get('status') if isinstance(st, dict) else None
assert status_val == 'active', f'expected active, got {status_val!r}'
" 2>/dev/null; then
    pass "Status shows network status=active after apply"
else
    fail "Status not active after apply: $STATUS_RESP"
fi

# ====================================================================
# Test 16: Plan after apply returns noop
# ====================================================================
PLAN2_RESP=$(curl -sf -X POST "$BASE/api/v1/networks/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$PLAN2_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
changes = d.get('changes', [])
assert len(changes) > 0, 'no changes'
assert 'noop' in changes[0], f'expected noop, got {changes[0]!r}'
" 2>/dev/null; then
    pass "Plan after apply returns noop"
else
    fail "Plan after apply not noop: $PLAN2_RESP"
fi

# ====================================================================
# Test 17: Status contains network module name
# ====================================================================
if echo "$STATUS_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('network') == 'prod-network', f'expected prod-network, got {d.get(\"network\")}'
" 2>/dev/null; then
    pass "Status response contains network=prod-network"
else
    fail "Status missing network identifier: $STATUS_RESP"
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
