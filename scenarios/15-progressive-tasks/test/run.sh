#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 15: Progressive Task Manager
# Tests three deployment phases and validates state persistence across each.
# Outputs PASS: or FAIL: lines for each test.

NS="${NAMESPACE:-wf-scenario-15}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
PORT=18015
BASE="http://localhost:$PORT"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Port-forward helper — kills previous and starts fresh
start_pf() {
    pkill -f "port-forward.*$PORT" 2>/dev/null || true
    sleep 1
    kubectl port-forward svc/workflow-server "$PORT":8080 -n "$NS" &
    PF_PID=$!
    sleep 4
}

cleanup() {
    pkill -f "port-forward.*$PORT" 2>/dev/null || true
}
trap cleanup EXIT

# Deploy config version and wait for rollout
deploy_version() {
    local config_file="$1"
    local version_label="$2"
    echo ""
    echo "--- Deploying $version_label ---"
    kubectl create configmap app \
        --from-file=app.yaml="$SCENARIO_DIR/config/$config_file" \
        -n "$NS" --dry-run=client -o yaml | kubectl apply -f -
    kubectl rollout restart deployment/workflow-server -n "$NS"
    kubectl rollout status deployment/workflow-server -n "$NS" --timeout=120s
    echo "--- $version_label ready ---"
}

# Init DB on current deployment
init_db() {
    curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/internal/init-db" 2>/dev/null || echo "000"
}

# ====================================================================
# PHASE 1: Deploy v1-basic, create tasks, verify CRUD
# ====================================================================
echo ""
echo "========================================"
echo "PHASE 1: Basic Task CRUD (v1-basic)"
echo "========================================"

deploy_version "v1-basic.yaml" "v1-basic"
start_pf

# Test 1: Health check
RESP=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q '"ok"'; then
    pass "Phase 1: Health check returns ok"
else
    fail "Phase 1: Health check failed: $RESP"
fi

# Test 2: Health check identifies v1 phase
if echo "$RESP" | grep -q "v1-basic"; then
    pass "Phase 1: Health check identifies v1-basic phase"
else
    fail "Phase 1: Health check missing phase identifier: $RESP"
fi

# Test 3: Init DB succeeds
INIT=$(init_db)
if [ "$INIT" = "200" ]; then
    pass "Phase 1: init-db returns 200"
else
    fail "Phase 1: init-db returned $INIT (expected 200)"
fi

# Test 4: Create task 1
CREATE1=$(curl -sf -X POST "$BASE/api/v1/tasks" \
    -H "Content-Type: application/json" \
    -d '{"title":"phase1-task-A","description":"Created in Phase 1"}' 2>/dev/null || echo "{}")
TASK1_ID=$(echo "$CREATE1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$TASK1_ID" ] && [ "$TASK1_ID" != "null" ]; then
    pass "Phase 1: Create task returns id=$TASK1_ID"
else
    fail "Phase 1: Create task did not return id. Response: $CREATE1"
fi

# Test 5: Create task 2
CREATE2=$(curl -sf -X POST "$BASE/api/v1/tasks" \
    -H "Content-Type: application/json" \
    -d '{"title":"phase1-task-B","description":"Second Phase 1 task"}' 2>/dev/null || echo "{}")
TASK2_ID=$(echo "$CREATE2" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$TASK2_ID" ] && [ "$TASK2_ID" != "null" ]; then
    pass "Phase 1: Create second task returns id=$TASK2_ID"
else
    fail "Phase 1: Create second task failed. Response: $CREATE2"
fi

# Test 6: Create task 3
CREATE3=$(curl -sf -X POST "$BASE/api/v1/tasks" \
    -H "Content-Type: application/json" \
    -d '{"title":"phase1-task-C","description":"Third Phase 1 task"}' 2>/dev/null || echo "{}")
TASK3_ID=$(echo "$CREATE3" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$TASK3_ID" ] && [ "$TASK3_ID" != "null" ]; then
    pass "Phase 1: Create third task returns id=$TASK3_ID"
else
    fail "Phase 1: Create third task failed. Response: $CREATE3"
fi

# Test 7: List tasks returns all 3
LIST1=$(curl -sf "$BASE/api/v1/tasks" 2>/dev/null || echo "[]")
TASK_COUNT=$(echo "$LIST1" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [ "$TASK_COUNT" -ge "3" ]; then
    pass "Phase 1: List tasks returns $TASK_COUNT tasks (>= 3)"
else
    fail "Phase 1: List tasks returned $TASK_COUNT tasks (expected >= 3)"
fi

# Test 8: Get task by ID
if [ -n "$TASK1_ID" ] && [ "$TASK1_ID" != "null" ]; then
    GET1=$(curl -sf "$BASE/api/v1/tasks/$TASK1_ID" 2>/dev/null || echo "{}")
    if echo "$GET1" | grep -q "phase1-task-A"; then
        pass "Phase 1: Get task by id=$TASK1_ID returns correct data"
    else
        fail "Phase 1: Get task $TASK1_ID returned unexpected: $GET1"
    fi
else
    fail "Phase 1: Cannot test get-by-id — no task id"
fi

# Test 9: Update task
if [ -n "$TASK2_ID" ] && [ "$TASK2_ID" != "null" ]; then
    UPDATE=$(curl -sf -X PUT "$BASE/api/v1/tasks/$TASK2_ID" \
        -H "Content-Type: application/json" \
        -d '{"title":"phase1-task-B-updated","status":"done"}' 2>/dev/null || echo "{}")
    if echo "$UPDATE" | grep -q "phase1-task-B-updated"; then
        pass "Phase 1: Update task changes title successfully"
    else
        fail "Phase 1: Update task failed. Response: $UPDATE"
    fi
else
    fail "Phase 1: Cannot test update — no task id"
fi

# Test 10: Delete task 3
if [ -n "$TASK3_ID" ] && [ "$TASK3_ID" != "null" ]; then
    DEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/api/v1/tasks/$TASK3_ID" 2>/dev/null || echo "000")
    if [ "$DEL_CODE" = "200" ] || [ "$DEL_CODE" = "204" ]; then
        pass "Phase 1: Delete task returns 2xx ($DEL_CODE)"
    else
        fail "Phase 1: Delete task returned $DEL_CODE (expected 200/204)"
    fi
else
    fail "Phase 1: Cannot test delete — no task id"
fi

# Test 11: Validate required field — create without title returns error
BAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/tasks" \
    -H "Content-Type: application/json" \
    -d '{"description":"no title"}' 2>/dev/null || echo "000")
if [ "$BAD_CODE" = "400" ] || [ "$BAD_CODE" = "422" ] || [ "$BAD_CODE" = "500" ]; then
    pass "Phase 1: Create task without title returns error ($BAD_CODE)"
else
    fail "Phase 1: Validation missing — returned $BAD_CODE (expected 400/422/500)"
fi

echo ""
echo "========================================"
echo "PHASE 2: Add Categories (v2-categories)"
echo "========================================"

deploy_version "v2-categories.yaml" "v2-categories"
start_pf

# Test 12: Health identifies v2
RESP2=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "ERROR")
if echo "$RESP2" | grep -q "v2-categories"; then
    pass "Phase 2: Health check identifies v2-categories phase"
else
    fail "Phase 2: Health check missing v2 identifier: $RESP2"
fi

# Test 13: Init DB (v2) succeeds — creates categories table, preserves tasks
INIT2=$(init_db)
if [ "$INIT2" = "200" ]; then
    pass "Phase 2: init-db (v2) returns 200"
else
    fail "Phase 2: init-db returned $INIT2 (expected 200)"
fi

# Test 14: CRITICAL — Phase 1 tasks still exist after upgrade
LIST2=$(curl -sf "$BASE/api/v1/tasks" 2>/dev/null || echo "[]")
if echo "$LIST2" | grep -q "phase1-task-A"; then
    pass "Phase 2: CRITICAL — Phase 1 task 'phase1-task-A' persisted across upgrade"
else
    fail "Phase 2: CRITICAL — Phase 1 task 'phase1-task-A' LOST after upgrade"
fi

# Test 15: CRITICAL — Phase 1 updated task still shows correct data
if echo "$LIST2" | grep -q "phase1-task-B-updated"; then
    pass "Phase 2: CRITICAL — Updated Phase 1 task preserved correct title"
else
    fail "Phase 2: CRITICAL — Updated Phase 1 task has wrong data or is missing"
fi

# Test 16: Create category
CAT1=$(curl -sf -X POST "$BASE/api/v1/categories" \
    -H "Content-Type: application/json" \
    -d '{"name":"Work","color":"#3b82f6"}' 2>/dev/null || echo "{}")
CAT1_ID=$(echo "$CAT1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$CAT1_ID" ] && [ "$CAT1_ID" != "null" ]; then
    pass "Phase 2: Create category returns id=$CAT1_ID"
else
    fail "Phase 2: Create category failed. Response: $CAT1"
fi

# Test 17: Create second category
CAT2=$(curl -sf -X POST "$BASE/api/v1/categories" \
    -H "Content-Type: application/json" \
    -d '{"name":"Personal","color":"#10b981"}' 2>/dev/null || echo "{}")
CAT2_ID=$(echo "$CAT2" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$CAT2_ID" ] && [ "$CAT2_ID" != "null" ]; then
    pass "Phase 2: Create second category returns id=$CAT2_ID"
else
    fail "Phase 2: Create second category failed. Response: $CAT2"
fi

# Test 18: List categories
CAT_LIST=$(curl -sf "$BASE/api/v1/categories" 2>/dev/null || echo "[]")
if echo "$CAT_LIST" | grep -q "Work"; then
    pass "Phase 2: List categories returns 'Work' category"
else
    fail "Phase 2: List categories missing 'Work': $CAT_LIST"
fi

# Test 19: Assign Phase 1 task to a category
if [ -n "$TASK1_ID" ] && [ "$TASK1_ID" != "null" ] && [ -n "$CAT1_ID" ] && [ "$CAT1_ID" != "null" ]; then
    ASSIGN=$(curl -sf -X PUT "$BASE/api/v1/tasks/$TASK1_ID/category" \
        -H "Content-Type: application/json" \
        -d "{\"category_id\":$CAT1_ID}" 2>/dev/null || echo "{}")
    ASSIGNED_CAT=$(echo "$ASSIGN" | python3 -c "import json,sys; print(json.load(sys.stdin).get('category_id',''))" 2>/dev/null || echo "")
    if [ "$ASSIGNED_CAT" = "$CAT1_ID" ]; then
        pass "Phase 2: Assign Phase 1 task to category succeeds"
    else
        fail "Phase 2: Assign category returned category_id='$ASSIGNED_CAT' (expected $CAT1_ID). Response: $ASSIGN"
    fi
else
    fail "Phase 2: Cannot test category assignment — missing task or category id"
fi

# Test 20: Task list shows category join for assigned task
LIST2B=$(curl -sf "$BASE/api/v1/tasks" 2>/dev/null || echo "[]")
if echo "$LIST2B" | grep -q "Work"; then
    pass "Phase 2: Task list includes category_name from JOIN"
else
    fail "Phase 2: Task list missing category_name: $LIST2B"
fi

echo ""
echo "========================================"
echo "PHASE 3: Add Auth (v3-auth)"
echo "========================================"

deploy_version "v3-auth.yaml" "v3-auth"
start_pf

# Test 21: Health identifies v3
RESP3=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "ERROR")
if echo "$RESP3" | grep -q "v3-auth"; then
    pass "Phase 3: Health check identifies v3-auth phase"
else
    fail "Phase 3: Health check missing v3 identifier: $RESP3"
fi

# Test 22: Init DB (v3) succeeds — adds user_id column
INIT3=$(init_db)
if [ "$INIT3" = "200" ]; then
    pass "Phase 3: init-db (v3) returns 200"
else
    fail "Phase 3: init-db returned $INIT3 (expected 200)"
fi

# Test 23: Tasks now require auth — 401 without token
UNAUTH=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/v1/tasks" 2>/dev/null || echo "000")
if [ "$UNAUTH" = "401" ]; then
    pass "Phase 3: Tasks endpoint returns 401 without token"
else
    fail "Phase 3: Tasks returned $UNAUTH without token (expected 401)"
fi

# Test 24: Register user
TS=$(date +%s)
REG_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"user-$TS@example.com\",\"password\":\"TestPass123!\",\"name\":\"Test User\"}" 2>/dev/null || echo "000")
if [ "$REG_CODE" = "200" ] || [ "$REG_CODE" = "201" ]; then
    pass "Phase 3: User registration returns 2xx ($REG_CODE)"
else
    fail "Phase 3: User registration returned $REG_CODE (expected 2xx)"
fi

# Test 25: Login returns JWT token
LOGIN=$(curl -sf -X POST "$BASE/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"user-$TS@example.com\",\"password\":\"TestPass123!\"}" 2>/dev/null || echo "{}")
TOKEN=$(echo "$LOGIN" | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    pass "Phase 3: Login returns JWT token"
else
    fail "Phase 3: Login failed, no token. Response: $LOGIN"
fi

# Test 26: CRITICAL — Phase 1 tasks still accessible with auth token
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    LIST3=$(curl -sf "$BASE/api/v1/tasks" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "[]")
    if echo "$LIST3" | grep -q "phase1-task-A"; then
        pass "Phase 3: CRITICAL — Phase 1 task 'phase1-task-A' persisted and accessible after auth upgrade"
    else
        fail "Phase 3: CRITICAL — Phase 1 task 'phase1-task-A' LOST or inaccessible after auth upgrade"
    fi
else
    fail "Phase 3: Cannot verify Phase 1 tasks — no token"
fi

# Test 27: CRITICAL — Phase 2 categories still exist
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    CAT_LIST3=$(curl -sf "$BASE/api/v1/categories" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "[]")
    if echo "$CAT_LIST3" | grep -q "Work"; then
        pass "Phase 3: CRITICAL — Phase 2 category 'Work' persisted after auth upgrade"
    else
        fail "Phase 3: CRITICAL — Phase 2 category 'Work' LOST after auth upgrade"
    fi
else
    fail "Phase 3: Cannot verify Phase 2 categories — no token"
fi

# Test 28: Create new task as authenticated user (gets user_id)
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    NEW_TASK=$(curl -sf -X POST "$BASE/api/v1/tasks" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -d '{"title":"phase3-authed-task","description":"Created with JWT in Phase 3"}' 2>/dev/null || echo "{}")
    NEW_ID=$(echo "$NEW_TASK" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    NEW_USER=$(echo "$NEW_TASK" | python3 -c "import json,sys; print(json.load(sys.stdin).get('user_id',''))" 2>/dev/null || echo "")
    if [ -n "$NEW_ID" ] && [ "$NEW_ID" != "null" ]; then
        pass "Phase 3: Create authenticated task returns id=$NEW_ID"
    else
        fail "Phase 3: Create authenticated task failed. Response: $NEW_TASK"
    fi
    if [ -n "$NEW_USER" ] && [ "$NEW_USER" != "null" ] && [ "$NEW_USER" != "" ]; then
        pass "Phase 3: New task has user_id=$NEW_USER set"
    else
        fail "Phase 3: New task missing user_id. Response: $NEW_TASK"
    fi
else
    fail "Phase 3: Cannot create authed task — no token"
fi

# Test 29: Phase 1 legacy tasks have null user_id (visible to all)
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && [ -n "$TASK1_ID" ] && [ "$TASK1_ID" != "null" ]; then
    GET_LEGACY=$(curl -sf "$BASE/api/v1/tasks/$TASK1_ID" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "{}")
    LEGACY_USER=$(echo "$GET_LEGACY" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d.get('user_id'); print('null' if v is None else v)" 2>/dev/null || echo "")
    if [ "$LEGACY_USER" = "null" ] || [ "$LEGACY_USER" = "" ]; then
        pass "Phase 3: Legacy Phase 1 task has null user_id (accessible to all)"
    else
        fail "Phase 3: Legacy Phase 1 task has unexpected user_id='$LEGACY_USER'"
    fi
else
    fail "Phase 3: Cannot check legacy task user_id — no token or task id"
fi

# Test 30: Profile endpoint works
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    PROFILE=$(curl -sf "$BASE/api/v1/auth/profile" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "{}")
    if echo "$PROFILE" | grep -q "user-$TS@example.com"; then
        pass "Phase 3: Profile endpoint returns correct user email"
    else
        fail "Phase 3: Profile returned unexpected data: $PROFILE"
    fi
else
    fail "Phase 3: Cannot test profile — no token"
fi

# ====================================================================
# Summary
# ====================================================================
echo ""
echo "========================================"
echo "RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "========================================"
if [ "$FAIL_COUNT" -gt "0" ]; then
    exit 1
fi
