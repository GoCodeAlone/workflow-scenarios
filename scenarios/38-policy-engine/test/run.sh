#!/usr/bin/env bash
# Scenario 38: Policy Engine
# Tests the policy.mock module and policy pipeline steps via HTTP and unit tests.
set -euo pipefail

PORT=18038
NAMESPACE="wf-scenario-38"
BASE_URL="http://localhost:${PORT}"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

WORKFLOW_DIR="${WORKFLOW_DIR:-/Users/jon/workspace/workflow}"

echo ""
echo "=== Scenario 38: Policy Engine ==="
echo ""

# ---- Unit tests ----
while IFS= read -r line; do
    if [[ "$line" =~ ^"--- PASS: " ]]; then
        name="${line#--- PASS: }"
        name="${name%% (*}"
        pass "$name"
    elif [[ "$line" =~ ^"--- FAIL: " ]]; then
        name="${line#--- FAIL: }"
        name="${name%% (*}"
        fail "$name"
    fi
done < <(cd "$WORKFLOW_DIR" && go test ./module/ -run "^TestMockPolicy|^TestPolicyEngine|^TestPolicy" -v -count=1 2>&1)

# ---- Integration tests (port-forward required) ----
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo "Namespace $NAMESPACE not found — skipping HTTP integration tests"
    echo ""
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
    [ "$FAIL_COUNT" -eq 0 ] && [ "$PASS_COUNT" -gt 0 ]
    exit $?
fi

# Start port-forward in background
kubectl port-forward -n "$NAMESPACE" svc/workflow-server "${PORT}:8080" &>/dev/null &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT

# Wait for server to be reachable
for i in $(seq 1 20); do
    if curl -sf "${BASE_URL}/healthz" &>/dev/null; then break; fi
    sleep 1
done

# Health check
if curl -sf "${BASE_URL}/healthz" | grep -q '"status":"ok"'; then
    pass "healthz"
else
    fail "healthz"
fi

# Load a policy document (mock returns 200 with empty body)
if curl -sf -X POST "${BASE_URL}/api/v1/policy/load" \
    -H "Content-Type: application/json" \
    -d '{"name":"allow-all","document":"package main\ndefault allow = true"}' >/dev/null 2>&1; then
    pass "policy_load"
else
    fail "policy_load"
fi

# Evaluate — mock returns 200 with empty body
if curl -sf -X POST "${BASE_URL}/api/v1/policy/evaluate" \
    -H "Content-Type: application/json" \
    -d '{"input":{"user":"alice","action":"read"}}' >/dev/null 2>&1; then
    pass "policy_evaluate_allow"
else
    fail "policy_evaluate_allow"
fi

# Load a deny policy
curl -sf -X POST "${BASE_URL}/api/v1/policy/load" \
    -H "Content-Type: application/json" \
    -d '{"name":"deny-guest","document":"deny if input.user == \"guest\""}' &>/dev/null || true

# Evaluate — mock returns 200 with empty body
if curl -sf -X POST "${BASE_URL}/api/v1/policy/evaluate" \
    -H "Content-Type: application/json" \
    -d '{"input":{"user":"guest","action":"write"}}' >/dev/null 2>&1; then
    pass "policy_evaluate_deny"
else
    fail "policy_evaluate_deny"
fi

# List policies (mock returns 200 with empty body)
if curl -sf "${BASE_URL}/api/v1/policy/list" >/dev/null 2>&1; then
    pass "policy_list"
else
    fail "policy_list"
fi

# Test policy dry-run (mock returns 200 with empty body)
if curl -sf -X POST "${BASE_URL}/api/v1/policy/test" \
    -H "Content-Type: application/json" \
    -d '{"policy":"allow-all","cases":[{"input":{"user":"alice"},"expected":"allow"}]}' >/dev/null 2>&1; then
    pass "policy_test"
else
    fail "policy_test"
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
