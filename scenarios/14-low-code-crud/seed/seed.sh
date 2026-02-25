#!/usr/bin/env bash
set -euo pipefail

echo "Seeding scenario 14-low-code-crud..."

echo "Waiting for workflow-server to be ready..."
kubectl wait --for=condition=ready pod -l app=workflow-server -n "$NAMESPACE" --timeout=120s

kubectl port-forward svc/workflow-server 18080:8080 -n "$NAMESPACE" &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE="http://localhost:18080"

# Initialise database schema
echo "Initialising database schema..."
INIT_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/internal/init-db" 2>/dev/null || echo "000")
echo "  init-db: $INIT_CODE"

# Register the seed admin user (idempotent — re-register is a no-op or 409)
echo "Registering seed user..."
REG_RESP=$(curl -sf -X POST "$BASE/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@example.com","password":"TestPassword123!","name":"Admin User"}' 2>/dev/null || echo "{}")
echo "  register: $REG_RESP"

# Login to get a token
echo "Logging in..."
LOGIN_RESP=$(curl -sf -X POST "$BASE/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@example.com","password":"TestPassword123!"}' 2>/dev/null || echo "{}")
TOKEN=$(echo "$LOGIN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || echo "")
echo "  token: ${TOKEN:0:20}..."

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "WARNING: no token obtained; skipping seed data creation"
    exit 0
fi

AUTH="-H \"Authorization: Bearer $TOKEN\""

# Check if seed data already exists
EXISTING=$(curl -sf "$BASE/api/v1/tasks" \
    -H "Authorization: Bearer $TOKEN" 2>/dev/null | python3 -c "import json,sys; rows=json.load(sys.stdin); print(len(rows))" 2>/dev/null || echo "0")
EXISTING=$(echo "$EXISTING" | tr -d '[:space:]')
if [ "${EXISTING:-0}" -gt "0" ] 2>/dev/null; then
    echo "Seed data already present ($EXISTING tasks), skipping..."
    exit 0
fi

# Create seed categories
echo "Creating seed categories..."
WORK_CAT=$(curl -sf -X POST "$BASE/api/v1/categories" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"name":"Work","color":"#3b82f6"}' 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
PERSONAL_CAT=$(curl -sf -X POST "$BASE/api/v1/categories" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"name":"Personal","color":"#10b981"}' 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
echo "  Work category id: $WORK_CAT"
echo "  Personal category id: $PERSONAL_CAT"

# Create seed tasks
echo "Creating seed tasks..."

curl -sf -X POST "$BASE/api/v1/tasks" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"title\":\"seed-task-001\",\"description\":\"Write the CRUD scenario tests\",\"priority\":\"high\",\"category_id\":$WORK_CAT}" \
    >/dev/null || true

curl -sf -X POST "$BASE/api/v1/tasks" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"title\":\"seed-task-002\",\"description\":\"Review OpenAPI spec output\",\"priority\":\"medium\",\"due_date\":\"2026-03-01\",\"category_id\":$WORK_CAT}" \
    >/dev/null || true

curl -sf -X POST "$BASE/api/v1/tasks" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"title\":\"seed-task-003\",\"description\":\"Deploy to staging\",\"priority\":\"low\",\"category_id\":$PERSONAL_CAT}" \
    >/dev/null || true

echo "Seed complete."
