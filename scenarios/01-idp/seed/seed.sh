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

# Create the admin user (setup endpoint only works when no users exist)
echo "Creating admin user via /api/auth/setup..."
SETUP_RESP=$(curl -sf -X POST http://localhost:18080/api/auth/setup \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@example.com","password":"TestPassword123!","name":"Admin User"}' || true)
echo "Setup response: $SETUP_RESP"

# Extract the admin token
ADMIN_TOKEN=$(echo "$SETUP_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || echo "")
if [ -z "$ADMIN_TOKEN" ]; then
    echo "Warning: could not extract admin token from setup response. Trying login..."
    LOGIN_RESP=$(curl -sf -X POST http://localhost:18080/api/auth/login \
        -H "Content-Type: application/json" \
        -d '{"email":"admin@example.com","password":"TestPassword123!"}' || echo "")
    ADMIN_TOKEN=$(echo "$LOGIN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || echo "")
fi

echo "Admin token: ${ADMIN_TOKEN:0:20}..."

# Create a second user using admin token
if [ -n "$ADMIN_TOKEN" ]; then
    echo "Creating regular user via /api/auth/users..."
    curl -sf -X POST http://localhost:18080/api/auth/users \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -d '{"email":"user@example.com","password":"TestPassword123!","name":"Regular User","role":"user"}' || true
else
    echo "Warning: no admin token, skipping regular user creation"
fi

# Clean up port-forward
kill $PF_PID 2>/dev/null || true

echo "Seed complete."
