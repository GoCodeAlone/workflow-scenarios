#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 34: App Container Deployment
# Tests deploy/status/rollback lifecycle for app.container with kubernetes mock backend.

NS="${NAMESPACE:-wf-scenario-34}"
PORT=18034
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
echo "=== Scenario 34: App Container Deployment (kubernetes mock backend) ==="
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
if echo "$RESP" | grep -q "34-app-container"; then
    pass "Health check identifies scenario 34-app-container"
else
    fail "Health check missing scenario identifier: $RESP"
fi

# ====================================================================
# Test 3: Status before deploy returns not_deployed
# ====================================================================
STATUS_RESP=$(curl -sf "$BASE/api/v1/app/status" 2>/dev/null || echo "")
if echo "$STATUS_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
result = d.get('result', {})
status_val = result.get('status') if isinstance(result, dict) else None
assert status_val == 'not_deployed', f'expected not_deployed, got {status_val!r}'
" 2>/dev/null; then
    pass "Status before deploy returns not_deployed"
else
    fail "Status before deploy not not_deployed: $STATUS_RESP"
fi

# ====================================================================
# Test 4: Deploy returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/app/deploy" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/app/deploy returns 200"
else
    fail "POST /api/v1/app/deploy returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 5: Deploy response status=active
# ====================================================================
DEPLOY_RESP=$(curl -sf -X POST "$BASE/api/v1/app/deploy" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$DEPLOY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('status') == 'active'" 2>/dev/null; then
    pass "Deploy response status=active"
else
    fail "Deploy response status not active: $DEPLOY_RESP"
fi

# ====================================================================
# Test 6: Deploy response platform=kubernetes
# ====================================================================
if echo "$DEPLOY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('platform') == 'kubernetes'" 2>/dev/null; then
    pass "Deploy response platform=kubernetes"
else
    fail "Deploy response platform not kubernetes: $DEPLOY_RESP"
fi

# ====================================================================
# Test 7: Deploy response contains endpoint
# ====================================================================
if echo "$DEPLOY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('endpoint'), str) and len(d['endpoint']) > 0" 2>/dev/null; then
    pass "Deploy response contains non-empty endpoint"
else
    fail "Deploy response missing endpoint: $DEPLOY_RESP"
fi

# ====================================================================
# Test 8: Deploy response endpoint contains app name
# ====================================================================
if echo "$DEPLOY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'my-app' in d.get('endpoint', '')" 2>/dev/null; then
    pass "Deploy response endpoint contains app name my-app"
else
    fail "Deploy response endpoint missing app name: $DEPLOY_RESP"
fi

# ====================================================================
# Test 9: Deploy response image=nginx:1.25
# ====================================================================
if echo "$DEPLOY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('image') == 'nginx:1.25'" 2>/dev/null; then
    pass "Deploy response image=nginx:1.25"
else
    fail "Deploy response image not nginx:1.25: $DEPLOY_RESP"
fi

# ====================================================================
# Test 10: Deploy response replicas=2
# ====================================================================
if echo "$DEPLOY_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('replicas') == 2" 2>/dev/null; then
    pass "Deploy response replicas=2"
else
    fail "Deploy response replicas not 2: $DEPLOY_RESP"
fi

# ====================================================================
# Test 11: Status returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/v1/app/status" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "GET /api/v1/app/status returns 200"
else
    fail "GET /api/v1/app/status returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 12: Status shows active after deploy
# ====================================================================
STATUS_RESP=$(curl -sf "$BASE/api/v1/app/status" 2>/dev/null || echo "")
if echo "$STATUS_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
result = d.get('result', {})
status_val = result.get('status') if isinstance(result, dict) else None
assert status_val == 'active', f'expected active, got {status_val!r}'
" 2>/dev/null; then
    pass "Status=active after deploy"
else
    fail "Status not active after deploy: $STATUS_RESP"
fi

# ====================================================================
# Test 13: Status platform=kubernetes after deploy
# ====================================================================
if echo "$STATUS_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
result = d.get('result', {})
platform_val = result.get('platform') if isinstance(result, dict) else None
assert platform_val == 'kubernetes', f'expected kubernetes, got {platform_val!r}'
" 2>/dev/null; then
    pass "Status platform=kubernetes after deploy"
else
    fail "Status platform not kubernetes: $STATUS_RESP"
fi

# ====================================================================
# Test 14: Second deploy returns 200 (creates rollback point)
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/app/deploy" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Second POST /api/v1/app/deploy returns 200 (creates rollback point)"
else
    fail "Second POST /api/v1/app/deploy returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 15: Rollback returns 200
# ====================================================================
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/app/rollback" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/app/rollback returns 200"
else
    fail "POST /api/v1/app/rollback returned $HTTP_CODE (expected 200)"
fi

# ====================================================================
# Test 16: Rollback response status=rolled_back
# ====================================================================
# Re-deploy twice to ensure rollback has previous state
curl -sf -X POST "$BASE/api/v1/app/deploy" -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1 || true
curl -sf -X POST "$BASE/api/v1/app/deploy" -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1 || true
ROLLBACK_RESP=$(curl -sf -X POST "$BASE/api/v1/app/rollback" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null || echo "")
if echo "$ROLLBACK_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('status') == 'rolled_back'" 2>/dev/null; then
    pass "Rollback response status=rolled_back"
else
    fail "Rollback response status not rolled_back: $ROLLBACK_RESP"
fi

# ====================================================================
# Test 17: Rollback response platform=kubernetes
# ====================================================================
if echo "$ROLLBACK_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('platform') == 'kubernetes'" 2>/dev/null; then
    pass "Rollback response platform=kubernetes"
else
    fail "Rollback response platform not kubernetes: $ROLLBACK_RESP"
fi

# ====================================================================
# Test 18: Rollback response rolled_back=true
# ====================================================================
if echo "$ROLLBACK_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('rolled_back') is True" 2>/dev/null; then
    pass "Rollback response rolled_back=true"
else
    fail "Rollback response missing rolled_back=true: $ROLLBACK_RESP"
fi

# ====================================================================
# Test 19: Status shows rolled_back after rollback
# ====================================================================
STATUS_RESP=$(curl -sf "$BASE/api/v1/app/status" 2>/dev/null || echo "")
if echo "$STATUS_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
result = d.get('result', {})
status_val = result.get('status') if isinstance(result, dict) else None
assert status_val == 'rolled_back', f'expected rolled_back, got {status_val!r}'
" 2>/dev/null; then
    pass "Status=rolled_back after rollback"
else
    fail "Status not rolled_back after rollback: $STATUS_RESP"
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
