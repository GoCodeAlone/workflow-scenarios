#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 25: Cloud Account — Cloud Provider Credentials
# Tests cloud.account mock provider: validate, list accounts, get account details.
# Outputs PASS: or FAIL: lines for each assertion.

NS="${NAMESPACE:-wf-scenario-25}"
PORT=18025
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
if echo "$RESP" | grep -q "25-cloud-account"; then
    pass "Health check identifies scenario 25-cloud-account"
else
    fail "Health check missing scenario identifier: $RESP"
fi

# ====================================================================
# Test 3: Validate aws-production credentials
# ====================================================================
RESP=$(curl -sf -X POST "$BASE/api/v1/cloud/validate" \
    -H "Content-Type: application/json" \
    -d '{"account":"aws-production"}' 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q '"valid"'; then
    pass "Validate endpoint returns valid field"
else
    fail "Validate endpoint missing valid field: $RESP"
fi

# ====================================================================
# Test 4: Validate returns provider=mock
# ====================================================================
if echo "$RESP" | grep -q '"provider"'; then
    pass "Validate response includes provider field"
else
    fail "Validate response missing provider field: $RESP"
fi

# ====================================================================
# Test 5: Validate returns region
# ====================================================================
if echo "$RESP" | grep -q '"region"'; then
    pass "Validate response includes region field"
else
    fail "Validate response missing region field: $RESP"
fi

# ====================================================================
# Test 6: Validate returns account name
# ====================================================================
if echo "$RESP" | grep -q '"account"'; then
    pass "Validate response includes account field"
else
    fail "Validate response missing account field: $RESP"
fi

# ====================================================================
# Test 7: List accounts returns all three accounts
# ====================================================================
RESP=$(curl -sf "$BASE/api/v1/cloud/accounts" 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q '"accounts"'; then
    pass "List accounts returns accounts field"
else
    fail "List accounts missing accounts field: $RESP"
fi

# ====================================================================
# Test 8: List accounts includes aws-production
# ====================================================================
if echo "$RESP" | grep -q "aws-production"; then
    pass "List accounts includes aws-production"
else
    fail "List accounts missing aws-production: $RESP"
fi

# ====================================================================
# Test 9: List accounts includes aws-staging
# ====================================================================
if echo "$RESP" | grep -q "aws-staging"; then
    pass "List accounts includes aws-staging"
else
    fail "List accounts missing aws-staging: $RESP"
fi

# ====================================================================
# Test 10: List accounts includes local-k8s
# ====================================================================
if echo "$RESP" | grep -q "local-k8s"; then
    pass "List accounts includes local-k8s"
else
    fail "List accounts missing local-k8s: $RESP"
fi

# ====================================================================
# Test 11: Get aws-production account info
# ====================================================================
RESP=$(curl -sf "$BASE/api/v1/cloud/accounts/aws-production" 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q '"name"'; then
    pass "Get aws-production returns name field"
else
    fail "Get aws-production missing name field: $RESP"
fi

# ====================================================================
# Test 12: Get aws-production shows correct provider
# ====================================================================
if echo "$RESP" | grep -q '"mock"'; then
    pass "Get aws-production shows provider=mock"
else
    fail "Get aws-production wrong provider: $RESP"
fi

# ====================================================================
# Test 13: Get aws-production shows correct region
# ====================================================================
if echo "$RESP" | grep -q "us-east-1"; then
    pass "Get aws-production shows region=us-east-1"
else
    fail "Get aws-production wrong region: $RESP"
fi

# ====================================================================
# Test 14: Get aws-staging account — different region
# ====================================================================
RESP=$(curl -sf "$BASE/api/v1/cloud/accounts/aws-staging" 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q "us-west-2"; then
    pass "Get aws-staging shows region=us-west-2"
else
    fail "Get aws-staging wrong region: $RESP"
fi

# ====================================================================
# Test 15: Get local-k8s account — kubernetes provider
# ====================================================================
RESP=$(curl -sf "$BASE/api/v1/cloud/accounts/local-k8s" 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q '"kubernetes"'; then
    pass "Get local-k8s shows provider=kubernetes"
else
    fail "Get local-k8s wrong provider: $RESP"
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
