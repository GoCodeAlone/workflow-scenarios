#!/usr/bin/env bash
set -euo pipefail

echo "Seeding scenario 12-approval-workflow..."

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

# Check if seed data already exists
EXISTING=$(curl -sf "http://localhost:18080/api/v1/requests" 2>/dev/null | grep -c "seed-requester" 2>/dev/null || echo "0")
EXISTING=$(echo "$EXISTING" | tr -d '[:space:]')
if [ "${EXISTING:-0}" -gt "0" ] 2>/dev/null; then
    echo "Seed data already present, skipping..."
    exit 0
fi

echo "Creating seed approval requests..."

# Small auto-approve request ($50)
curl -sf -X POST http://localhost:18080/api/v1/requests \
    -H "Content-Type: application/json" \
    -d '{"description":"Office supplies","category":"supplies","amount":50,"requester":"seed-requester"}' || true

# Medium manager-level request ($500)
curl -sf -X POST http://localhost:18080/api/v1/requests \
    -H "Content-Type: application/json" \
    -d '{"description":"Team training subscription","category":"training","amount":500,"requester":"seed-requester"}' || true

# Large VP-level request ($2000)
curl -sf -X POST http://localhost:18080/api/v1/requests \
    -H "Content-Type: application/json" \
    -d '{"description":"New server hardware","category":"infrastructure","amount":2000,"requester":"seed-requester"}' || true

echo "Seed complete."
