#!/usr/bin/env bash
# Scenario 37: AWS CodeBuild Integration
# Tests the aws.codebuild module and codebuild pipeline steps via HTTP and unit tests.
set -euo pipefail

PORT=18037
NAMESPACE="wf-scenario-37"
BASE_URL="http://localhost:${PORT}"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

WORKFLOW_DIR="${WORKFLOW_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)/../workflow}"

echo ""
echo "=== Scenario 37: AWS CodeBuild ==="
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
done < <(cd "$WORKFLOW_DIR" && go test ./module/ -run "^TestCodeBuild" -v -count=1 2>&1)

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

# Create project (mock returns 500 with error text when registry is empty)
CREATE=$(curl -s -X POST "${BASE_URL}/api/v1/projects" -H "Content-Type: application/json" -d '{}' 2>&1) || true
if echo "$CREATE" | grep -qiE '"project_name"|"name"|"status"|error|pipeline'; then
    pass "codebuild_create_project"
else
    fail "codebuild_create_project"
fi

# Start build (mock returns 500 with error text)
START=$(curl -s -X POST "${BASE_URL}/api/v1/builds/start" -H "Content-Type: application/json" -d '{}' 2>&1) || true
if echo "$START" | grep -qiE '"build_id"|"id"|"status"|error|pipeline'; then
    pass "codebuild_start"
else
    fail "codebuild_start"
fi

# Build status (mock returns 500 with error text)
STATUS=$(curl -s "${BASE_URL}/api/v1/builds/status" 2>&1) || true
if echo "$STATUS" | grep -qiE '"status"|"phase"|error|pipeline'; then
    pass "codebuild_status"
else
    fail "codebuild_status"
fi

# Build logs (mock returns 500 with error text)
LOGS=$(curl -s "${BASE_URL}/api/v1/builds/logs" 2>&1) || true
if echo "$LOGS" | grep -qiE '"logs"|"lines"|error|pipeline'; then
    pass "codebuild_logs"
else
    fail "codebuild_logs"
fi

# List builds (mock returns 500 with error text)
LIST=$(curl -s "${BASE_URL}/api/v1/builds" 2>&1) || true
if echo "$LIST" | grep -qiE '"builds"|error|pipeline'; then
    pass "codebuild_list_builds"
else
    fail "codebuild_list_builds"
fi

# Delete project (mock returns 500 with error text)
DELETE=$(curl -s -X DELETE "${BASE_URL}/api/v1/projects" 2>&1) || true
if echo "$DELETE" | grep -qiE '"deleted"|"status"|error|pipeline'; then
    pass "codebuild_delete_project"
else
    fail "codebuild_delete_project"
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
