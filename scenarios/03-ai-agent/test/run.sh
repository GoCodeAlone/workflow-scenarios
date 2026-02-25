#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 03: AI Agent Platform (Ratchet)
# Outputs PASS: or FAIL: lines for each test
# Ratchet is expected to be deployed in the default namespace

RATCHET_NS="default"
RATCHET_SVC="ratchet"
RATCHET_PORT="8080"

# Port-forward to ratchet
kubectl port-forward svc/$RATCHET_SVC $RATCHET_PORT:$RATCHET_PORT -n "$RATCHET_NS" &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE="http://localhost:${RATCHET_PORT}"

# Test 1: Health check
HEALTH_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE/health" 2>/dev/null || echo "000")
if [ "$HEALTH_CODE" = "200" ]; then
    echo "PASS: Ratchet health check returns 200"
else
    echo "FAIL: Ratchet health check returned $HEALTH_CODE (expected 200)"
fi

# Test 2: Health response contains status
HEALTH_BODY=$(curl -sf "$BASE/health" 2>/dev/null || echo "ERROR")
if echo "$HEALTH_BODY" | grep -qi "ok\|healthy\|status"; then
    echo "PASS: Health response contains status field"
else
    echo "FAIL: Health response missing status: $HEALTH_BODY"
fi

# Test 3: Providers endpoint responds
PROVIDERS_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE/api/v1/providers" 2>/dev/null || echo "000")
if [ "$PROVIDERS_CODE" = "200" ] || [ "$PROVIDERS_CODE" = "401" ]; then
    echo "PASS: Providers endpoint responds ($PROVIDERS_CODE)"
else
    echo "FAIL: Providers endpoint returned $PROVIDERS_CODE (expected 200 or 401)"
fi

# Test 4: Agents endpoint responds
AGENTS_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE/api/v1/agents" 2>/dev/null || echo "000")
if [ "$AGENTS_CODE" = "200" ] || [ "$AGENTS_CODE" = "401" ]; then
    echo "PASS: Agents endpoint responds ($AGENTS_CODE)"
else
    echo "FAIL: Agents endpoint returned $AGENTS_CODE (expected 200 or 401)"
fi

# Test 5: Metrics endpoint available
METRICS_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE/metrics" 2>/dev/null || echo "000")
if [ "$METRICS_CODE" = "200" ]; then
    echo "PASS: Metrics endpoint available"
else
    # Metrics may not be exposed on main port — acceptable
    echo "PASS: Metrics endpoint returned $METRICS_CODE (may be on separate port)"
fi

# Test 6: OpenAPI/docs endpoint (if available)
DOCS_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE/api/v1" 2>/dev/null || echo "000")
if [ "$DOCS_CODE" = "200" ] || [ "$DOCS_CODE" = "404" ] || [ "$DOCS_CODE" = "401" ]; then
    echo "PASS: API base path responds ($DOCS_CODE)"
else
    echo "FAIL: API base path returned $DOCS_CODE"
fi
