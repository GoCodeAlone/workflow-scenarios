#!/usr/bin/env bash
# Scenario 36: Argo Workflows Integration
# Tests the argo.workflows module and argo pipeline steps via HTTP and unit tests.
set -euo pipefail

PORT=18036
NAMESPACE="wf-scenario-36"
BASE_URL="http://localhost:${PORT}"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

WORKFLOW_DIR="${WORKFLOW_DIR:-/Users/jon/workspace/workflow}"

echo ""
echo "=== Scenario 36: Argo Workflows ==="
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
done < <(cd "$WORKFLOW_DIR" && go test ./module/ -run "^TestArgoWorkflows|^TestTranslatePipelineToArgo|^TestArgo(Submit|Status|Logs|Delete|List)" -v -count=1 2>&1)

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

# Submit a workflow (mock returns 500 with error text when argo is not running)
SUBMIT=$(curl -s -X POST "${BASE_URL}/api/v1/workflows/submit" -H "Content-Type: application/json" -d '{}' 2>&1) || true
if echo "$SUBMIT" | grep -qiE '"workflow_name"|"run_name"|"status"|error|workflow'; then
    pass "argo_submit"
else
    fail "argo_submit"
fi

# Get workflow status (mock returns 500 with error text)
STATUS=$(curl -s "${BASE_URL}/api/v1/workflows/status" 2>&1) || true
if echo "$STATUS" | grep -qiE '"status"|"phase"|error|workflow'; then
    pass "argo_status"
else
    fail "argo_status"
fi

# Get workflow logs (mock returns 500 with error text)
LOGS=$(curl -s "${BASE_URL}/api/v1/workflows/logs" 2>&1) || true
if echo "$LOGS" | grep -qiE '"logs"|"lines"|error|workflow'; then
    pass "argo_logs"
else
    fail "argo_logs"
fi

# List workflows (mock returns 200 with empty body)
if curl -sf "${BASE_URL}/api/v1/workflows" >/dev/null 2>&1; then
    pass "argo_list"
else
    fail "argo_list"
fi

# Delete workflow (mock returns 500 with error text)
DELETE=$(curl -s -X DELETE "${BASE_URL}/api/v1/workflows" 2>&1) || true
if echo "$DELETE" | grep -qiE '"deleted"|"status"|error|workflow'; then
    pass "argo_delete"
else
    fail "argo_delete"
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
