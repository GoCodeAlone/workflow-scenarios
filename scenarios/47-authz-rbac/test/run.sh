#!/usr/bin/env bash
# Scenario 47: Authz RBAC
# Tests RBAC policy management: add policy → check (allowed) → remove → check (denied)
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:18047}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 47: Authz RBAC ==="
echo ""

# Test 1: Health check
RESULT=$(curl -s "$BASE_URL/healthz")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$STATUS" = "ok" ] && pass "Health check returns ok" || fail "Health check failed (got: $STATUS)"

SCENARIO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scenario',''))" 2>/dev/null || echo "")
[ "$SCENARIO" = "47-authz-rbac" ] && pass "Health check identifies scenario 47" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# Test 2: Init DB
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/internal/init-db")
[ "$HTTP_CODE" = "200" ] && pass "init-db returns 200" || fail "init-db returned $HTTP_CODE (expected 200)"

# Test 3: Add a policy (admin can read documents)
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/policies" \
  -H "Content-Type: application/json" \
  -d '{"role":"admin","resource":"documents","action":"read"}')
POL_ROLE=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('role',''))" 2>/dev/null || echo "")
[ "$POL_ROLE" = "admin" ] && pass "Add policy returns role=admin" || fail "Add policy failed (got: $RESULT)"

POL_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
[ -n "$POL_ID" ] && pass "Add policy returns ID" || fail "Add policy missing ID"

# Test 4: Add policy for editor role
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/policies" \
  -H "Content-Type: application/json" \
  -d '{"role":"editor","resource":"documents","action":"write"}')
EDITOR_ROLE=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('role',''))" 2>/dev/null || echo "")
[ "$EDITOR_ROLE" = "editor" ] && pass "Add editor policy succeeds" || fail "Add editor policy failed (got: $RESULT)"

# Test 5: List policies shows both
RESULT=$(curl -s "$BASE_URL/api/v1/policies")
POL_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else -1)" 2>/dev/null || echo "-1")
[ "$POL_COUNT" -ge 2 ] && pass "List policies returns at least 2 entries" || fail "List policies returned $POL_COUNT (expected >= 2)"

# Test 6: Assign admin role to alice
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/roles/assign" \
  -H "Content-Type: application/json" \
  -d '{"user":"alice","role":"admin"}')
ASSIGNED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('assigned',''))" 2>/dev/null || echo "")
[ "$ASSIGNED" = "True" ] && pass "Assign admin role to alice succeeds" || fail "Assign role failed (got: $RESULT)"

# Test 7: Assign editor role to bob
curl -s -X POST "$BASE_URL/api/v1/roles/assign" \
  -H "Content-Type: application/json" \
  -d '{"user":"bob","role":"editor"}' > /dev/null

# Test 8: List alice's roles
RESULT=$(curl -s "$BASE_URL/api/v1/roles/alice")
ALICE_ROLES=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else -1)" 2>/dev/null || echo "-1")
[ "$ALICE_ROLES" -ge 1 ] && pass "List roles for alice returns at least 1 role" || fail "List alice roles returned $ALICE_ROLES"

# Test 9: alice CAN read documents (has admin role with read policy)
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/check" \
  -H "Content-Type: application/json" \
  -d '{"user":"alice","resource":"documents","action":"read"}')
ALLOWED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('allowed',''))" 2>/dev/null || echo "")
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/v1/check" \
  -H "Content-Type: application/json" \
  -d '{"user":"alice","resource":"documents","action":"read"}')
[ "$ALLOWED" = "True" ] && pass "alice can read documents (allowed=true)" || fail "alice read documents check failed (got: $RESULT)"
[ "$HTTP_CODE" = "200" ] && pass "Allow check returns 200" || fail "Allow check returned $HTTP_CODE (expected 200)"

# Test 10: bob CANNOT read documents (editor role has only write policy)
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/check" \
  -H "Content-Type: application/json" \
  -d '{"user":"bob","resource":"documents","action":"read"}')
ALLOWED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('allowed',''))" 2>/dev/null || echo "")
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/v1/check" \
  -H "Content-Type: application/json" \
  -d '{"user":"bob","resource":"documents","action":"read"}')
[ "$ALLOWED" = "False" ] && pass "bob cannot read documents (allowed=false)" || fail "bob read documents check wrong (got: $RESULT)"
[ "$HTTP_CODE" = "403" ] && pass "Deny check returns 403" || fail "Deny check returned $HTTP_CODE (expected 403)"

# Test 11: bob CAN write documents (editor role has write policy)
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/check" \
  -H "Content-Type: application/json" \
  -d '{"user":"bob","resource":"documents","action":"write"}')
ALLOWED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('allowed',''))" 2>/dev/null || echo "")
[ "$ALLOWED" = "True" ] && pass "bob can write documents (allowed=true)" || fail "bob write documents check failed (got: $RESULT)"

# Test 12: unknown user is denied
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/check" \
  -H "Content-Type: application/json" \
  -d '{"user":"charlie","resource":"documents","action":"read"}')
ALLOWED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('allowed',''))" 2>/dev/null || echo "")
[ "$ALLOWED" = "False" ] && pass "Unknown user denied access (allowed=false)" || fail "Unknown user access wrong (got: $RESULT)"

# Test 13: Remove admin read-documents policy
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE_URL/api/v1/policies" \
  -H "Content-Type: application/json" \
  -d '{"role":"admin","resource":"documents","action":"read"}')
[ "$HTTP_CODE" = "200" ] && pass "Delete policy returns 200" || fail "Delete policy returned $HTTP_CODE (expected 200)"

# Test 14: alice CANNOT read documents after policy removed
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/check" \
  -H "Content-Type: application/json" \
  -d '{"user":"alice","resource":"documents","action":"read"}')
ALLOWED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('allowed',''))" 2>/dev/null || echo "")
[ "$ALLOWED" = "False" ] && pass "alice denied after policy removed (allowed=false)" || fail "alice still allowed after policy removal (got: $RESULT)"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/v1/check" \
  -H "Content-Type: application/json" \
  -d '{"user":"alice","resource":"documents","action":"read"}')
[ "$HTTP_CODE" = "403" ] && pass "Post-removal deny returns 403" || fail "Post-removal deny returned $HTTP_CODE (expected 403)"

# Test 15: List policies shows one less
RESULT=$(curl -s "$BASE_URL/api/v1/policies")
POL_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else -1)" 2>/dev/null || echo "-1")
[ "$POL_COUNT" -ge 1 ] && pass "Policy list still has remaining policies" || fail "Policy list unexpectedly empty (got: $POL_COUNT)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
