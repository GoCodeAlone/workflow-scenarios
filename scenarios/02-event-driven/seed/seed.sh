#!/usr/bin/env bash
set -euo pipefail

echo "Seeding scenario 02-event-driven..."

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
EXISTING=$(curl -sf "http://localhost:18080/api/events" 2>/dev/null | grep -c "seed-001" 2>/dev/null || echo "0")
EXISTING=$(echo "$EXISTING" | tr -d '[:space:]')
if [ "${EXISTING:-0}" -gt "0" ] 2>/dev/null; then
    echo "Seed data already present, skipping..."
    exit 0
fi

echo "Publishing seed events..."
curl -sf -X POST http://localhost:18080/api/events \
    -H "Content-Type: application/json" \
    -d '{"type":"order.created","payload":{"order_id":"seed-001","amount":99.99}}' || true

curl -sf -X POST http://localhost:18080/api/events \
    -H "Content-Type: application/json" \
    -d '{"type":"user.signup","payload":{"user_id":"seed-user-01","email":"seed@example.com"}}' || true

echo "Seed complete."
