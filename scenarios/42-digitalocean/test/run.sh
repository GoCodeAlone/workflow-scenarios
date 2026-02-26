#!/usr/bin/env bash
# Scenario 42: DigitalOcean Cloud Provider Integration
# Tests platform.doks, platform.do_networking, platform.do_dns, platform.do_app,
# and the DO pipeline steps via HTTP and unit tests.
set -euo pipefail

PORT=18042
NAMESPACE="wf-scenario-42"
BASE_URL="http://localhost:${PORT}"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

WORKFLOW_DIR="${WORKFLOW_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)/../workflow}"

echo ""
echo "=== Scenario 42: DigitalOcean Cloud Provider Integration ==="
echo ""

# ---- Unit tests ----
run_go_tests() {
    local pkg="$1"
    local pattern="${2:-}"
    local run_flag=""
    [ -n "$pattern" ] && run_flag="-run $pattern"

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
    done < <(cd "$WORKFLOW_DIR" && go test "$pkg" $run_flag -v -count=1 2>&1)
}

run_go_tests "./module/" "^TestDO_|^TestPlatformDO|^TestPlatformDOKS"

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
for i in $(seq 1 30); do
    if curl -sf --max-time 10 "${BASE_URL}/healthz" &>/dev/null; then break; fi
    sleep 2
done

# Health check
if curl -sf --max-time 15 "${BASE_URL}/healthz" | grep -q '"status":"ok"'; then
    pass "healthz"
else
    fail "healthz"
fi

# Deploy the DO App Platform app (mock returns 200 with empty body)
if curl -sf -X POST "${BASE_URL}/api/v1/do/deploy" \
    -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1; then
    pass "do_deploy"
else
    fail "do_deploy"
fi

# Check app status (mock returns 200 with empty body)
if curl -sf --max-time 15 "${BASE_URL}/api/v1/do/status" >/dev/null 2>&1; then
    pass "do_status"
else
    fail "do_status"
fi

# Retrieve app logs (mock returns 200 with empty body)
if curl -sf --max-time 15 "${BASE_URL}/api/v1/do/logs" >/dev/null 2>&1; then
    pass "do_logs"
else
    fail "do_logs"
fi

# Scale app instances (mock returns 200 with empty body)
if curl -sf -X POST "${BASE_URL}/api/v1/do/scale" \
    -H "Content-Type: application/json" \
    -d '{"instances":4}' >/dev/null 2>&1; then
    pass "do_scale"
else
    fail "do_scale"
fi

# Destroy the app deployment (mock returns 200 with empty body)
if curl -sf -X DELETE "${BASE_URL}/api/v1/do" >/dev/null 2>&1; then
    pass "do_destroy"
else
    fail "do_destroy"
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
