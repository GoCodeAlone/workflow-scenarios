#!/usr/bin/env bash
# Scenario 39: Distributed Tracing Propagation
# Tests the tracing.propagation module and trace pipeline steps via HTTP and unit tests.
set -euo pipefail

PORT=18039
NAMESPACE="wf-scenario-39"
BASE_URL="http://localhost:${PORT}"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

WORKFLOW_DIR="${WORKFLOW_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)/../workflow}"

echo ""
echo "=== Scenario 39: Distributed Tracing ==="
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

run_go_tests "./module/" "^TestOTelTracing|^TestOTelMiddleware|^TestTracPipeline"
run_go_tests "./plugins/observability/" ""

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

# Start a new trace span (mock returns 200 with empty body)
if curl -sf -X POST "${BASE_URL}/api/v1/trace/start" \
    -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1; then
    pass "trace_start"
else
    fail "trace_start"
fi

# Inject trace context into carrier headers (mock returns 200 with empty body)
if curl -sf -X POST "${BASE_URL}/api/v1/trace/inject" \
    -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1; then
    pass "trace_inject"
else
    fail "trace_inject"
fi

# Extract trace context from inbound headers (mock returns 200 with empty body)
if curl -sf -X POST "${BASE_URL}/api/v1/trace/extract" \
    -H "Content-Type: application/json" \
    -H "traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" \
    -d '{"headers":{"traceparent":"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}}' >/dev/null 2>&1; then
    pass "trace_extract"
else
    fail "trace_extract"
fi

# Annotate a span with events/attributes (mock returns 200 with empty body)
if curl -sf -X POST "${BASE_URL}/api/v1/trace/annotate" \
    -H "Content-Type: application/json" -d '{"event":"cache.miss","attributes":{"key":"user:42"}}' >/dev/null 2>&1; then
    pass "trace_annotate"
else
    fail "trace_annotate"
fi

# Link current span to remote parent trace (mock returns 200 with empty body)
if curl -sf -X POST "${BASE_URL}/api/v1/trace/link" \
    -H "Content-Type: application/json" \
    -d '{"parent_headers":{"traceparent":"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}}' >/dev/null 2>&1; then
    pass "trace_link"
else
    fail "trace_link"
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
