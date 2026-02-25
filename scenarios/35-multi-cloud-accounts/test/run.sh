#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 35: Multi-Cloud Accounts (AWS mock, GCP, Azure)
# Tests cloud.account validate, list, and per-account detail endpoints.
# Outputs PASS: or FAIL: lines for each assertion.

NS="${NAMESPACE:-wf-scenario-35}"
PORT=18035
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
if echo "$RESP" | grep -q "35-multi-cloud-accounts"; then
    pass "Health check identifies scenario 35-multi-cloud-accounts"
else
    fail "Health check missing scenario identifier: $RESP"
fi

# ====================================================================
# Test 3: Validate endpoint returns valid field
# ====================================================================
RESP=$(curl -sf -X POST "$BASE/api/v1/cloud/validate" \
    -H "Content-Type: application/json" \
    -d '{"account":"aws-prod"}' 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q '"valid"'; then
    pass "Validate endpoint returns valid field"
else
    fail "Validate endpoint missing valid field: $RESP"
fi

# ====================================================================
# Test 4: Validate aws-prod returns provider
# ====================================================================
if echo "$RESP" | grep -q '"provider"'; then
    pass "Validate response includes provider field"
else
    fail "Validate response missing provider field: $RESP"
fi

# ====================================================================
# Test 5: Validate aws-prod returns region
# ====================================================================
if echo "$RESP" | grep -q '"region"'; then
    pass "Validate response includes region field"
else
    fail "Validate response missing region field: $RESP"
fi

# ====================================================================
# Test 6: List accounts returns all three accounts
# ====================================================================
RESP=$(curl -sf "$BASE/api/v1/cloud/accounts" 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q '"accounts"'; then
    pass "List accounts returns accounts field"
else
    fail "List accounts missing accounts field: $RESP"
fi

# ====================================================================
# Test 7: List accounts includes aws-prod
# ====================================================================
if echo "$RESP" | grep -q "aws-prod"; then
    pass "List accounts includes aws-prod"
else
    fail "List accounts missing aws-prod: $RESP"
fi

# ====================================================================
# Test 8: List accounts includes gcp-prod
# ====================================================================
if echo "$RESP" | grep -q "gcp-prod"; then
    pass "List accounts includes gcp-prod"
else
    fail "List accounts missing gcp-prod: $RESP"
fi

# ====================================================================
# Test 9: List accounts includes azure-prod
# ====================================================================
if echo "$RESP" | grep -q "azure-prod"; then
    pass "List accounts includes azure-prod"
else
    fail "List accounts missing azure-prod: $RESP"
fi

# ====================================================================
# Test 10: List accounts includes gcp provider
# ====================================================================
if echo "$RESP" | grep -q '"gcp"'; then
    pass "List accounts includes gcp provider"
else
    fail "List accounts missing gcp provider: $RESP"
fi

# ====================================================================
# Test 11: List accounts includes azure provider
# ====================================================================
if echo "$RESP" | grep -q '"azure"'; then
    pass "List accounts includes azure provider"
else
    fail "List accounts missing azure provider: $RESP"
fi

# ====================================================================
# Test 12: Get aws-prod — returns name and provider
# ====================================================================
RESP=$(curl -sf "$BASE/api/v1/cloud/accounts/aws-prod" 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q '"name"'; then
    pass "Get aws-prod returns name field"
else
    fail "Get aws-prod missing name field: $RESP"
fi

# ====================================================================
# Test 13: Get aws-prod — correct region
# ====================================================================
if echo "$RESP" | grep -q "us-east-1"; then
    pass "Get aws-prod shows region=us-east-1"
else
    fail "Get aws-prod wrong region: $RESP"
fi

# ====================================================================
# Test 14: Get gcp-prod — returns name
# ====================================================================
RESP=$(curl -sf "$BASE/api/v1/cloud/accounts/gcp-prod" 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q '"name"'; then
    pass "Get gcp-prod returns name field"
else
    fail "Get gcp-prod missing name field: $RESP"
fi

# ====================================================================
# Test 15: Get gcp-prod — correct region
# ====================================================================
if echo "$RESP" | grep -q "us-central1"; then
    pass "Get gcp-prod shows region=us-central1"
else
    fail "Get gcp-prod wrong region: $RESP"
fi

# ====================================================================
# Test 16: Get gcp-prod — project_id present
# ====================================================================
if echo "$RESP" | grep -q "my-gcp-project"; then
    pass "Get gcp-prod shows project_id=my-gcp-project"
else
    fail "Get gcp-prod missing project_id: $RESP"
fi

# ====================================================================
# Test 17: Get azure-prod — returns name
# ====================================================================
RESP=$(curl -sf "$BASE/api/v1/cloud/accounts/azure-prod" 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q '"name"'; then
    pass "Get azure-prod returns name field"
else
    fail "Get azure-prod missing name field: $RESP"
fi

# ====================================================================
# Test 18: Get azure-prod — correct region
# ====================================================================
if echo "$RESP" | grep -q "eastus"; then
    pass "Get azure-prod shows region=eastus"
else
    fail "Get azure-prod wrong region: $RESP"
fi

# ====================================================================
# Test 19: Get azure-prod — subscription_id present
# ====================================================================
if echo "$RESP" | grep -q "00000000-0000-0000-0000-000000000001"; then
    pass "Get azure-prod shows subscription_id"
else
    fail "Get azure-prod missing subscription_id: $RESP"
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
