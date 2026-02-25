#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 30: ECS Fargate
# Tests plan/apply/status/destroy lifecycle using the in-memory mock backend.

NS="${NAMESPACE:-wf-scenario-30}"
PORT=18030
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
echo "=== Scenario 30: ECS Fargate (in-memory mock backend) ==="
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
if echo "$RESP" | grep -q "30-ecs-fargate"; then
    pass "Health check identifies scenario 30-ecs-fargate"
else
    fail "Health check missing scenario identifier: $RESP"
fi

# ====================================================================
# Test 3: Plan returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/services/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/services/plan returns 200"
else
    fail "POST /api/v1/services/plan returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 4: Plan response contains actions
# ====================================================================
PLAN_RESP=$(curl -sf -X POST "$BASE/api/v1/services/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$PLAN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('actions'), list)" 2>/dev/null; then
    pass "Plan response contains actions list"
else
    fail "Plan response missing actions list: $PLAN_RESP"
fi

# ====================================================================
# Test 5: Plan action type is 'create' (service is pending)
# ====================================================================
if echo "$PLAN_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
actions = d.get('actions', [])
assert len(actions) > 0, 'no actions'
assert actions[0].get('type') == 'create', f'expected create, got {actions[0].get(\"type\")}'
" 2>/dev/null; then
    pass "Plan action type is 'create' for pending ECS service"
else
    fail "Plan action type not 'create': $PLAN_RESP"
fi

# ====================================================================
# Test 6: Plan response contains provider field
# ====================================================================
if echo "$PLAN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'provider' in d" 2>/dev/null; then
    pass "Plan response contains provider field"
else
    fail "Plan response missing provider field: $PLAN_RESP"
fi

# ====================================================================
# Test 7: Plan response provider is 'ecs'
# ====================================================================
if echo "$PLAN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('provider') == 'ecs'" 2>/dev/null; then
    pass "Plan provider is 'ecs'"
else
    fail "Plan provider not 'ecs': $PLAN_RESP"
fi

# ====================================================================
# Test 8: Apply returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/services/apply" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/services/apply returns 200"
else
    fail "POST /api/v1/services/apply returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 9: Apply response success=true
# ====================================================================
APPLY_RESP=$(curl -sf -X POST "$BASE/api/v1/services/apply" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$APPLY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('success') is True" 2>/dev/null; then
    pass "Apply response success=true"
else
    fail "Apply response success not true: $APPLY_RESP"
fi

# ====================================================================
# Test 10: Apply response contains message
# ====================================================================
if echo "$APPLY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('message'), str) and len(d['message']) > 0" 2>/dev/null; then
    pass "Apply response contains non-empty message"
else
    fail "Apply response missing message: $APPLY_RESP"
fi

# ====================================================================
# Test 11: Status returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/v1/services/status" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "GET /api/v1/services/status returns 200"
else
    fail "GET /api/v1/services/status returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 12: Status shows service=running after apply
# ====================================================================
STATUS_RESP=$(curl -sf "$BASE/api/v1/services/status" 2>/dev/null || echo "")
if echo "$STATUS_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
st = d.get('status', {})
status_val = st.get('status') if isinstance(st, dict) else None
assert status_val == 'running', f'expected running, got {status_val!r}'
" 2>/dev/null; then
    pass "Status shows ECS service status=running after apply"
else
    fail "Status not running after apply: $STATUS_RESP"
fi

# ====================================================================
# Test 13: Status shows runningCount > 0
# ====================================================================
if echo "$STATUS_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
st = d.get('status', {})
assert isinstance(st, dict), 'status not a dict'
assert st.get('runningCount', 0) > 0, f'expected runningCount > 0, got {st.get(\"runningCount\")}'
" 2>/dev/null; then
    pass "Status shows runningCount > 0 after apply"
else
    fail "Status runningCount not > 0: $STATUS_RESP"
fi

# ====================================================================
# Test 14: Status contains cluster name
# ====================================================================
if echo "$STATUS_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
st = d.get('status', {})
assert isinstance(st, dict) and st.get('cluster'), 'missing cluster in status'
" 2>/dev/null; then
    pass "Status contains cluster name"
else
    fail "Status missing cluster name: $STATUS_RESP"
fi

# ====================================================================
# Test 15: Status contains taskDefinition after apply
# ====================================================================
if echo "$STATUS_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
st = d.get('status', {})
td = st.get('taskDefinition', {}) if isinstance(st, dict) else {}
assert td.get('family'), 'missing taskDefinition.family'
" 2>/dev/null; then
    pass "Status contains taskDefinition with family after apply"
else
    fail "Status missing taskDefinition: $STATUS_RESP"
fi

# ====================================================================
# Test 16: Plan after apply returns noop
# ====================================================================
PLAN2_RESP=$(curl -sf -X POST "$BASE/api/v1/services/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$PLAN2_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
actions = d.get('actions', [])
assert len(actions) > 0, 'no actions'
assert actions[0].get('type') == 'noop', f'expected noop, got {actions[0].get(\"type\")}'
" 2>/dev/null; then
    pass "Plan after apply returns noop action"
else
    fail "Plan after apply not noop: $PLAN2_RESP"
fi

# ====================================================================
# Test 17: Destroy returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/api/v1/services" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "DELETE /api/v1/services returns 200"
else
    fail "DELETE /api/v1/services returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 18: Destroy response destroyed=true
# ====================================================================
DESTROY_RESP=$(curl -sf -X DELETE "$BASE/api/v1/services" 2>/dev/null || echo "")
if echo "$DESTROY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('destroyed') is True" 2>/dev/null; then
    pass "Destroy response destroyed=true"
else
    fail "Destroy response destroyed not true: $DESTROY_RESP"
fi

# ====================================================================
# Test 19: Status shows deleted after destroy
# ====================================================================
STATUS2_RESP=$(curl -sf "$BASE/api/v1/services/status" 2>/dev/null || echo "")
if echo "$STATUS2_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
st = d.get('status', {})
status_val = st.get('status') if isinstance(st, dict) else None
assert status_val == 'deleted', f'expected deleted, got {status_val!r}'
" 2>/dev/null; then
    pass "Status shows ECS service status=deleted after destroy"
else
    fail "Status not deleted after destroy: $STATUS2_RESP"
fi

# ====================================================================
# Test 20: Plan after destroy returns create again
# ====================================================================
PLAN3_RESP=$(curl -sf -X POST "$BASE/api/v1/services/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$PLAN3_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
actions = d.get('actions', [])
assert len(actions) > 0, 'no actions'
assert actions[0].get('type') == 'create', f'expected create, got {actions[0].get(\"type\")}'
" 2>/dev/null; then
    pass "Plan after destroy returns create action"
else
    fail "Plan after destroy not create: $PLAN3_RESP"
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
