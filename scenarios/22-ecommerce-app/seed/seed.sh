#!/usr/bin/env bash
set -euo pipefail

echo "Seeding scenario 22-ecommerce-app..."

echo "Waiting for workflow-server to be ready..."
kubectl wait --for=condition=ready pod -l app=workflow-server -n "$NAMESPACE" --timeout=120s

kubectl port-forward svc/workflow-server 18022:8080 -n "$NAMESPACE" &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "Initializing database schema..."
curl -sf -X POST http://localhost:18022/internal/init-db || echo "DB init may have already run"

# Check if seed data already exists
EXISTING=$(curl -sf "http://localhost:18022/api/v1/products" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "0")
if [ "${EXISTING:-0}" -gt "0" ] 2>/dev/null; then
    echo "Seed data already present, skipping..."
    exit 0
fi

echo "Creating seed products..."

curl -sf -X POST http://localhost:18022/api/v1/products \
    -H "Content-Type: application/json" \
    -d '{"name":"Widget Pro","description":"A professional widget","price":29.99,"stock":100}' || true

curl -sf -X POST http://localhost:18022/api/v1/products \
    -H "Content-Type: application/json" \
    -d '{"name":"Gadget Plus","description":"An enhanced gadget","price":49.99,"stock":50}' || true

echo "Seed complete."
