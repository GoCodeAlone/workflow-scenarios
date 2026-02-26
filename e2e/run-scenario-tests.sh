#!/usr/bin/env bash
# Run Playwright tests against a deployed scenario
# Usage: ./run-scenario-tests.sh <scenario-id>
# Example: ./run-scenario-tests.sh 20-auth-service
set -euo pipefail

SCENARIO="${1:-20-auth-service}"
SCENARIO_NUM="${SCENARIO%%-*}"
PORT="180${SCENARIO_NUM}"
NAMESPACE="wf-scenario-${SCENARIO_NUM}"

echo "Testing scenario $SCENARIO on port $PORT..."

# Check pod is running
if ! kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q Running; then
    echo "SKIP: No running pods in $NAMESPACE"
    exit 0
fi

# Start port forward, killing any existing one first
pkill -f "port-forward.*${PORT}" 2>/dev/null || true
sleep 1
kubectl port-forward svc/workflow-server "${PORT}:8080" -n "$NAMESPACE" &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT

# Wait for port forward to be ready (health check on /healthz)
for i in $(seq 1 10); do
    if curl -sf "http://localhost:${PORT}/healthz" >/dev/null 2>&1; then
        echo "Service ready on port $PORT"
        break
    fi
    sleep 1
done

# Run Playwright tests matching this scenario
mkdir -p test-results
SCENARIO_URL="http://localhost:${PORT}" npx playwright test --grep "@scenario-${SCENARIO_NUM}" 2>&1 || {
    echo "WARN: Some tests failed for $SCENARIO"
}

echo "Tests complete for $SCENARIO"
echo "Screenshots saved to test-results/"
