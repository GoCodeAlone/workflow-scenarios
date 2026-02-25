#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 17: Full Lifecycle — Contacts API (Multi-Phase)
# Tests two deployment phases and validates state persistence across the upgrade.
# Outputs PASS: or FAIL: lines for each test.

NS="${NAMESPACE:-wf-scenario-17}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
PORT=18017
BASE="http://localhost:$PORT"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

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

deploy_version() {
    local config_file="$1"
    local label="$2"
    echo ""
    echo "--- Deploying $label ---"
    kubectl create configmap app \
        --from-file=app.yaml="$SCENARIO_DIR/config/$config_file" \
        -n "$NS" --dry-run=client -o yaml | kubectl apply -f -
    kubectl rollout restart deployment/workflow-server -n "$NS"
    kubectl wait --for=condition=ready pod -l app=workflow-server -n "$NS" --timeout=120s
    echo "--- $label ready ---"
}

init_db() {
    curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE/internal/init-db" 2>/dev/null || echo "000"
}

# ====================================================================
# PHASE 1: Deploy v1-contacts, create contacts, verify CRUD
# ====================================================================
echo ""
echo "========================================"
echo "PHASE 1: Contacts CRUD (v1-contacts)"
echo "========================================"

deploy_version "v1-contacts.yaml" "v1-contacts"
start_pf

# Test 1: Health check
RESP=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q '"ok"'; then
    pass "Phase 1: Health check returns ok"
else
    fail "Phase 1: Health check failed: $RESP"
fi

# Test 2: Phase identifier
if echo "$RESP" | grep -q "v1-contacts"; then
    pass "Phase 1: Health check identifies v1-contacts"
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

# Test 4: Create contact 1
C1=$(curl -sf -X POST "$BASE/api/v1/contacts" \
    -H "Content-Type: application/json" \
    -d '{"name":"Alice Smith","email":"alice@acme.com","phone":"+1-555-0101","company":"Acme Corp"}' 2>/dev/null || echo "{}")
C1_ID=$(echo "$C1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$C1_ID" ] && [ "$C1_ID" != "null" ]; then
    pass "Phase 1: Create contact Alice returns id=$C1_ID"
else
    fail "Phase 1: Create contact Alice failed. Response: $C1"
fi

# Test 5: Create contact 2
C2=$(curl -sf -X POST "$BASE/api/v1/contacts" \
    -H "Content-Type: application/json" \
    -d '{"name":"Bob Jones","email":"bob@widgets.com","phone":"+1-555-0102","company":"Widgets Inc"}' 2>/dev/null || echo "{}")
C2_ID=$(echo "$C2" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$C2_ID" ] && [ "$C2_ID" != "null" ]; then
    pass "Phase 1: Create contact Bob returns id=$C2_ID"
else
    fail "Phase 1: Create contact Bob failed. Response: $C2"
fi

# Test 6: Create contact 3
C3=$(curl -sf -X POST "$BASE/api/v1/contacts" \
    -H "Content-Type: application/json" \
    -d '{"name":"Carol White","email":"carol@startup.io","phone":"+1-555-0103","company":"StartupIO"}' 2>/dev/null || echo "{}")
C3_ID=$(echo "$C3" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$C3_ID" ] && [ "$C3_ID" != "null" ]; then
    pass "Phase 1: Create contact Carol returns id=$C3_ID"
else
    fail "Phase 1: Create contact Carol failed. Response: $C3"
fi

# Test 7: List contacts returns all 3
LIST1=$(curl -sf "$BASE/api/v1/contacts" 2>/dev/null || echo "[]")
COUNT1=$(echo "$LIST1" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [ "$COUNT1" -ge "3" ]; then
    pass "Phase 1: List contacts returns $COUNT1 contacts (>= 3)"
else
    fail "Phase 1: List contacts returned $COUNT1 (expected >= 3)"
fi

# Test 8: Get contact by ID
if [ -n "$C1_ID" ] && [ "$C1_ID" != "null" ]; then
    GET1=$(curl -sf "$BASE/api/v1/contacts/$C1_ID" 2>/dev/null || echo "{}")
    if echo "$GET1" | grep -q "Alice Smith"; then
        pass "Phase 1: Get contact by id returns correct data"
    else
        fail "Phase 1: Get contact $C1_ID returned unexpected: $GET1"
    fi
else
    fail "Phase 1: Cannot test get-by-id — no contact id"
fi

# Test 9: Update contact
if [ -n "$C2_ID" ] && [ "$C2_ID" != "null" ]; then
    UPD=$(curl -sf -X PUT "$BASE/api/v1/contacts/$C2_ID" \
        -H "Content-Type: application/json" \
        -d '{"company":"Widgets Corp"}' 2>/dev/null || echo "{}")
    if echo "$UPD" | grep -q "Widgets Corp"; then
        pass "Phase 1: Update contact company succeeds"
    else
        fail "Phase 1: Update contact failed. Response: $UPD"
    fi
else
    fail "Phase 1: Cannot test update — no contact id"
fi

# Test 10: Delete contact 3
if [ -n "$C3_ID" ] && [ "$C3_ID" != "null" ]; then
    DEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/api/v1/contacts/$C3_ID" 2>/dev/null || echo "000")
    if [ "$DEL_CODE" = "200" ] || [ "$DEL_CODE" = "204" ]; then
        pass "Phase 1: Delete contact returns 2xx ($DEL_CODE)"
    else
        fail "Phase 1: Delete contact returned $DEL_CODE (expected 200/204)"
    fi
else
    fail "Phase 1: Cannot test delete — no contact id"
fi

# Test 11: Validation — missing name returns error
BAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/contacts" \
    -H "Content-Type: application/json" \
    -d '{"email":"only@email.com"}' 2>/dev/null || echo "000")
if [ "$BAD_CODE" = "400" ] || [ "$BAD_CODE" = "422" ] || [ "$BAD_CODE" = "500" ]; then
    pass "Phase 1: Create without name returns error ($BAD_CODE)"
else
    fail "Phase 1: Validation missing — returned $BAD_CODE (expected 400/422/500)"
fi

# Test 12: 404 for nonexistent contact
NOT_FOUND=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/v1/contacts/99999" 2>/dev/null || echo "000")
if [ "$NOT_FOUND" = "404" ]; then
    pass "Phase 1: Get nonexistent contact returns 404"
else
    fail "Phase 1: Get nonexistent returned $NOT_FOUND (expected 404)"
fi

echo ""
echo "========================================"
echo "PHASE 2: Add Notes + Tags (v2-notes)"
echo "========================================"

deploy_version "v2-notes.yaml" "v2-notes"
start_pf

# Test 13: Health identifies v2
RESP2=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "ERROR")
if echo "$RESP2" | grep -q "v2-notes"; then
    pass "Phase 2: Health check identifies v2-notes"
else
    fail "Phase 2: Health check missing v2 identifier: $RESP2"
fi

# Test 14: Init DB v2 succeeds
INIT2=$(init_db)
if [ "$INIT2" = "200" ]; then
    pass "Phase 2: init-db (v2) returns 200"
else
    fail "Phase 2: init-db returned $INIT2 (expected 200)"
fi

# Test 15: CRITICAL — Phase 1 contacts still exist
LIST2=$(curl -sf "$BASE/api/v1/contacts" 2>/dev/null || echo "[]")
if echo "$LIST2" | grep -q "Alice Smith"; then
    pass "Phase 2: CRITICAL — Alice Smith contact persisted across upgrade"
else
    fail "Phase 2: CRITICAL — Alice Smith contact LOST after upgrade"
fi

# Test 16: CRITICAL — Updated contact data preserved
if echo "$LIST2" | grep -q "Widgets Corp"; then
    pass "Phase 2: CRITICAL — Updated company 'Widgets Corp' preserved after upgrade"
else
    fail "Phase 2: CRITICAL — Updated company data LOST after upgrade"
fi

# Test 17: Add note to Phase 1 contact (Alice)
if [ -n "$C1_ID" ] && [ "$C1_ID" != "null" ]; then
    NOTE=$(curl -sf -X POST "$BASE/api/v1/contacts/$C1_ID/notes" \
        -H "Content-Type: application/json" \
        -d '{"note":"Met at conference — potential enterprise customer"}' 2>/dev/null || echo "{}")
    NOTE_ID=$(echo "$NOTE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    if [ -n "$NOTE_ID" ] && [ "$NOTE_ID" != "null" ]; then
        pass "Phase 2: Add note to Phase 1 contact returns id=$NOTE_ID"
    else
        fail "Phase 2: Add note to Alice failed. Response: $NOTE"
    fi
else
    fail "Phase 2: Cannot add note — no contact id"
fi

# Test 18: List notes for contact
if [ -n "$C1_ID" ] && [ "$C1_ID" != "null" ]; then
    NOTES=$(curl -sf "$BASE/api/v1/contacts/$C1_ID/notes" 2>/dev/null || echo "[]")
    if echo "$NOTES" | grep -q "conference"; then
        pass "Phase 2: List notes returns note with expected content"
    else
        fail "Phase 2: List notes did not contain expected note. Response: $NOTES"
    fi
else
    fail "Phase 2: Cannot list notes — no contact id"
fi

# Test 19: Add tag to Phase 1 contact
if [ -n "$C1_ID" ] && [ "$C1_ID" != "null" ]; then
    TAG=$(curl -sf -X POST "$BASE/api/v1/contacts/$C1_ID/tags" \
        -H "Content-Type: application/json" \
        -d '{"tag":"enterprise"}' 2>/dev/null || echo "{}")
    if echo "$TAG" | grep -q "enterprise"; then
        pass "Phase 2: Add tag 'enterprise' to Phase 1 contact"
    else
        fail "Phase 2: Add tag failed. Response: $TAG"
    fi
else
    fail "Phase 2: Cannot add tag — no contact id"
fi

# Test 20: Add second tag
if [ -n "$C1_ID" ] && [ "$C1_ID" != "null" ]; then
    TAG2=$(curl -sf -X POST "$BASE/api/v1/contacts/$C1_ID/tags" \
        -H "Content-Type: application/json" \
        -d '{"tag":"vip"}' 2>/dev/null || echo "{}")
    if echo "$TAG2" | grep -q "vip"; then
        pass "Phase 2: Add tag 'vip' to Phase 1 contact"
    else
        fail "Phase 2: Add second tag failed. Response: $TAG2"
    fi
else
    fail "Phase 2: Cannot add second tag — no contact id"
fi

# Test 21: Add tag to Phase 1 Bob contact
if [ -n "$C2_ID" ] && [ "$C2_ID" != "null" ]; then
    TAG3=$(curl -sf -X POST "$BASE/api/v1/contacts/$C2_ID/tags" \
        -H "Content-Type: application/json" \
        -d '{"tag":"enterprise"}' 2>/dev/null || echo "{}")
    if echo "$TAG3" | grep -q "enterprise"; then
        pass "Phase 2: Add tag 'enterprise' to Bob contact"
    else
        fail "Phase 2: Add enterprise tag to Bob failed. Response: $TAG3"
    fi
else
    fail "Phase 2: Cannot add tag to Bob — no contact id"
fi

# Test 22: Search by tag returns tagged contacts
SEARCH=$(curl -sf "$BASE/api/v1/contacts/search?tag=enterprise" 2>/dev/null || echo "[]")
SEARCH_COUNT=$(echo "$SEARCH" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [ "$SEARCH_COUNT" -ge "2" ]; then
    pass "Phase 2: Search by tag 'enterprise' returns $SEARCH_COUNT contacts (Alice + Bob)"
else
    fail "Phase 2: Search by tag returned $SEARCH_COUNT contacts (expected >= 2)"
fi

# Test 23: List tags for contact
if [ -n "$C1_ID" ] && [ "$C1_ID" != "null" ]; then
    TAGS=$(curl -sf "$BASE/api/v1/contacts/$C1_ID/tags" 2>/dev/null || echo "[]")
    if echo "$TAGS" | grep -q "enterprise"; then
        pass "Phase 2: List tags returns 'enterprise' tag for Alice"
    else
        fail "Phase 2: List tags missing 'enterprise'. Response: $TAGS"
    fi
else
    fail "Phase 2: Cannot list tags — no contact id"
fi

# Test 24: Duplicate tag is idempotent (INSERT OR IGNORE)
if [ -n "$C1_ID" ] && [ "$C1_ID" != "null" ]; then
    DUP_TAG_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/contacts/$C1_ID/tags" \
        -H "Content-Type: application/json" \
        -d '{"tag":"enterprise"}' 2>/dev/null || echo "000")
    if [ "$DUP_TAG_CODE" = "200" ] || [ "$DUP_TAG_CODE" = "201" ]; then
        pass "Phase 2: Duplicate tag insertion is idempotent ($DUP_TAG_CODE)"
    else
        fail "Phase 2: Duplicate tag returned $DUP_TAG_CODE (expected 2xx)"
    fi
else
    fail "Phase 2: Cannot test duplicate tag — no contact id"
fi

# Test 25: Create new contact in Phase 2, add note + tag
NEW_C=$(curl -sf -X POST "$BASE/api/v1/contacts" \
    -H "Content-Type: application/json" \
    -d '{"name":"Dave Kim","email":"dave@newco.com","company":"NewCo"}' 2>/dev/null || echo "{}")
NEW_C_ID=$(echo "$NEW_C" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
if [ -n "$NEW_C_ID" ] && [ "$NEW_C_ID" != "null" ]; then
    pass "Phase 2: Create new contact in Phase 2 returns id=$NEW_C_ID"
else
    fail "Phase 2: Create contact in Phase 2 failed. Response: $NEW_C"
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
