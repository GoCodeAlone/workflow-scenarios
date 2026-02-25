#!/usr/bin/env bash
set -euo pipefail

echo "Seeding scenario 17-full-lifecycle (Phase 1 — v1-contacts)..."

echo "Waiting for workflow-server to be ready..."
kubectl wait --for=condition=ready pod -l app=workflow-server -n "$NAMESPACE" --timeout=120s

kubectl port-forward svc/workflow-server 18017:8080 -n "$NAMESPACE" &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE="http://localhost:18017"

# Initialise v1 database schema
echo "Initialising v1 database schema..."
INIT_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/internal/init-db" 2>/dev/null || echo "000")
echo "  init-db: $INIT_CODE"

# Check if seed data already exists
EXISTING=$(curl -sf "$BASE/api/v1/contacts" 2>/dev/null | python3 -c "import json,sys; rows=json.load(sys.stdin); print(len(rows))" 2>/dev/null || echo "0")
EXISTING=$(echo "$EXISTING" | tr -d '[:space:]')
if [ "${EXISTING:-0}" -gt "0" ] 2>/dev/null; then
    echo "Seed data already present ($EXISTING contacts), skipping..."
    exit 0
fi

# Create seed contacts
echo "Creating seed contacts..."

C1=$(curl -sf -X POST "$BASE/api/v1/contacts" \
    -H "Content-Type: application/json" \
    -d '{"name":"Alice Smith","email":"alice@acme.com","phone":"+1-555-0101","company":"Acme Corp"}' \
    2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
echo "  alice: id=$C1"

C2=$(curl -sf -X POST "$BASE/api/v1/contacts" \
    -H "Content-Type: application/json" \
    -d '{"name":"Bob Jones","email":"bob@widgets.com","phone":"+1-555-0102","company":"Widgets Inc"}' \
    2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
echo "  bob: id=$C2"

C3=$(curl -sf -X POST "$BASE/api/v1/contacts" \
    -H "Content-Type: application/json" \
    -d '{"name":"Carol White","email":"carol@startup.io","phone":"+1-555-0103","company":"StartupIO"}' \
    2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
echo "  carol: id=$C3"

echo "Seed complete. Created 3 Phase 1 contacts."
