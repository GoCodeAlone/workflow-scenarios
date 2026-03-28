#!/usr/bin/env bash
# Scenario 51: Twilio Integration
# Tests workflow-plugin-twilio step types against a mock Twilio API server.
set -euo pipefail

PORT=18051
NAMESPACE="${NAMESPACE:-wf-scenario-63}"
BASE_URL="${BASE_URL:-http://localhost:${PORT}}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 51: Twilio Integration ==="

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
[ "$SCENARIO" = "51-twilio-integration" ] && pass "Health check identifies scenario 51" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# ----------------------------------------------------------------
# SMS Tests
# ----------------------------------------------------------------

# Test 3: Send SMS
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/twilio/sms" \
  -H "Content-Type: application/json" \
  -d '{"to":"+15005550001","from":"+15005550006","body":"Hello from scenario 51"}')
SMS_SID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sid',''))" 2>/dev/null || echo "")
SMS_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "${SMS_SID:0:2}" = "SM" ] && pass "Send SMS returns sid starting with SM" || fail "Send SMS sid invalid (got: $SMS_SID)"
[ "$SMS_STATUS" = "queued" ] && pass "Send SMS status is queued" || fail "Send SMS status mismatch (got: $SMS_STATUS)"

# Test 5: Send SMS with media (MMS)
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/twilio/mms" \
  -H "Content-Type: application/json" \
  -d '{"to":"+15005550001","from":"+15005550006","body":"MMS test","media_url":"https://example.com/image.jpg"}')
MMS_SID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sid',''))" 2>/dev/null || echo "")
[ "${MMS_SID:0:2}" = "SM" ] && pass "Send MMS returns sid starting with SM" || fail "Send MMS sid invalid (got: $MMS_SID)"
MMS_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$MMS_STATUS" = "queued" ] && pass "Send MMS status is queued" || fail "Send MMS status mismatch (got: $MMS_STATUS)"

# ----------------------------------------------------------------
# Message Listing Tests
# ----------------------------------------------------------------

# Test 7: List messages
RESULT=$(curl -s "$BASE_URL/api/v1/twilio/messages")
MSG_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('messages',[])))" 2>/dev/null || echo "0")
[ "$MSG_COUNT" -ge 1 ] && pass "List messages returns non-empty messages array" || fail "List messages returned no messages (got count: $MSG_COUNT)"

# Test 8: Fetch single message by SID
RESULT=$(curl -s "$BASE_URL/api/v1/twilio/messages/SM1234567890abcdef1234567890abcdef")
FETCH_SID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sid',''))" 2>/dev/null || echo "")
FETCH_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$FETCH_SID" = "SM1234567890abcdef1234567890abcdef" ] && pass "Fetch message returns correct sid" || fail "Fetch message sid mismatch (got: $FETCH_SID)"
[ -n "$FETCH_STATUS" ] && [ "$FETCH_STATUS" != "null" ] && pass "Fetch message has status field" || fail "Fetch message missing status (got: $FETCH_STATUS)"

# ----------------------------------------------------------------
# Verification Tests
# ----------------------------------------------------------------

# Test 10: Send verification
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/twilio/verify" \
  -H "Content-Type: application/json" \
  -d '{"to":"+15005550001","channel":"sms","service_sid":"VA_test_service"}')
VERIFY_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
VERIFY_SID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sid',''))" 2>/dev/null || echo "")
[ "$VERIFY_STATUS" = "pending" ] && pass "Send verification status is pending" || fail "Send verification status mismatch (got: $VERIFY_STATUS)"
[ "${VERIFY_SID:0:2}" = "VE" ] && pass "Send verification sid starts with VE" || fail "Send verification sid invalid (got: $VERIFY_SID)"

# Test 12: Check verification
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/twilio/verify/check" \
  -H "Content-Type: application/json" \
  -d '{"to":"+15005550001","code":"123456","service_sid":"VA_test_service"}')
CHECK_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$CHECK_STATUS" = "approved" ] && pass "Check verification status is approved" || fail "Check verification status mismatch (got: $CHECK_STATUS)"

# ----------------------------------------------------------------
# Call Tests
# ----------------------------------------------------------------

# Test 13: Create call
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/twilio/calls" \
  -H "Content-Type: application/json" \
  -d '{"to":"+15005550001","from":"+15005550006","url":"https://example.com/twiml"}')
CALL_SID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sid',''))" 2>/dev/null || echo "")
CALL_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "${CALL_SID:0:2}" = "CA" ] && pass "Create call returns sid starting with CA" || fail "Create call sid invalid (got: $CALL_SID)"
[ "$CALL_STATUS" = "queued" ] && pass "Create call status is queued" || fail "Create call status mismatch (got: $CALL_STATUS)"

# Test 15: List calls
RESULT=$(curl -s "$BASE_URL/api/v1/twilio/calls")
CALL_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('calls',[])))" 2>/dev/null || echo "0")
[ "$CALL_COUNT" -ge 1 ] && pass "List calls returns non-empty calls array" || fail "List calls returned no calls (got count: $CALL_COUNT)"

# ----------------------------------------------------------------
# Phone Lookup Tests
# ----------------------------------------------------------------

# Test 16: Lookup phone number
RESULT=$(curl -s "$BASE_URL/api/v1/twilio/lookup/%2B15005550001")
LOOKUP_PHONE=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('phone_number',''))" 2>/dev/null || echo "")
LOOKUP_CC=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('country_code',''))" 2>/dev/null || echo "")
[ -n "$LOOKUP_PHONE" ] && [ "$LOOKUP_PHONE" != "null" ] && pass "Lookup phone returns phone_number field" || fail "Lookup phone missing phone_number (got: $LOOKUP_PHONE)"
[ "$LOOKUP_CC" = "US" ] && pass "Lookup phone returns country_code US" || fail "Lookup phone country_code mismatch (got: $LOOKUP_CC)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
