#!/usr/bin/env bash
set -euo pipefail

echo "Seeding scenario 16-progressive-orders (Phase 1 — v1-basic-orders)..."

echo "Waiting for workflow-server to be ready..."
kubectl wait --for=condition=ready pod -l app=workflow-server -n "$NAMESPACE" --timeout=120s

kubectl port-forward svc/workflow-server 18016:8080 -n "$NAMESPACE" &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE="http://localhost:18016"

# Initialise v1 database schema
echo "Initialising v1 database schema..."
INIT_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/internal/init-db" 2>/dev/null || echo "000")
echo "  init-db: $INIT_CODE"

# Check if seed data already exists
EXISTING=$(curl -sf "$BASE/api/v1/orders" 2>/dev/null | python3 -c "import json,sys; rows=json.load(sys.stdin); print(len(rows))" 2>/dev/null || echo "0")
EXISTING=$(echo "$EXISTING" | tr -d '[:space:]')
if [ "${EXISTING:-0}" -gt "0" ] 2>/dev/null; then
    echo "Seed data already present ($EXISTING orders), skipping..."
    exit 0
fi

# Create 3 seed orders
echo "Creating seed orders..."

ORDER1=$(curl -sf -X POST "$BASE/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d '{"customer_email":"alice@example.com","items":["widget-a","widget-b"],"total":49.99}' \
    2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
echo "  order 1: $ORDER1"

ORDER2=$(curl -sf -X POST "$BASE/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d '{"customer_email":"bob@example.com","items":["gadget-x"],"total":129.00}' \
    2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
echo "  order 2: $ORDER2"

ORDER3=$(curl -sf -X POST "$BASE/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d '{"customer_email":"carol@example.com","items":["item-one","item-two","item-three"],"total":75.50}' \
    2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
echo "  order 3: $ORDER3"

echo "Seed complete. Created 3 Phase 1 orders."
