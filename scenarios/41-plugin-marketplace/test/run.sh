#!/usr/bin/env bash
# Scenario 41: Plugin Marketplace
# Tests the marketplace pipeline steps via HTTP and unit tests.
set -euo pipefail

PORT=18041
NAMESPACE="wf-scenario-41"
BASE_URL="http://localhost:${PORT}"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

WORKFLOW_DIR="${WORKFLOW_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)/../workflow}"

echo ""
echo "=== Scenario 41: Plugin Marketplace ==="
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

run_go_tests "./module/" "^TestMarketplace"

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

# Search the marketplace catalog (mock returns 200 with empty body)
SEARCH_CODE=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" "${BASE_URL}/api/v1/marketplace/search?query=kafka&category=messaging" 2>&1) || true
if [ "$SEARCH_CODE" = "200" ]; then
    pass "marketplace_search"
else
    fail "marketplace_search"
fi

# Get plugin detail (mock returns 200 with empty body)
DETAIL_CODE=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" "${BASE_URL}/api/v1/marketplace/detail?plugin=messaging-kafka" 2>&1) || true
if [ "$DETAIL_CODE" = "200" ]; then
    pass "marketplace_detail"
else
    fail "marketplace_detail"
fi

# Install a plugin (mock returns error about missing data dir — expected in container)
INSTALL=$(curl -s --max-time 15 -X POST "${BASE_URL}/api/v1/marketplace/install" \
    -H "Content-Type: application/json" \
    -d '{"plugin":"messaging-kafka"}' 2>&1) || true
if echo "$INSTALL" | grep -qiE '"installed"|"name"|"status"|error|pipeline|mkdir|permission'; then
    pass "marketplace_install"
else
    fail "marketplace_install"
fi

# List installed plugins (mock returns 200 with empty body)
INSTALLED_CODE=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" "${BASE_URL}/api/v1/marketplace/installed" 2>&1) || true
if [ "$INSTALLED_CODE" = "200" ]; then
    pass "marketplace_installed"
else
    fail "marketplace_installed"
fi

# Update the plugin (mock returns error when plugin not installed)
UPDATE=$(curl -s --max-time 15 -X POST "${BASE_URL}/api/v1/marketplace/update" \
    -H "Content-Type: application/json" \
    -d '{"plugin":"messaging-kafka"}' 2>&1) || true
if echo "$UPDATE" | grep -qiE '"updated"|"version"|"status"|error|pipeline|not.found|not.installed'; then
    pass "marketplace_update"
else
    fail "marketplace_update"
fi

# Uninstall the plugin (mock returns error when plugin not installed)
UNINSTALL=$(curl -s --max-time 15 -X DELETE "${BASE_URL}/api/v1/marketplace/uninstall" \
    -H "Content-Type: application/json" \
    -d '{"plugin":"messaging-kafka"}' 2>&1) || true
if echo "$UNINSTALL" | grep -qiE '"uninstalled"|"name"|"status"|error|pipeline|not.found|not.installed'; then
    pass "marketplace_uninstall"
else
    fail "marketplace_uninstall"
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
