#!/usr/bin/env bash
set -euo pipefail

echo "Seeding scenario 21-payment-service..."

NS="${NAMESPACE:-wf-scenario-21}"
PORT=18021
BASE="http://localhost:$PORT"

echo "Waiting for workflow-server to be ready..."
kubectl wait --for=condition=ready pod -l app=workflow-server -n "$NS" --timeout=120s

kubectl port-forward svc/workflow-server "$PORT":8080 -n "$NS" &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

# Initialise database schema
echo "Initialising database schema..."
INIT_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/internal/init-db" 2>/dev/null || echo "000")
echo "  init-db: $INIT_CODE"

echo "Seed complete."
