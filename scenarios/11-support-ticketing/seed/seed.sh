#!/usr/bin/env bash
set -euo pipefail

echo "Seeding scenario 11-support-ticketing..."

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
EXISTING=$(curl -sf "http://localhost:18080/api/v1/tickets" 2>/dev/null | grep -c "seed-ticket" 2>/dev/null || echo "0")
EXISTING=$(echo "$EXISTING" | tr -d '[:space:]')
if [ "${EXISTING:-0}" -gt "0" ] 2>/dev/null; then
    echo "Seed data already present, skipping..."
    exit 0
fi

echo "Creating seed tickets..."

# Low priority ticket
curl -sf -X POST http://localhost:18080/api/v1/tickets \
    -H "Content-Type: application/json" \
    -d '{"subject":"seed-ticket: Password reset not working","description":"User reports unable to reset password via email link.","priority":"low"}' || true

# Critical priority ticket
curl -sf -X POST http://localhost:18080/api/v1/tickets \
    -H "Content-Type: application/json" \
    -d '{"subject":"seed-ticket: Production database down","description":"All database queries failing with connection timeout.","priority":"critical"}' || true

echo "Seed complete."
