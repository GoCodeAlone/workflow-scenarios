#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 28: IaC Pipeline
# Tests the full IaC lifecycle: plan → apply → status → drift-detect → destroy.

NS="${NAMESPACE:-wf-scenario-28}"
PORT=18028
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
echo "=== Scenario 28: IaC Pipeline (iac.state + platform.kubernetes/kind) ==="
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
if echo "$RESP" | grep -q "28-iac-pipeline"; then
    pass "Health check identifies scenario 28-iac-pipeline"
else
    fail "Health check missing scenario identifier: $RESP"
fi

# ====================================================================
# Test 3: IaC plan returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/iac/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/iac/plan returns 200"
else
    fail "POST /api/v1/iac/plan returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 4: Plan response contains status=planned
# ====================================================================
PLAN_RESP=$(curl -sf -X POST "$BASE/api/v1/iac/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$PLAN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('status') == 'planned', f'got {d.get(\"status\")}'" 2>/dev/null; then
    pass "Plan response status=planned"
else
    fail "Plan response missing status=planned: $PLAN_RESP"
fi

# ====================================================================
# Test 5: Plan response contains actions list
# ====================================================================
if echo "$PLAN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('actions'), list)" 2>/dev/null; then
    pass "Plan response contains actions list"
else
    fail "Plan response missing actions list: $PLAN_RESP"
fi

# ====================================================================
# Test 6: Plan action type is 'create' (cluster starts pending)
# ====================================================================
if echo "$PLAN_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
actions = d.get('actions', [])
assert len(actions) > 0, 'no actions'
assert actions[0].get('type') == 'create', f'expected create, got {actions[0].get(\"type\")}'
" 2>/dev/null; then
    pass "Plan action type is 'create' for pending cluster"
else
    fail "Plan action type not 'create': $PLAN_RESP"
fi

# ====================================================================
# Test 7: Plan response contains resource_id
# ====================================================================
if echo "$PLAN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'resource_id' in d" 2>/dev/null; then
    pass "Plan response contains resource_id"
else
    fail "Plan response missing resource_id: $PLAN_RESP"
fi

# ====================================================================
# Test 8: IaC apply returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/iac/apply" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/iac/apply returns 200"
else
    fail "POST /api/v1/iac/apply returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 9: Apply response success=true
# ====================================================================
APPLY_RESP=$(curl -sf -X POST "$BASE/api/v1/iac/apply" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$APPLY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('success') is True" 2>/dev/null; then
    pass "Apply response success=true"
else
    fail "Apply response success not true: $APPLY_RESP"
fi

# ====================================================================
# Test 10: Apply response status=active
# ====================================================================
if echo "$APPLY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('status') == 'active'" 2>/dev/null; then
    pass "Apply response status=active"
else
    fail "Apply response status not active: $APPLY_RESP"
fi

# ====================================================================
# Test 11: Apply response contains message
# ====================================================================
if echo "$APPLY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('message'), str) and len(d['message']) > 0" 2>/dev/null; then
    pass "Apply response contains non-empty message"
else
    fail "Apply response missing message: $APPLY_RESP"
fi

# ====================================================================
# Test 12: IaC status returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/v1/iac/status" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "GET /api/v1/iac/status returns 200"
else
    fail "GET /api/v1/iac/status returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 13: Status stored_status=active after apply
# ====================================================================
STATUS_RESP=$(curl -sf "$BASE/api/v1/iac/status" 2>/dev/null || echo "")
if echo "$STATUS_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('stored_status') == 'active'" 2>/dev/null; then
    pass "Status stored_status=active after apply"
else
    fail "Status stored_status not active: $STATUS_RESP"
fi

# ====================================================================
# Test 14: Status contains resource_id
# ====================================================================
if echo "$STATUS_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'resource_id' in d" 2>/dev/null; then
    pass "Status contains resource_id"
else
    fail "Status missing resource_id: $STATUS_RESP"
fi

# ====================================================================
# Test 15: Status contains live_status
# ====================================================================
if echo "$STATUS_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('live_status') is not None" 2>/dev/null; then
    pass "Status contains live_status"
else
    fail "Status missing live_status: $STATUS_RESP"
fi

# ====================================================================
# Test 16: Drift detect returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/iac/drift" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/iac/drift returns 200"
else
    fail "POST /api/v1/iac/drift returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 17: Drift detect reports drifted=true (config has changed keys)
# ====================================================================
DRIFT_RESP=$(curl -sf -X POST "$BASE/api/v1/iac/drift" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$DRIFT_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('drifted') is True" 2>/dev/null; then
    pass "Drift detect reports drifted=true"
else
    fail "Drift detect did not report drifted=true: $DRIFT_RESP"
fi

# ====================================================================
# Test 18: Drift detect response contains diffs
# ====================================================================
if echo "$DRIFT_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('diffs'), list) and len(d['diffs']) > 0" 2>/dev/null; then
    pass "Drift detect response contains non-empty diffs"
else
    fail "Drift detect response missing diffs: $DRIFT_RESP"
fi

# ====================================================================
# Test 19: IaC destroy returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/api/v1/iac" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "DELETE /api/v1/iac returns 200"
else
    fail "DELETE /api/v1/iac returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 20: Destroy response destroyed=true
# ====================================================================
DESTROY_RESP=$(curl -sf -X DELETE "$BASE/api/v1/iac" 2>/dev/null || echo "")
if echo "$DESTROY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('destroyed') is True" 2>/dev/null; then
    pass "Destroy response destroyed=true"
else
    fail "Destroy response destroyed not true: $DESTROY_RESP"
fi

# ====================================================================
# Test 21: Destroy response status=destroyed
# ====================================================================
if echo "$DESTROY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('status') == 'destroyed'" 2>/dev/null; then
    pass "Destroy response status=destroyed"
else
    fail "Destroy response status not destroyed: $DESTROY_RESP"
fi

# ====================================================================
# Test 22: Status shows destroyed after destroy
# ====================================================================
STATUS2_RESP=$(curl -sf "$BASE/api/v1/iac/status" 2>/dev/null || echo "")
if echo "$STATUS2_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('stored_status') == 'destroyed'" 2>/dev/null; then
    pass "Status stored_status=destroyed after destroy"
else
    fail "Status stored_status not destroyed after destroy: $STATUS2_RESP"
fi

# ====================================================================
# Test 23: Plan again after destroy yields create action
# ====================================================================
PLAN3_RESP=$(curl -sf -X POST "$BASE/api/v1/iac/plan" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$PLAN3_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
actions = d.get('actions', [])
# After destroy the cluster is in 'deleted' state, so plan should propose create again
assert len(actions) > 0, 'no actions'
" 2>/dev/null; then
    pass "Plan after destroy returns at least one action"
else
    fail "Plan after destroy returned no actions: $PLAN3_RESP"
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
