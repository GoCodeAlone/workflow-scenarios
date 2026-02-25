#!/usr/bin/env bash
# Seed script for Scenario 07: No-Code Workflow
# Creates the initial admin user via the admin plugin's setup endpoint.
set -euo pipefail

echo "Seeding scenario 07-no-code-workflow..."

NAMESPACE="${NAMESPACE:-wf-scenario-07}"

# Wait for the workflow-server pod to be ready
echo "Waiting for workflow-server to be ready..."
kubectl wait --for=condition=ready pod -l app=workflow-server -n "$NAMESPACE" --timeout=120s

# Port-forward to the admin server (port 8081)
kubectl port-forward svc/workflow-server 18081:8081 -n "$NAMESPACE" &
PF_PID=$!
sleep 5

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

ADMIN_BASE="http://localhost:18081"

# Wait for the admin server to be ready
for i in $(seq 1 10); do
    if curl -sf "$ADMIN_BASE/api/v1/health" >/dev/null 2>&1 || \
       curl -sf "$ADMIN_BASE/api/v1/auth/setup-status" >/dev/null 2>&1; then
        echo "Admin server is ready"
        break
    fi
    echo "Waiting for admin server... ($i/10)"
    sleep 3
done

# Check if seed data already exists (admin user already set up)
SETUP_STATUS=$(curl -s "$ADMIN_BASE/api/v1/auth/setup-status" 2>/dev/null || echo "")
if echo "$SETUP_STATUS" | grep -q '"setup_done":true\|"setupDone":true\|"setup_complete":true'; then
    echo "Admin user already set up, skipping seed..."
    exit 0
fi

# Create the admin user via the setup endpoint
echo "Creating admin user via /api/v1/auth/setup..."
SETUP_RESP=$(curl -sf -X POST "$ADMIN_BASE/api/v1/auth/setup" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@scenario07.com","password":"TestPass123x","name":"Admin"}' 2>/dev/null || \
    curl -s -X POST "$ADMIN_BASE/api/v1/auth/setup" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@scenario07.com","password":"TestPass123x","name":"Admin"}' 2>/dev/null || echo "")
echo "Setup response: $SETUP_RESP"

echo "Seed complete."
