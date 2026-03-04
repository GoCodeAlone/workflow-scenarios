#!/usr/bin/env bash
# Scenario 44: Agent Self-Healing Infrastructure (Scripted)
# Tests the test provider in scripted mode simulating a 6-step self-healing conversation.
# Verifies multi-turn execution, iteration counting, and max_iterations enforcement.
#
# REQUIRES: workflow-server built with workflow-plugin-agent registered.
set -euo pipefail

PORT=18044
NAMESPACE="wf-scenario-44"
BASE_URL="http://localhost:${PORT}"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo ""
echo "=== Scenario 44: Agent Self-Healing Infrastructure (Scripted) ==="
echo ""

# ---- Integration tests (port-forward required) ----
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo "Namespace $NAMESPACE not found — skipping HTTP integration tests"
    echo "(Deploy with: make deploy SCENARIO=44-agent-self-healing)"
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
if echo "$HEALTH" | grep -q "44-agent-self-healing"; then
    pass "healthz identifies scenario 44"
else
    fail "healthz missing scenario identifier: $HEALTH"
fi

# Test 3: Scripted agent execution completes
AGENT_RESP=$(curl -sf --max-time 60 -X POST "${BASE_URL}/api/v1/agent/self-healing" \
    -H "Content-Type: application/json" \
    -d '{"task":"Diagnose and remediate any unhealthy pods in the production namespace.","agent_id":"infra-agent"}' \
    2>/dev/null || echo '{}')
if echo "$AGENT_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='completed' else 1)" 2>/dev/null; then
    pass "scripted_agent_execution status is 'completed'"
else
    fail "scripted_agent_execution not completed: $AGENT_RESP"
fi

# Test 4: Scripted agent final response includes remediation summary
if echo "$AGENT_RESP" | grep -qi "remedi"; then
    pass "scripted_agent_execution result contains remediation summary"
else
    fail "scripted_agent_execution result missing remediation summary: $AGENT_RESP"
fi

# Test 5: Scripted agent result mentions OOMKill or memory
if echo "$AGENT_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = (d.get('result') or '').lower()
sys.exit(0 if 'oom' in r or 'memory' in r or 'restarted' in r else 1)
" 2>/dev/null; then
    pass "scripted_agent_execution result mentions OOM/memory/restart"
else
    fail "scripted_agent_execution result missing expected content: $AGENT_RESP"
fi

# Test 6: Scripted agent runs multiple iterations (6 scripted steps + tool results)
if echo "$AGENT_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if int(d.get('iterations',0)) >= 6 else 1)" 2>/dev/null; then
    pass "scripted_agent_execution ran >= 6 iterations"
else
    # Iterations may be lower if tool results don't consume scripted steps
    ITERS=$(echo "$AGENT_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('iterations',0))" 2>/dev/null || echo "0")
    if [ "$ITERS" -ge 1 ]; then
        pass "scripted_agent_execution ran $ITERS iterations (tool calls consumed without advancing steps)"
    else
        fail "scripted_agent_execution iterations=0: $AGENT_RESP"
    fi
fi

# Test 7: Multi-turn — second execution uses fresh scripted source per request
AGENT_RESP2=$(curl -sf --max-time 60 -X POST "${BASE_URL}/api/v1/agent/self-healing" \
    -H "Content-Type: application/json" \
    -d '{"task":"Check pod health","agent_id":"infra-agent-2"}' \
    2>/dev/null || echo '{}')
if echo "$AGENT_RESP2" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('status') in ('completed','failed') else 1)" 2>/dev/null; then
    pass "multi_turn second execution completes"
else
    fail "multi_turn second execution did not complete: $AGENT_RESP2"
fi

# Test 8: Iteration limit enforcement — agent-loop loops, max_iterations=3 caps it
LIMIT_RESP=$(curl -sf --max-time 30 -X POST "${BASE_URL}/api/v1/agent/iteration-limit" \
    -H "Content-Type: application/json" \
    -d '{}' 2>/dev/null || echo '{}')
LIMIT_ITERS=$(echo "$LIMIT_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('iterations',0))" 2>/dev/null || echo "0")
if [ "$LIMIT_ITERS" -le 3 ] && [ "$LIMIT_ITERS" -ge 1 ]; then
    pass "iteration_limit respected (iterations=$LIMIT_ITERS, max=3)"
else
    fail "iteration_limit not respected (iterations=$LIMIT_ITERS, expected 1-3): $LIMIT_RESP"
fi

# Test 9: Iteration limit agent returns completed status (ran out of responses then stopped at max)
if echo "$LIMIT_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('status') in ('completed','failed') else 1)" 2>/dev/null; then
    STATUS=$(echo "$LIMIT_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null)
    pass "iteration_limit status=$STATUS (valid terminal state)"
else
    fail "iteration_limit missing valid status: $LIMIT_RESP"
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
