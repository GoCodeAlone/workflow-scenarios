#!/usr/bin/env bash
# Scenario 57: Salesforce Integration
# Tests workflow-plugin-salesforce step types against a mock Salesforce API server.
set -euo pipefail

PORT=18057
NAMESPACE="${NAMESPACE:-wf-scenario-57}"
BASE_URL="${BASE_URL:-http://localhost:${PORT}}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 57: Salesforce Integration ==="

# Start port-forward if not already reachable
if ! curl -sf --max-time 2 "${BASE_URL}/healthz" &>/dev/null; then
    kubectl port-forward -n "$NAMESPACE" svc/workflow-server "${PORT}:8080" &>/dev/null &
    PF_PID=$!
    trap "kill $PF_PID 2>/dev/null || true" EXIT
    for i in $(seq 1 30); do
        if curl -sf --max-time 2 "${BASE_URL}/healthz" &>/dev/null; then break; fi
        sleep 1
    done
fi

echo ""

# Test 1: Health check
RESULT=$(curl -s "$BASE_URL/healthz")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$STATUS" = "ok" ] && pass "Health check returns ok" || fail "Health check failed (got: $STATUS)"

SCENARIO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scenario',''))" 2>/dev/null || echo "")
[ "$SCENARIO" = "57-salesforce-integration" ] && pass "Health check identifies scenario 57" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# ----------------------------------------------------------------
# SObject CRUD Tests
# ----------------------------------------------------------------

# Test 3: Create Account record
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/sf/records/Account" \
  -H "Content-Type: application/json" \
  -d '{"fields":{"Name":"Acme Corporation","Industry":"Technology","Website":"https://acme.example.com"}}')
CREATE_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
CREATE_SUCCESS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null || echo "")
[ -n "$CREATE_ID" ] && [ "$CREATE_ID" != "null" ] && pass "Create record returns id" || fail "Create record missing id (got: $CREATE_ID)"
[ "$CREATE_SUCCESS" = "True" ] && pass "Create record success is true" || fail "Create record success mismatch (got: $CREATE_SUCCESS)"

# Test 5: Get Account record
RESULT=$(curl -s "$BASE_URL/api/v1/sf/records/Account/001Dn00000ABC123DEF")
GET_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Id',''))" 2>/dev/null || echo "")
GET_NAME=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Name',''))" 2>/dev/null || echo "")
[ "$GET_ID" = "001Dn00000ABC123DEF" ] && pass "Get record returns correct Id" || fail "Get record Id mismatch (got: $GET_ID)"
[ "$GET_NAME" = "Acme Corporation" ] && pass "Get record returns Name field" || fail "Get record Name mismatch (got: $GET_NAME)"

# Test 7: Get record has attributes
GET_TYPE=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('attributes',{}).get('type',''))" 2>/dev/null || echo "")
[ "$GET_TYPE" = "Account" ] && pass "Get record attributes.type is Account" || fail "Get record attributes.type mismatch (got: $GET_TYPE)"

# Test 8: Update Account record
RESULT=$(curl -s -X PATCH "$BASE_URL/api/v1/sf/records/Account/001Dn00000ABC123DEF" \
  -H "Content-Type: application/json" \
  -d '{"fields":{"Name":"Acme Corp Updated","Industry":"Finance"}}')
UPDATE_SUCCESS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null || echo "")
[ "$UPDATE_SUCCESS" = "True" ] && pass "Update record returns success" || fail "Update record success mismatch (got: $UPDATE_SUCCESS)"

# Test 9: Delete Account record
RESULT=$(curl -s -X DELETE "$BASE_URL/api/v1/sf/records/Account/001Dn00000ABC123DEF")
DELETE_SUCCESS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null || echo "")
[ "$DELETE_SUCCESS" = "True" ] && pass "Delete record returns success" || fail "Delete record success mismatch (got: $DELETE_SUCCESS)"

# ----------------------------------------------------------------
# SOQL Query Tests
# ----------------------------------------------------------------

# Test 10: SOQL query returns records
RESULT=$(curl -s "$BASE_URL/api/v1/sf/query?soql=SELECT+Id,Name+FROM+Account")
TOTAL=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_size',0))" 2>/dev/null || echo "0")
DONE=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('done',''))" 2>/dev/null || echo "")
[ "$TOTAL" -ge 1 ] && pass "SOQL query returns records (total_size=$TOTAL)" || fail "SOQL query returned no records (total_size=$TOTAL)"
[ "$DONE" = "True" ] && pass "SOQL query done is true" || fail "SOQL query done mismatch (got: $DONE)"

# Test 12: SOQL query records have attributes
FIRST_ID=$(echo "$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin).get('records',[]); print(r[0].get('Id','') if r else '')" 2>/dev/null || echo "")
[ -n "$FIRST_ID" ] && [ "$FIRST_ID" != "null" ] && pass "SOQL query records contain Id field" || fail "SOQL query record missing Id (got: $FIRST_ID)"

# ----------------------------------------------------------------
# Metadata Tests
# ----------------------------------------------------------------

# Test 13: Describe global lists SObject types
RESULT=$(curl -s "$BASE_URL/api/v1/sf/describe")
SOBJECT_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('sobjects',[])))" 2>/dev/null || echo "0")
[ "$SOBJECT_COUNT" -ge 1 ] && pass "Describe global returns sobjects (count=$SOBJECT_COUNT)" || fail "Describe global returned no sobjects (count=$SOBJECT_COUNT)"

# Test 14: Describe global contains Account
HAS_ACCOUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); names=[s.get('name') for s in d.get('sobjects',[])]; print('Account' in names)" 2>/dev/null || echo "")
[ "$HAS_ACCOUNT" = "True" ] && pass "Describe global includes Account" || fail "Describe global missing Account"

# Test 15: Describe object returns field metadata
RESULT=$(curl -s "$BASE_URL/api/v1/sf/describe/Account")
FIELD_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('fields',[])))" 2>/dev/null || echo "0")
DESCRIBE_NAME=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
[ "$FIELD_COUNT" -ge 1 ] && pass "Describe object returns fields (count=$FIELD_COUNT)" || fail "Describe object returned no fields (count=$FIELD_COUNT)"
[ "$DESCRIBE_NAME" = "Account" ] && pass "Describe object name is Account" || fail "Describe object name mismatch (got: $DESCRIBE_NAME)"

# ----------------------------------------------------------------
# Org Limits Tests
# ----------------------------------------------------------------

# Test 17: Org limits returns API request limits
RESULT=$(curl -s "$BASE_URL/api/v1/sf/limits")
HAS_DAILY=$(echo "$RESULT" | python3 -c "import sys,json; print('DailyApiRequests' in json.load(sys.stdin))" 2>/dev/null || echo "")
[ "$HAS_DAILY" = "True" ] && pass "Org limits contains DailyApiRequests" || fail "Org limits missing DailyApiRequests"

# ----------------------------------------------------------------
# Identity Tests
# ----------------------------------------------------------------

# Test 18: Identity returns current user info
RESULT=$(curl -s "$BASE_URL/api/v1/sf/identity")
USER_EMAIL=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('email',''))" 2>/dev/null || echo "")
USER_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('user_id',''))" 2>/dev/null || echo "")
[ -n "$USER_EMAIL" ] && [ "$USER_EMAIL" != "null" ] && pass "Identity returns email" || fail "Identity missing email (got: $USER_EMAIL)"
[ -n "$USER_ID" ] && [ "$USER_ID" != "null" ] && pass "Identity returns user_id" || fail "Identity missing user_id (got: $USER_ID)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
