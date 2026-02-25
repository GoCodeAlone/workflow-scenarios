#!/usr/bin/env bash
set -euo pipefail

echo "Seeding scenario 01-idp..."

# Wait for the workflow-server to be ready
echo "Waiting for workflow-server to be ready..."
kubectl wait --for=condition=ready pod -l app=workflow-server -n "$NAMESPACE" --timeout=60s

# Port-forward to the service
kubectl port-forward svc/workflow-server 18080:8080 -n "$NAMESPACE" &
PF_PID=$!
sleep 3

# Create test users
echo "Creating test user..."
curl -sf -X POST http://localhost:18080/api/auth/register \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@example.com","password":"TestPassword123!"}' || true

echo "Creating second test user..."
curl -sf -X POST http://localhost:18080/api/auth/register \
    -H "Content-Type: application/json" \
    -d '{"email":"user@example.com","password":"TestPassword123!"}' || true

# Clean up port-forward
kill $PF_PID 2>/dev/null || true

echo "Seed complete."
