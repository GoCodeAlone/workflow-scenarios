#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 83: Enterprise Lead Enrichment
# AI-powered lead scoring with CRM sync and human-in-the-loop approval
# Outputs PASS: or FAIL: lines for each test

LOCAL_PORT=18083
NAMESPACE="${NAMESPACE:-wf-scenario-enterprise-lead-enrichment}"
BASE="http://localhost:${LOCAL_PORT}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Port-forward with retry
if ! curl -sf --max-time 2 "${BASE}/healthz" &>/dev/null; then
    kubectl port-forward -n "$NAMESPACE" svc/workflow-server "${LOCAL_PORT}:8080" &>/dev/null &
    PF_PID=$!
    trap "kill $PF_PID 2>/dev/null || true" EXIT
    for i in $(seq 1 30); do
        if curl -sf --max-time 2 "${BASE}/healthz" &>/dev/null; then break; fi
        sleep 1
    done
fi

# ---------- Test 1: Health check ----------
RESPONSE=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "")
if echo "$RESPONSE" | grep -q '"ok"'; then
    pass "Health check returns ok"
else
    fail "Health check failed: $RESPONSE"
fi

# ---------- Test 2: High-score lead (auto-approve path) ----------
HIGH_SCORE_BODY='{
  "first_name": "Jane",
  "last_name": "Smith",
  "company": "Acme Corp",
  "email": "jane.smith@acmecorp.com",
  "phone": "+1-555-0100",
  "source": "conference"
}'

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$BASE/api/leads" \
    -H "Content-Type: application/json" \
    -d "$HIGH_SCORE_BODY" 2>/dev/null || echo "000")

RESULT=$(curl -s -X POST "$BASE/api/leads" \
    -H "Content-Type: application/json" \
    -d "$HIGH_SCORE_BODY" 2>/dev/null || echo "{}")

if [ "$HTTP_CODE" = "200" ]; then
    pass "High-score lead returns 200"
else
    fail "High-score lead returned $HTTP_CODE (expected 200)"
fi

# Verify response contains CRM record ID
if echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('crm_record_id')" 2>/dev/null; then
    pass "High-score lead response contains crm_record_id"
else
    fail "High-score lead response missing crm_record_id: $RESULT"
fi

# Verify response contains lead_id
if echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('lead_id','').startswith('lead-')" 2>/dev/null; then
    pass "High-score lead response contains valid lead_id"
else
    fail "High-score lead response missing lead_id: $RESULT"
fi

# Verify status is created
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
if [ "$STATUS" = "created" ]; then
    pass "High-score lead status is 'created'"
else
    fail "High-score lead status is '$STATUS' (expected 'created')"
fi

# ---------- Test 3: Medium-score lead (approval path) ----------
MEDIUM_SCORE_BODY='{
  "first_name": "Bob",
  "last_name": "Jones",
  "company": "Small Startup LLC",
  "email": "bob@smallstartup.io",
  "source": "web"
}'

APPROVAL_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$BASE/api/leads" \
    -H "Content-Type: application/json" \
    -d "$MEDIUM_SCORE_BODY" 2>/dev/null || echo "000")

APPROVAL_RESULT=$(curl -s -X POST "$BASE/api/leads" \
    -H "Content-Type: application/json" \
    -d "$MEDIUM_SCORE_BODY" 2>/dev/null || echo "{}")

if [ "$APPROVAL_CODE" = "202" ]; then
    pass "Medium-score lead returns 202 (pending approval)"
else
    fail "Medium-score lead returned $APPROVAL_CODE (expected 202)"
fi

# Verify response contains approval_id
if echo "$APPROVAL_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('approval_id')" 2>/dev/null; then
    pass "Medium-score lead response contains approval_id"
else
    fail "Medium-score lead response missing approval_id: $APPROVAL_RESULT"
fi

# Verify status is pending_approval
APPROVAL_STATUS=$(echo "$APPROVAL_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
if [ "$APPROVAL_STATUS" = "pending_approval" ]; then
    pass "Medium-score lead status is 'pending_approval'"
else
    fail "Medium-score lead status is '$APPROVAL_STATUS' (expected 'pending_approval')"
fi

# ---------- Test 4: Invalid payload (empty body) ----------
INVALID_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$BASE/api/leads" \
    -H "Content-Type: application/json" \
    -d '{}' 2>/dev/null || echo "000")

if [ "$INVALID_CODE" = "400" ]; then
    pass "Empty body returns 400"
else
    fail "Empty body returned $INVALID_CODE (expected 400)"
fi

# Verify error message
INVALID_RESULT=$(curl -s -X POST "$BASE/api/leads" \
    -H "Content-Type: application/json" \
    -d '{}' 2>/dev/null || echo "{}")

if echo "$INVALID_RESULT" | grep -q "missing required fields"; then
    pass "Empty body returns descriptive error message"
else
    fail "Empty body error message not found: $INVALID_RESULT"
fi

# ---------- Test 5: Missing email field ----------
PARTIAL_BODY='{
  "first_name": "Alice",
  "last_name": "Doe",
  "company": "Test Inc"
}'

PARTIAL_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$BASE/api/leads" \
    -H "Content-Type: application/json" \
    -d "$PARTIAL_BODY" 2>/dev/null || echo "000")

if [ "$PARTIAL_CODE" = "400" ]; then
    pass "Missing email returns 400"
else
    fail "Missing email returned $PARTIAL_CODE (expected 400)"
fi

# ---------- Test 6: GET method not allowed ----------
METHOD_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "$BASE/api/leads" 2>/dev/null || echo "000")

if [ "$METHOD_CODE" = "404" ] || [ "$METHOD_CODE" = "405" ]; then
    pass "GET /api/leads returns 404 or 405"
else
    fail "GET /api/leads returned $METHOD_CODE (expected 404 or 405)"
fi

# ---------- Summary ----------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
