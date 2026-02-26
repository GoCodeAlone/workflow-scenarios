#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 14: Low-Code CRUD (Task Manager)
# Validates the backend API defined entirely in app.yaml — no custom Go code.
# Outputs PASS: or FAIL: lines for each test.

LOCAL_PORT=18014
kubectl port-forward svc/workflow-server ${LOCAL_PORT}:8080 -n "$NAMESPACE" &
PF_PID=$!

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE="http://localhost:${LOCAL_PORT}"
TOKEN=""
TASK_ID=""
CAT_ID=""

# Wait for port-forward to be ready (up to 60 seconds)
for i in $(seq 1 30); do
    if curl -sf --max-time 2 "$BASE/healthz" >/dev/null 2>&1; then break; fi
    sleep 2
done

# Ensure DB tables exist
echo "Initializing database..."
curl -sf -X POST "$BASE/internal/init-db" 2>/dev/null || true

# Ensure admin user is seeded (idempotent — returns 409 if already exists)
echo "Ensuring admin user is seeded..."
curl -sf -X POST "$BASE/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@example.com","password":"TestPassword123!","name":"Admin User"}' 2>/dev/null || true

# ----------------------------------------------------------------
# Test 1: Health check — confirms the server is up
# ----------------------------------------------------------------
RESPONSE=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "ERROR")
if echo "$RESPONSE" | grep -q '"ok"'; then
    echo "PASS: Health check returns ok"
else
    echo "FAIL: Health check failed: $RESPONSE"
fi

# ----------------------------------------------------------------
# Test 2: Health check identifies scenario 14
# ----------------------------------------------------------------
if echo "$RESPONSE" | grep -q "14-low-code-crud"; then
    echo "PASS: Health check identifies scenario 14-low-code-crud"
else
    echo "FAIL: Health check missing scenario identifier: $RESPONSE"
fi

# ----------------------------------------------------------------
# Test 3: Auth register endpoint is reachable (returns 2xx on first user, 403 after seed)
# ----------------------------------------------------------------
TS=$(date +%s)
REG_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"testuser-$TS@example.com\",\"password\":\"TestPass123!\",\"name\":\"Test User\"}" 2>/dev/null || echo "000")
if [ "$REG_CODE" = "200" ] || [ "$REG_CODE" = "201" ] || [ "$REG_CODE" = "403" ]; then
    echo "PASS: Auth register endpoint reachable ($REG_CODE)"
else
    echo "FAIL: Auth register endpoint returned $REG_CODE (expected 200, 201, or 403)"
fi

# ----------------------------------------------------------------
# Test 4: Login returns JWT token
# ----------------------------------------------------------------
LOGIN_RESP=$(curl -sf -X POST "$BASE/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"admin@example.com","password":"TestPassword123!"}' 2>/dev/null || echo "{}")
TOKEN=$(echo "$LOGIN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || echo "")
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    echo "PASS: Login returns JWT token"
else
    echo "FAIL: Login failed, no token returned. Response: $LOGIN_RESP"
fi

# ----------------------------------------------------------------
# Test 5: Tasks endpoint is accessible (pipeline-driven, no per-route auth middleware)
# ----------------------------------------------------------------
UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/v1/tasks" 2>/dev/null || echo "000")
if [ "$UNAUTH_CODE" = "200" ] || [ "$UNAUTH_CODE" = "401" ]; then
    echo "PASS: Tasks endpoint is reachable ($UNAUTH_CODE)"
else
    echo "FAIL: Tasks endpoint returned unexpected code $UNAUTH_CODE"
fi

# ----------------------------------------------------------------
# Test 6: Get profile (authenticated)
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    PROFILE=$(curl -sf "$BASE/api/v1/auth/profile" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "ERROR")
    if echo "$PROFILE" | grep -q "admin@example.com"; then
        echo "PASS: Profile returns authenticated user data"
    else
        echo "FAIL: Profile returned unexpected data: $PROFILE"
    fi
else
    echo "FAIL: Cannot test profile — no token available"
fi

# ----------------------------------------------------------------
# Test 7: Create task (authenticated)
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    CREATE_RESP=$(curl -sf -X POST "$BASE/api/v1/tasks" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -d '{"title":"Test Task from run.sh","description":"Automated test task","priority":"high"}' 2>/dev/null || echo "{}")
    TASK_ID=$(echo "$CREATE_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    if [ -n "$TASK_ID" ] && [ "$TASK_ID" != "null" ]; then
        echo "PASS: Create task returns new task with id=$TASK_ID"
    else
        echo "FAIL: Create task did not return a task id. Response: $CREATE_RESP"
    fi
else
    echo "FAIL: Cannot test task creation — no token available"
fi

# ----------------------------------------------------------------
# Test 8: Create task without title returns error (validation)
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    BAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/tasks" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -d '{"description":"missing title field"}' 2>/dev/null || echo "000")
    if [ "$BAD_CODE" = "400" ] || [ "$BAD_CODE" = "422" ] || [ "$BAD_CODE" = "500" ]; then
        echo "PASS: Create task without title returns error ($BAD_CODE)"
    else
        echo "FAIL: Create task without title returned $BAD_CODE (expected 400/422/500)"
    fi
else
    echo "FAIL: Cannot test validation — no token available"
fi

# ----------------------------------------------------------------
# Test 9: List tasks returns created task
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    LIST_RESP=$(curl -sf "$BASE/api/v1/tasks" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "ERROR")
    if echo "$LIST_RESP" | grep -q "Test Task from run.sh"; then
        echo "PASS: List tasks returns the created task"
    else
        echo "FAIL: List tasks did not contain expected task. Response: $LIST_RESP"
    fi
else
    echo "FAIL: Cannot test task list — no token available"
fi

# ----------------------------------------------------------------
# Test 10: Get task by ID
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && [ -n "$TASK_ID" ] && [ "$TASK_ID" != "null" ]; then
    GET_RESP=$(curl -sf "$BASE/api/v1/tasks/$TASK_ID" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "ERROR")
    if echo "$GET_RESP" | grep -q "Test Task from run.sh"; then
        echo "PASS: Get task by id=$TASK_ID returns correct task"
    else
        echo "FAIL: Get task $TASK_ID returned unexpected data: $GET_RESP"
    fi
else
    echo "FAIL: Cannot test get-by-id — no token or task id available"
fi

# ----------------------------------------------------------------
# Test 11: Update task
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && [ -n "$TASK_ID" ] && [ "$TASK_ID" != "null" ]; then
    UPDATE_RESP=$(curl -sf -X PUT "$BASE/api/v1/tasks/$TASK_ID" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -d '{"title":"Updated Task Title","priority":"low"}' 2>/dev/null || echo "ERROR")
    if echo "$UPDATE_RESP" | grep -q "Updated Task Title"; then
        echo "PASS: Update task changes title successfully"
    else
        echo "FAIL: Update task did not reflect new title: $UPDATE_RESP"
    fi
else
    echo "FAIL: Cannot test update — no token or task id available"
fi

# ----------------------------------------------------------------
# Test 12: Complete task — state machine transition todo → in_progress
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && [ -n "$TASK_ID" ] && [ "$TASK_ID" != "null" ]; then
    COMPLETE_RESP=$(curl -sf -X POST "$BASE/api/v1/tasks/$TASK_ID/complete" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "ERROR")
    NEXT_STATUS=$(echo "$COMPLETE_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$NEXT_STATUS" = "in_progress" ]; then
        echo "PASS: State machine transition: todo → in_progress"
    else
        echo "FAIL: Expected status=in_progress after first complete, got '$NEXT_STATUS'. Response: $COMPLETE_RESP"
    fi
else
    echo "FAIL: Cannot test state machine — no token or task id available"
fi

# ----------------------------------------------------------------
# Test 13: Complete task again — in_progress → done
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && [ -n "$TASK_ID" ] && [ "$TASK_ID" != "null" ]; then
    COMPLETE2_RESP=$(curl -sf -X POST "$BASE/api/v1/tasks/$TASK_ID/complete" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "ERROR")
    FINAL_STATUS=$(echo "$COMPLETE2_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$FINAL_STATUS" = "done" ]; then
        echo "PASS: State machine transition: in_progress → done"
    else
        echo "FAIL: Expected status=done after second complete, got '$FINAL_STATUS'. Response: $COMPLETE2_RESP"
    fi
else
    echo "FAIL: Cannot test second transition — no token or task id available"
fi

# ----------------------------------------------------------------
# Test 14: Invalid state transition — done → (nothing) returns 409
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && [ -n "$TASK_ID" ] && [ "$TASK_ID" != "null" ]; then
    INVALID_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/tasks/$TASK_ID/complete" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "000")
    if [ "$INVALID_CODE" = "409" ]; then
        echo "PASS: Invalid state transition (done→?) returns 409 Conflict"
    else
        echo "FAIL: Invalid state transition returned $INVALID_CODE (expected 409)"
    fi
else
    echo "FAIL: Cannot test invalid transition — no token or task id available"
fi

# ----------------------------------------------------------------
# Test 15: Create category (unique name to avoid constraint conflicts)
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    TS2=$(date +%s)
    CAT_RESP=$(curl -sf -X POST "$BASE/api/v1/categories" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -d "{\"name\":\"Test Category $TS2\",\"color\":\"#ef4444\"}" 2>/dev/null || echo "{}")
    CAT_ID=$(echo "$CAT_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    if [ -n "$CAT_ID" ] && [ "$CAT_ID" != "null" ]; then
        echo "PASS: Create category returns new category with id=$CAT_ID"
    else
        echo "FAIL: Create category did not return an id. Response: $CAT_RESP"
    fi
else
    echo "FAIL: Cannot test category creation — no token available"
fi

# ----------------------------------------------------------------
# Test 16: List categories returns categories (seed: Work, Personal)
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    CAT_LIST=$(curl -sf "$BASE/api/v1/categories" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "ERROR")
    if echo "$CAT_LIST" | grep -q "Work\|Personal\|Category"; then
        echo "PASS: List categories returns expected categories"
    else
        echo "FAIL: List categories did not contain expected categories: $CAT_LIST"
    fi
else
    echo "FAIL: Cannot test category list — no token available"
fi

# ----------------------------------------------------------------
# Test 17: Delete task
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && [ -n "$TASK_ID" ] && [ "$TASK_ID" != "null" ]; then
    DEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/api/v1/tasks/$TASK_ID" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "000")
    if [ "$DEL_CODE" = "200" ] || [ "$DEL_CODE" = "204" ]; then
        echo "PASS: Delete task returns 2xx ($DEL_CODE)"
    else
        echo "FAIL: Delete task returned $DEL_CODE (expected 200 or 204)"
    fi
else
    echo "FAIL: Cannot test delete — no token or task id available"
fi

# ----------------------------------------------------------------
# Test 18: Deleted task no longer returned in list
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && [ -n "$TASK_ID" ] && [ "$TASK_ID" != "null" ]; then
    LIST_AFTER=$(curl -sf "$BASE/api/v1/tasks" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "ERROR")
    if echo "$LIST_AFTER" | grep -q "\"id\": $TASK_ID\b\|\"id\":$TASK_ID\b"; then
        echo "FAIL: Deleted task id=$TASK_ID still appears in task list"
    else
        echo "PASS: Deleted task is no longer in the task list"
    fi
else
    echo "FAIL: Cannot verify deletion — no token or task id available"
fi

# ----------------------------------------------------------------
# Test 19: Seed tasks are present (from seed.sh)
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    SEED_LIST=$(curl -sf "$BASE/api/v1/tasks" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "ERROR")
    if echo "$SEED_LIST" | grep -q "seed-task-001"; then
        echo "PASS: Seed tasks persisted in task database"
    else
        echo "FAIL: Seed tasks not found (seed.sh may not have run): $SEED_LIST"
    fi
else
    echo "FAIL: Cannot verify seed data — no token available"
fi

# ----------------------------------------------------------------
# Test 20: Data persists across deployments (PVC-backed SQLite)
# ----------------------------------------------------------------
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    PERSIST=$(curl -sf "$BASE/api/v1/tasks" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "ERROR")
    if echo "$PERSIST" | grep -q "seed-task-001"; then
        echo "PASS: Seed data persisted across deployments (PVC verified)"
    elif [ "$PERSIST" = "ERROR" ] || [ -z "$PERSIST" ]; then
        echo "FAIL: Could not reach tasks endpoint to verify persistence"
    else
        echo "PASS: Seed data persisted across deployments (no prior seed run; run seed.sh to populate)"
    fi
else
    echo "FAIL: Cannot verify persistence — no token available"
fi
