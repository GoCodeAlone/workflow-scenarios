#!/usr/bin/env bash
set -euo pipefail

echo "Seeding scenario 15-progressive-tasks (Phase 1 — v1-basic)..."

echo "Waiting for workflow-server to be ready..."
kubectl wait --for=condition=ready pod -l app=workflow-server -n "$NAMESPACE" --timeout=120s

kubectl port-forward svc/workflow-server 18015:8080 -n "$NAMESPACE" &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE="http://localhost:18015"

# Initialise v1 database schema
echo "Initialising v1 database schema..."
INIT_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/internal/init-db" 2>/dev/null || echo "000")
echo "  init-db: $INIT_CODE"

# Check if seed data already exists
EXISTING=$(curl -sf "$BASE/api/v1/tasks" 2>/dev/null | python3 -c "import json,sys; rows=json.load(sys.stdin); print(len(rows))" 2>/dev/null || echo "0")
EXISTING=$(echo "$EXISTING" | tr -d '[:space:]')
if [ "${EXISTING:-0}" -gt "0" ] 2>/dev/null; then
    echo "Seed data already present ($EXISTING tasks), skipping..."
    exit 0
fi

# Create 3 seed tasks (no auth in v1)
echo "Creating seed tasks..."

curl -sf -X POST "$BASE/api/v1/tasks" \
    -H "Content-Type: application/json" \
    -d '{"title":"phase1-task-001","description":"Initial task from seed — must survive all upgrades"}' \
    >/dev/null || true

curl -sf -X POST "$BASE/api/v1/tasks" \
    -H "Content-Type: application/json" \
    -d '{"title":"phase1-task-002","description":"Second seed task — verify persistence across phases"}' \
    >/dev/null || true

curl -sf -X POST "$BASE/api/v1/tasks" \
    -H "Content-Type: application/json" \
    -d '{"title":"phase1-task-003","description":"Third seed task — verify CRUD still works after upgrade"}' \
    >/dev/null || true

echo "Seed complete. Created 3 Phase 1 tasks."
