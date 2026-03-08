#!/usr/bin/env bash
# Scenario 46: GitHub CI/CD Integration
# Tests webhook receipt, workflow dispatch, status polling, and state transitions.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:18046}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 46: GitHub CI/CD Integration ==="
echo ""

# Test 1: Health check
RESULT=$(curl -s "$BASE_URL/healthz")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$STATUS" = "ok" ] && pass "Health check returns ok" || fail "Health check failed (got: $STATUS)"

SCENARIO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scenario',''))" 2>/dev/null || echo "")
[ "$SCENARIO" = "46-github-cicd" ] && pass "Health check identifies scenario 46" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# Test 2: Init DB
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/internal/init-db")
[ "$HTTP_CODE" = "200" ] && pass "init-db returns 200" || fail "init-db returned $HTTP_CODE (expected 200)"

# Test 3: Webhook rejected without signature
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/webhooks/github" \
  -H "Content-Type: application/json" \
  -d '{"action":"opened","repository":{"full_name":"owner/repo"}}')
[ "$HTTP_CODE" = "401" ] && pass "Webhook without signature returns 401" || fail "Webhook without signature returned $HTTP_CODE (expected 401)"

# Test 4: Webhook accepted with signature header
RESULT=$(curl -s -X POST "$BASE_URL/webhooks/github" \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: sha256=abc123" \
  -H "X-GitHub-Event: push" \
  -d '{"action":"","repository":{"full_name":"owner/repo"}}')
RECEIVED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('received',''))" 2>/dev/null || echo "")
[ "$RECEIVED" = "True" ] && pass "Webhook with signature returns received=true" || fail "Webhook with signature failed (got received=$RECEIVED, response: $RESULT)"

EVENT_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('event_id',''))" 2>/dev/null || echo "")
[ -n "$EVENT_ID" ] && pass "Webhook returns event_id" || fail "Webhook missing event_id (response: $RESULT)"

# Test 5: Dispatch a workflow run
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/actions/dispatch" \
  -H "Content-Type: application/json" \
  -d '{"repo":"owner/repo","workflow":"ci.yml","ref":"main"}')
RUN_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
[ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] && pass "Dispatch run returns run ID" || fail "Dispatch run failed (got: $RESULT)"

RUN_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$RUN_STATUS" = "pending" ] && pass "New run status is pending" || fail "New run status is not pending (got: $RUN_STATUS)"

RUN_REPO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('repo',''))" 2>/dev/null || echo "")
[ "$RUN_REPO" = "owner/repo" ] && pass "Run stores correct repo" || fail "Run repo mismatch (got: $RUN_REPO)"

# Test 6: Get run status by ID
RESULT=$(curl -s "$BASE_URL/api/v1/actions/runs/$RUN_ID")
FETCHED_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$FETCHED_STATUS" = "pending" ] && pass "Get run returns pending status" || fail "Get run status mismatch (got: $FETCHED_STATUS)"

# Test 7: Get non-existent run returns 404
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/v1/actions/runs/run-does-not-exist")
[ "$HTTP_CODE" = "404" ] && pass "Get non-existent run returns 404" || fail "Get non-existent run returned $HTTP_CODE (expected 404)"

# Test 8: Complete run with success
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/actions/runs/$RUN_ID/complete" \
  -H "Content-Type: application/json" \
  -d '{"conclusion":"success"}')
COMPLETED_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
CONCLUSION=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('conclusion',''))" 2>/dev/null || echo "")
[ "$COMPLETED_STATUS" = "completed" ] && pass "Run transitions to completed status" || fail "Run status not completed (got: $COMPLETED_STATUS)"
[ "$CONCLUSION" = "success" ] && pass "Run conclusion is success" || fail "Run conclusion mismatch (got: $CONCLUSION)"

# Test 9: Verify final state via GET
RESULT=$(curl -s "$BASE_URL/api/v1/actions/runs/$RUN_ID")
FINAL_STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
FINAL_CONCLUSION=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('conclusion',''))" 2>/dev/null || echo "")
[ "$FINAL_STATUS" = "completed" ] && pass "Persisted run status is completed" || fail "Persisted run status mismatch (got: $FINAL_STATUS)"
[ "$FINAL_CONCLUSION" = "success" ] && pass "Persisted run conclusion is success" || fail "Persisted run conclusion mismatch (got: $FINAL_CONCLUSION)"

# Test 10: Dispatch second run with failure conclusion
RESULT2=$(curl -s -X POST "$BASE_URL/api/v1/actions/dispatch" \
  -H "Content-Type: application/json" \
  -d '{"repo":"owner/repo","workflow":"deploy.yml","ref":"feature-branch"}')
RUN_ID2=$(echo "$RESULT2" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
[ -n "$RUN_ID2" ] && pass "Second dispatch run returns ID" || fail "Second dispatch failed"

curl -s -X POST "$BASE_URL/api/v1/actions/runs/$RUN_ID2/complete" \
  -H "Content-Type: application/json" \
  -d '{"conclusion":"failure"}' > /dev/null

RESULT2=$(curl -s "$BASE_URL/api/v1/actions/runs/$RUN_ID2")
FAIL_CONCLUSION=$(echo "$RESULT2" | python3 -c "import sys,json; print(json.load(sys.stdin).get('conclusion',''))" 2>/dev/null || echo "")
[ "$FAIL_CONCLUSION" = "failure" ] && pass "Run with failure conclusion stored correctly" || fail "Failure conclusion mismatch (got: $FAIL_CONCLUSION)"

# Test 11: List runs returns array
RESULT=$(curl -s "$BASE_URL/api/v1/actions/runs")
COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else -1)" 2>/dev/null || echo "-1")
[ "$COUNT" -ge 2 ] && pass "List runs returns at least 2 entries" || fail "List runs returned $COUNT entries (expected >= 2)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
