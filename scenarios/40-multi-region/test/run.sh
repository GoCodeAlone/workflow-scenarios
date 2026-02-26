#!/usr/bin/env bash
# Scenario 40: Multi-Region Tenant Deployment
# Tests the platform.region and platform.region_router modules via HTTP and unit tests.
set -euo pipefail

PORT=18040
NAMESPACE="wf-scenario-40"
BASE_URL="http://localhost:${PORT}"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

WORKFLOW_DIR="${WORKFLOW_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)/../workflow}"

echo ""
echo "=== Scenario 40: Multi-Region Tenant Deployment ==="
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

run_go_tests "./module/" "^TestMultiRegion|^TestRegion"

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

# Deploy to a region (mock returns 200 with empty body)
if curl -sf -X POST "${BASE_URL}/api/v1/regions/deploy" \
    -H "Content-Type: application/json" \
    -d '{"region":"us-east-1","tenant_id":"tenant-abc"}' >/dev/null 2>&1; then
    pass "region_deploy"
else
    fail "region_deploy"
fi

# Check health status across all regions (mock returns 200 with empty body)
if curl -sf "${BASE_URL}/api/v1/regions/status" >/dev/null 2>&1; then
    pass "region_status"
else
    fail "region_status"
fi

# Trigger failover (mock returns 200 with empty body)
if curl -sf -X POST "${BASE_URL}/api/v1/regions/failover" \
    -H "Content-Type: application/json" \
    -d '{"from_region":"us-east-1","to_region":"us-west-2"}' >/dev/null 2>&1; then
    pass "region_failover"
else
    fail "region_failover"
fi

# Adjust traffic weights (mock returns 200 with empty body)
if curl -sf -X POST "${BASE_URL}/api/v1/regions/weight" \
    -H "Content-Type: application/json" \
    -d '{"weights":{"us-east-1":50,"us-west-2":40,"eu-west-1":10}}' >/dev/null 2>&1; then
    pass "region_weight"
else
    fail "region_weight"
fi

# Promote a region (mock returns 200 with empty body)
if curl -sf -X POST "${BASE_URL}/api/v1/regions/promote" \
    -H "Content-Type: application/json" \
    -d '{"region":"us-west-2"}' >/dev/null 2>&1; then
    pass "region_promote"
else
    fail "region_promote"
fi

# Sync state across regions (mock returns 200 with empty body)
if curl -sf -X POST "${BASE_URL}/api/v1/regions/sync" \
    -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1; then
    pass "region_sync"
else
    fail "region_sync"
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
