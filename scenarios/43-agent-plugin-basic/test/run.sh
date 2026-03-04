#!/usr/bin/env bash
# Scenario 43: Agent Plugin Basic Integration
# Tests agent.provider (mock), step.agent_execute, and step.provider_models
# via HTTP integration tests against a running workflow-server with the agent plugin.
#
# REQUIRES: workflow-server built with workflow-plugin-agent registered.
# The standard workflow-server:local image does NOT include the agent plugin.
set -euo pipefail

PORT=18043
NAMESPACE="wf-scenario-43"
BASE_URL="http://localhost:${PORT}"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo ""
echo "=== Scenario 43: Agent Plugin Basic Integration ==="
echo ""

# ---- Integration tests (port-forward required) ----
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo "Namespace $NAMESPACE not found — skipping HTTP integration tests"
    echo "(Deploy with: make deploy SCENARIO=43-agent-plugin-basic)"
    echo ""
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
    exit 0
fi

# Start port-forward in background
kubectl port-forward -n "$NAMESPACE" svc/workflow-server "${PORT}:8080" &>/dev/null &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT

# Wait for server to be reachable
for i in $(seq 1 30); do
    if curl -sf --max-time 10 "${BASE_URL}/healthz" &>/dev/null; then break; fi
    sleep 2
done

# Test 1: Health check
if curl -sf --max-time 15 "${BASE_URL}/healthz" | grep -q '"status":"ok"'; then
    pass "healthz"
else
    fail "healthz"
fi

# Test 2: Health check identifies scenario
HEALTH=$(curl -sf --max-time 15 "${BASE_URL}/healthz" 2>/dev/null || echo '{}')
if echo "$HEALTH" | grep -q "43-agent-plugin-basic"; then
    pass "healthz identifies scenario 43"
else
    fail "healthz missing scenario identifier: $HEALTH"
fi

# Test 3: Agent run returns 200
AGENT_RESP=$(curl -sf --max-time 30 -X POST "${BASE_URL}/api/v1/agent/run" \
    -H "Content-Type: application/json" \
    -d '{"task":"What is the answer to the ultimate question?","agent_id":"test-agent-1"}' 2>/dev/null || echo '{}')
if echo "$AGENT_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('result') else 1)" 2>/dev/null; then
    pass "agent_run returns result field"
else
    fail "agent_run missing result field: $AGENT_RESP"
fi

# Test 4: Agent result contains expected mock response content
if echo "$AGENT_RESP" | grep -q "42"; then
    pass "agent_run result contains '42' from mock response"
else
    fail "agent_run result does not contain '42': $AGENT_RESP"
fi

# Test 5: Agent status is 'completed'
if echo "$AGENT_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='completed' else 1)" 2>/dev/null; then
    pass "agent_run status is 'completed'"
else
    fail "agent_run status not 'completed': $AGENT_RESP"
fi

# Test 6: Agent iterations field present and > 0
if echo "$AGENT_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if int(d.get('iterations',0)) > 0 else 1)" 2>/dev/null; then
    pass "agent_run iterations > 0"
else
    fail "agent_run iterations missing or zero: $AGENT_RESP"
fi

# Test 7: Provider models for mock type returns known model
MODELS_RESP=$(curl -sf --max-time 15 -X POST "${BASE_URL}/api/v1/provider/models" \
    -H "Content-Type: application/json" \
    -d '{"type":"mock"}' 2>/dev/null || echo '{}')
if echo "$MODELS_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('success') else 1)" 2>/dev/null; then
    pass "provider_models success=true for mock"
else
    fail "provider_models not successful: $MODELS_RESP"
fi

# Test 8: Provider models returns at least one model
if echo "$MODELS_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if len(d.get('models',[])) > 0 else 1)" 2>/dev/null; then
    pass "provider_models returns at least one model"
else
    fail "provider_models returned empty models list: $MODELS_RESP"
fi

# Test 9: Provider models for mock returns 'mock-default'
if echo "$MODELS_RESP" | grep -q "mock-default"; then
    pass "provider_models includes mock-default model"
else
    fail "provider_models missing mock-default: $MODELS_RESP"
fi

# Test 10: Agent run without agent_id defaults gracefully
ANON_RESP=$(curl -sf --max-time 30 -X POST "${BASE_URL}/api/v1/agent/run" \
    -H "Content-Type: application/json" \
    -d '{"task":"Simple task"}' 2>/dev/null || echo '{}')
if echo "$ANON_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='completed' else 1)" 2>/dev/null; then
    pass "agent_run without agent_id completes successfully"
else
    fail "agent_run without agent_id failed: $ANON_RESP"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ] && [ "$PASS_COUNT" -gt 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED"
    exit 1
fi
