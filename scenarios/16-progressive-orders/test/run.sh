#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 16: Progressive Order System
# Tests three deployment phases and validates state persistence across each.
# Outputs PASS: or FAIL: lines for each test.

NS="${NAMESPACE:-wf-scenario-16}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
PORT=18016
BASE="http://localhost:$PORT"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

start_pf() {
    pkill -f "port-forward.*$PORT" 2>/dev/null || true
    sleep 2
    kubectl port-forward svc/workflow-server "$PORT":8080 -n "$NS" &
    PF_PID=$!
    # Wait for port-forward to be ready (up to 60 seconds)
    for i in $(seq 1 30); do
        if curl -sf --max-time 2 "$BASE/healthz" >/dev/null 2>&1; then break; fi
        sleep 2
    done
}

cleanup() {
    pkill -f "port-forward.*$PORT" 2>/dev/null || true
}
trap cleanup EXIT

deploy_version() {
    local config_file="$1"
    local label="$2"
    echo ""
    echo "--- Deploying $label ---"
    kubectl create configmap app \
        --from-file=app.yaml="$SCENARIO_DIR/config/$config_file" \
        -n "$NS" --dry-run=client -o yaml | kubectl apply -f -
    kubectl rollout restart deployment/workflow-server -n "$NS"
    kubectl rollout status deployment/workflow-server -n "$NS" --timeout=120s
    echo "--- $label ready ---"
}

init_db() {
    curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/internal/init-db" 2>/dev/null || echo "000"
}

# ====================================================================
# PHASE 1: Deploy v1-basic-orders, create orders, verify CRUD
# ====================================================================
echo ""
echo "========================================"
echo "PHASE 1: Basic Order CRUD (v1-basic-orders)"
echo "========================================"

deploy_version "v1-basic-orders.yaml" "v1-basic-orders"
start_pf

# Test 1: Health check
RESP=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q '"ok"'; then
    pass "Phase 1: Health check returns ok"
else
    fail "Phase 1: Health check failed: $RESP"
fi

# Test 2: Phase identifier
if echo "$RESP" | grep -q "v1-basic-orders"; then
    pass "Phase 1: Health check identifies v1-basic-orders"
else
    fail "Phase 1: Health check missing v1 identifier: $RESP"
fi

# Test 3: Init DB
INIT=$(init_db)
if [ "$INIT" = "200" ]; then
    pass "Phase 1: init-db returns 200"
else
    fail "Phase 1: init-db returned $INIT (expected 200)"
fi

# Test 4: Create order 1 (will be paid in Phase 2)
CREATE1=$(curl -sf -X POST "$BASE/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d '{"customer_email":"alice@example.com","items":["widget-a","widget-b"],"total":49.99}' 2>/dev/null || echo "{}")
ORDER1_ID=$(echo "$CREATE1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$ORDER1_ID" ] && [ "$ORDER1_ID" != "null" ]; then
    pass "Phase 1: Create order 1 returns id (alice@example.com)"
else
    fail "Phase 1: Create order 1 failed. Response: $CREATE1"
fi

# Test 5: Create order 2 (will be shipped in Phase 2)
CREATE2=$(curl -sf -X POST "$BASE/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d '{"customer_email":"bob@example.com","items":["gadget-x"],"total":129.00}' 2>/dev/null || echo "{}")
ORDER2_ID=$(echo "$CREATE2" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$ORDER2_ID" ] && [ "$ORDER2_ID" != "null" ]; then
    pass "Phase 1: Create order 2 returns id (bob@example.com)"
else
    fail "Phase 1: Create order 2 failed. Response: $CREATE2"
fi

# Test 6: Create order 3 (will be cancelled in Phase 2)
CREATE3=$(curl -sf -X POST "$BASE/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d '{"customer_email":"carol@example.com","items":["item-one"],"total":75.50}' 2>/dev/null || echo "{}")
ORDER3_ID=$(echo "$CREATE3" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$ORDER3_ID" ] && [ "$ORDER3_ID" != "null" ]; then
    pass "Phase 1: Create order 3 returns id (carol@example.com)"
else
    fail "Phase 1: Create order 3 failed. Response: $CREATE3"
fi

# Test 7: List orders returns all 3
LIST1=$(curl -sf "$BASE/api/v1/orders" 2>/dev/null || echo "[]")
COUNT1=$(echo "$LIST1" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [ "$COUNT1" -ge "3" ]; then
    pass "Phase 1: List orders returns $COUNT1 orders (>= 3)"
else
    fail "Phase 1: List orders returned $COUNT1 orders (expected >= 3)"
fi

# Test 8: Get order by ID
if [ -n "$ORDER1_ID" ] && [ "$ORDER1_ID" != "null" ]; then
    GET1=$(curl -sf "$BASE/api/v1/orders/$ORDER1_ID" 2>/dev/null || echo "{}")
    if echo "$GET1" | grep -q "alice@example.com"; then
        pass "Phase 1: Get order by id returns correct data (alice@example.com)"
    else
        fail "Phase 1: Get order $ORDER1_ID returned unexpected: $GET1"
    fi
else
    fail "Phase 1: Cannot test get-by-id — no order id"
fi

# Test 9: Order defaults to pending status
if [ -n "$ORDER1_ID" ] && [ "$ORDER1_ID" != "null" ]; then
    STATUS=$(curl -sf "$BASE/api/v1/orders/$ORDER1_ID" 2>/dev/null | \
        python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$STATUS" = "pending" ]; then
        pass "Phase 1: New order has status=pending"
    else
        fail "Phase 1: New order has status='$STATUS' (expected 'pending')"
    fi
else
    fail "Phase 1: Cannot verify order status — no order id"
fi

# Test 10: Validation — missing required field
BAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d '{"items":["x"]}' 2>/dev/null || echo "000")
if [ "$BAD_CODE" = "400" ] || [ "$BAD_CODE" = "422" ] || [ "$BAD_CODE" = "500" ]; then
    pass "Phase 1: Create without customer_email returns error ($BAD_CODE)"
else
    fail "Phase 1: Validation missing — returned $BAD_CODE (expected 400/422/500)"
fi

echo ""
echo "========================================"
echo "PHASE 2: State Machine (v2-state-machine)"
echo "========================================"

deploy_version "v2-state-machine.yaml" "v2-state-machine"
start_pf

# Test 11: Health identifies v2
RESP2=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "ERROR")
if echo "$RESP2" | grep -q "v2-state-machine"; then
    pass "Phase 2: Health check identifies v2-state-machine"
else
    fail "Phase 2: Health check missing v2 identifier: $RESP2"
fi

# Test 12: Init DB v2 succeeds
INIT2=$(init_db)
if [ "$INIT2" = "200" ]; then
    pass "Phase 2: init-db (v2) returns 200"
else
    fail "Phase 2: init-db returned $INIT2 (expected 200)"
fi

# Test 13: CRITICAL — Phase 1 orders still exist
LIST2=$(curl -sf "$BASE/api/v1/orders" 2>/dev/null || echo "[]")
if echo "$LIST2" | grep -q "alice@example.com"; then
    pass "Phase 2: CRITICAL — alice@example.com order persisted across upgrade"
else
    fail "Phase 2: CRITICAL — alice@example.com order LOST after upgrade"
fi

# Test 14: CRITICAL — Phase 1 orders still in pending state (not corrupted)
if [ -n "$ORDER1_ID" ] && [ "$ORDER1_ID" != "null" ]; then
    STATUS2=$(curl -sf "$BASE/api/v1/orders/$ORDER1_ID" 2>/dev/null | \
        python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$STATUS2" = "pending" ]; then
        pass "Phase 2: CRITICAL — Phase 1 order status intact (still 'pending')"
    else
        fail "Phase 2: CRITICAL — Phase 1 order status changed to '$STATUS2' (expected 'pending')"
    fi
else
    fail "Phase 2: Cannot verify Phase 1 order status — no order id"
fi

# Test 15: Pay order 1 (pending → paid)
if [ -n "$ORDER1_ID" ] && [ "$ORDER1_ID" != "null" ]; then
    PAY=$(curl -sf -X POST "$BASE/api/v1/orders/$ORDER1_ID/pay" 2>/dev/null || echo "{}")
    PAY_STATUS=$(echo "$PAY" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$PAY_STATUS" = "paid" ]; then
        pass "Phase 2: State machine — pending → paid for order 1"
    else
        fail "Phase 2: Pay order 1 returned status='$PAY_STATUS' (expected 'paid'). Response: $PAY"
    fi
else
    fail "Phase 2: Cannot test pay — no order id"
fi

# Test 16: Pay again returns 409 (already paid)
if [ -n "$ORDER1_ID" ] && [ "$ORDER1_ID" != "null" ]; then
    PAY2_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/orders/$ORDER1_ID/pay" 2>/dev/null || echo "000")
    if [ "$PAY2_CODE" = "409" ]; then
        pass "Phase 2: Duplicate pay returns 409 Conflict"
    else
        fail "Phase 2: Duplicate pay returned $PAY2_CODE (expected 409)"
    fi
else
    fail "Phase 2: Cannot test duplicate pay — no order id"
fi

# Test 17: Ship order 2 requires payment first (should fail — still pending)
if [ -n "$ORDER2_ID" ] && [ "$ORDER2_ID" != "null" ]; then
    SHIP_UNPAID=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/orders/$ORDER2_ID/ship" 2>/dev/null || echo "000")
    if [ "$SHIP_UNPAID" = "422" ]; then
        pass "Phase 2: Cannot ship unpaid order — returns 422"
    else
        fail "Phase 2: Ship unpaid order returned $SHIP_UNPAID (expected 422)"
    fi
else
    fail "Phase 2: Cannot test ship-unpaid — no order id"
fi

# Test 18: Pay order 2, then ship it
if [ -n "$ORDER2_ID" ] && [ "$ORDER2_ID" != "null" ]; then
    curl -sf -X POST "$BASE/api/v1/orders/$ORDER2_ID/pay" >/dev/null 2>&1 || true
    SHIP=$(curl -sf -X POST "$BASE/api/v1/orders/$ORDER2_ID/ship" 2>/dev/null || echo "{}")
    SHIP_STATUS=$(echo "$SHIP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$SHIP_STATUS" = "shipped" ]; then
        pass "Phase 2: State machine — paid → shipped for order 2"
    else
        fail "Phase 2: Ship order 2 returned status='$SHIP_STATUS' (expected 'shipped'). Response: $SHIP"
    fi
else
    fail "Phase 2: Cannot test ship — no order id"
fi

# Test 19: Cannot cancel shipped order
if [ -n "$ORDER2_ID" ] && [ "$ORDER2_ID" != "null" ]; then
    CANCEL_SHIPPED=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/orders/$ORDER2_ID/cancel" 2>/dev/null || echo "000")
    if [ "$CANCEL_SHIPPED" = "422" ]; then
        pass "Phase 2: Cannot cancel shipped order — returns 422"
    else
        fail "Phase 2: Cancel shipped returned $CANCEL_SHIPPED (expected 422)"
    fi
else
    fail "Phase 2: Cannot test cancel-shipped — no order id"
fi

# Test 20: Cancel order 3 (pending → cancelled)
if [ -n "$ORDER3_ID" ] && [ "$ORDER3_ID" != "null" ]; then
    CANCEL=$(curl -sf -X POST "$BASE/api/v1/orders/$ORDER3_ID/cancel" 2>/dev/null || echo "{}")
    CANCEL_STATUS=$(echo "$CANCEL" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$CANCEL_STATUS" = "cancelled" ]; then
        pass "Phase 2: State machine — pending → cancelled for order 3"
    else
        fail "Phase 2: Cancel order 3 returned status='$CANCEL_STATUS' (expected 'cancelled'). Response: $CANCEL"
    fi
else
    fail "Phase 2: Cannot test cancel — no order id"
fi

echo ""
echo "========================================"
echo "PHASE 3: Notifications + Notes (v3-notifications)"
echo "========================================"

deploy_version "v3-notifications.yaml" "v3-notifications"
start_pf

# Test 21: Health identifies v3
RESP3=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "ERROR")
if echo "$RESP3" | grep -q "v3-notifications"; then
    pass "Phase 3: Health check identifies v3-notifications"
else
    fail "Phase 3: Health check missing v3 identifier: $RESP3"
fi

# Test 22: Init DB v3 succeeds (adds order_notes table)
INIT3=$(init_db)
if [ "$INIT3" = "200" ]; then
    pass "Phase 3: init-db (v3) returns 200"
else
    fail "Phase 3: init-db returned $INIT3 (expected 200)"
fi

# Test 23: CRITICAL — All Phase 1 orders still present
LIST3=$(curl -sf "$BASE/api/v1/orders" 2>/dev/null || echo "[]")
if echo "$LIST3" | grep -q "alice@example.com"; then
    pass "Phase 3: CRITICAL — alice@example.com order persisted through all upgrades"
else
    fail "Phase 3: CRITICAL — alice@example.com order LOST after v3 upgrade"
fi

# Test 24: CRITICAL — Phase 2 state transitions preserved (order 1 is paid)
if [ -n "$ORDER1_ID" ] && [ "$ORDER1_ID" != "null" ]; then
    STATUS3=$(curl -sf "$BASE/api/v1/orders/$ORDER1_ID" 2>/dev/null | \
        python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$STATUS3" = "paid" ]; then
        pass "Phase 3: CRITICAL — Phase 2 state (paid) preserved for order 1"
    else
        fail "Phase 3: CRITICAL — Order 1 status changed to '$STATUS3' (expected 'paid')"
    fi
else
    fail "Phase 3: Cannot verify Phase 2 state — no order id"
fi

# Test 25: Get order history (state_transitions table from Phase 2)
if [ -n "$ORDER1_ID" ] && [ "$ORDER1_ID" != "null" ]; then
    HISTORY=$(curl -sf "$BASE/api/v1/orders/$ORDER1_ID/history" 2>/dev/null || echo "[]")
    HIST_COUNT=$(echo "$HISTORY" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    if [ "$HIST_COUNT" -ge "1" ]; then
        pass "Phase 3: Order history returns $HIST_COUNT transitions for order 1"
    else
        fail "Phase 3: Order history returned $HIST_COUNT transitions (expected >= 1)"
    fi
else
    fail "Phase 3: Cannot test history — no order id"
fi

# Test 26: Create new order in Phase 3 (with event publishing)
CREATE_V3=$(curl -sf -X POST "$BASE/api/v1/orders" \
    -H "Content-Type: application/json" \
    -d '{"customer_email":"dave@example.com","items":["new-item"],"total":25.00}' 2>/dev/null || echo "{}")
ORDER4_ID=$(echo "$CREATE_V3" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$ORDER4_ID" ] && [ "$ORDER4_ID" != "null" ]; then
    pass "Phase 3: Create order in v3 returns id (dave@example.com)"
else
    fail "Phase 3: Create order in v3 failed. Response: $CREATE_V3"
fi

# Test 27: Add note to Phase 1 order
if [ -n "$ORDER1_ID" ] && [ "$ORDER1_ID" != "null" ]; then
    NOTE=$(curl -sf -X POST "$BASE/api/v1/orders/$ORDER1_ID/notes" \
        -H "Content-Type: application/json" \
        -d '{"note":"Payment confirmed by support","author":"support-agent"}' 2>/dev/null || echo "{}")
    NOTE_ID=$(echo "$NOTE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    if [ -n "$NOTE_ID" ] && [ "$NOTE_ID" != "null" ]; then
        pass "Phase 3: Add note to Phase 1 order returns id=$NOTE_ID"
    else
        fail "Phase 3: Add note failed. Response: $NOTE"
    fi
else
    fail "Phase 3: Cannot add note — no order id"
fi

# Test 28: Add note to new v3 order
if [ -n "$ORDER4_ID" ] && [ "$ORDER4_ID" != "null" ]; then
    NOTE2=$(curl -sf -X POST "$BASE/api/v1/orders/$ORDER4_ID/notes" \
        -H "Content-Type: application/json" \
        -d '{"note":"New order from Phase 3","author":"system"}' 2>/dev/null || echo "{}")
    NOTE2_ID=$(echo "$NOTE2" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    if [ -n "$NOTE2_ID" ] && [ "$NOTE2_ID" != "null" ]; then
        pass "Phase 3: Add note to Phase 3 order returns id=$NOTE2_ID"
    else
        fail "Phase 3: Add note to v3 order failed. Response: $NOTE2"
    fi
else
    fail "Phase 3: Cannot add note to v3 order — no order id"
fi

# Test 29: Pay and ship new v3 order — event should publish without error
if [ -n "$ORDER4_ID" ] && [ "$ORDER4_ID" != "null" ]; then
    curl -sf -X POST "$BASE/api/v1/orders/$ORDER4_ID/pay" >/dev/null 2>&1 || true
    SHIP_V3=$(curl -sf -X POST "$BASE/api/v1/orders/$ORDER4_ID/ship" 2>/dev/null || echo "{}")
    SHIP_V3_STATUS=$(echo "$SHIP_V3" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    if [ "$SHIP_V3_STATUS" = "shipped" ]; then
        pass "Phase 3: State transition in v3 (with broker) succeeds — paid → shipped"
    else
        fail "Phase 3: Ship in v3 returned status='$SHIP_V3_STATUS' (expected 'shipped'). Response: $SHIP_V3"
    fi
else
    fail "Phase 3: Cannot test v3 transition — no order id"
fi

# Test 30: History for new v3 order has transitions logged
if [ -n "$ORDER4_ID" ] && [ "$ORDER4_ID" != "null" ]; then
    HIST3=$(curl -sf "$BASE/api/v1/orders/$ORDER4_ID/history" 2>/dev/null || echo "[]")
    HIST3_COUNT=$(echo "$HIST3" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    # Should have: created(pending), paid, shipped = 3 transitions
    if [ "$HIST3_COUNT" -ge "3" ]; then
        pass "Phase 3: New order history has $HIST3_COUNT transitions (create + pay + ship)"
    else
        fail "Phase 3: New order history has $HIST3_COUNT transitions (expected >= 3)"
    fi
else
    fail "Phase 3: Cannot verify new order history — no order id"
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
