#!/usr/bin/env bash
set -euo pipefail

echo "Seeding scenario 08-data-pipeline..."

echo "Waiting for workflow-server to be ready..."
kubectl wait --for=condition=ready pod -l app=workflow-server -n "$NAMESPACE" --timeout=120s

kubectl port-forward svc/workflow-server 18080:8080 -n "$NAMESPACE" &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "Initializing database schema..."
curl -sf -X POST http://localhost:18080/internal/init-db || echo "DB init may have already run"

echo "Ingesting seed records through bento pipeline..."
curl -sf -X POST http://localhost:18080/api/pipeline/ingest \
    -H "Content-Type: application/json" \
    -d '{"name":"seed-record-001","value":10.0,"category":"orders"}' || true

curl -sf -X POST http://localhost:18080/api/pipeline/ingest \
    -H "Content-Type: application/json" \
    -d '{"name":"seed-record-002","value":25.5,"category":"events"}' || true

echo "Seed complete."
