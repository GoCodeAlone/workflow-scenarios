#!/usr/bin/env bash
# Seed script for Scenario 24: Artifact Store
# Uploads a few sample artifacts so the test suite has data to work with.

set -euo pipefail

NS="${NAMESPACE:-wf-scenario-24}"
PORT=18024
BASE="http://localhost:$PORT"

echo "Seeding scenario 24 artifacts..."

# Set up port-forward
kubectl wait --for=condition=ready pod -l app=workflow-server -n "$NS" --timeout=120s
kubectl port-forward svc/workflow-server "$PORT":8080 -n "$NS" &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

# Upload a sample build artifact (best-effort — shell_exec requires Docker sandbox)
CONTENT=$(echo "sample binary content v1.0" | base64)
curl -s -X POST "$BASE/api/v1/artifacts/upload" \
  -H "Content-Type: application/json" \
  -d "{\"key\":\"builds/seed/app-v1.0.bin\",\"content\":\"$CONTENT\",\"metadata\":{\"version\":\"1.0\",\"commit\":\"abc123\"}}" \
  > /dev/null && echo "Seeded: builds/seed/app-v1.0.bin" || echo "WARNING: upload skipped (shell_exec sandbox unavailable)"

# Upload a sample log file
LOG_CONTENT=$(echo "Build log: all tests passed" | base64)
curl -s -X POST "$BASE/api/v1/artifacts/upload" \
  -H "Content-Type: application/json" \
  -d "{\"key\":\"logs/seed/build.log\",\"content\":\"$LOG_CONTENT\",\"metadata\":{\"version\":\"1.0\"}}" \
  > /dev/null && echo "Seeded: logs/seed/build.log" || echo "WARNING: upload skipped (shell_exec sandbox unavailable)"

echo "Seed complete."
