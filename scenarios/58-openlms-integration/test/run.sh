#!/usr/bin/env bash
# Scenario 58: OpenLMS Integration
# Tests workflow-plugin-openlms step types against a mock Moodle Web Services server.
set -euo pipefail

PORT=18058
NAMESPACE="${NAMESPACE:-wf-scenario-58}"
BASE_URL="${BASE_URL:-http://localhost:${PORT}}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 58: OpenLMS Integration ==="

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
[ "$SCENARIO" = "58-openlms-integration" ] && pass "Health check identifies scenario 58" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# ----------------------------------------------------------------
# User Tests
# ----------------------------------------------------------------

# Test 3: Create user
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/openlms/users" \
  -H "Content-Type: application/json" \
  -d '{"username":"jdoe","password":"Pass1234!","firstname":"John","lastname":"Doe","email":"jdoe@example.com"}')
USER_ID=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); u=d.get('user',{}); print(u.get('id','') if u else '')" 2>/dev/null || echo "")
[ "$USER_ID" = "2" ] && pass "Create user returns user id" || fail "Create user id mismatch (got: $USER_ID)"

USER_NAME=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); u=d.get('user',{}); print(u.get('username','') if u else '')" 2>/dev/null || echo "")
[ "$USER_NAME" = "jdoe" ] && pass "Create user returns correct username" || fail "Create user username mismatch (got: $USER_NAME)"

# Test 5: Get user by username
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/openlms/users/get" \
  -H "Content-Type: application/json" \
  -d '{"key":"username","value":"jdoe"}')
GET_USER_EMAIL=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); u=d.get('user',{}); print(u.get('email','') if u else '')" 2>/dev/null || echo "")
[ "$GET_USER_EMAIL" = "jdoe@example.com" ] && pass "Get user returns correct email" || fail "Get user email mismatch (got: $GET_USER_EMAIL)"

GET_TOTAL=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total',''))" 2>/dev/null || echo "")
[ "$GET_TOTAL" = "1" ] && pass "Get user returns totalrecords=1" || fail "Get user total mismatch (got: $GET_TOTAL)"

# Test 7: Search users
RESULT=$(curl -s "$BASE_URL/api/v1/openlms/users/search/john")
SEARCH_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('users',[])))" 2>/dev/null || echo "0")
[ "$SEARCH_COUNT" -ge 1 ] && pass "Search users returns results" || fail "Search users returned no results (got: $SEARCH_COUNT)"

# ----------------------------------------------------------------
# Course Tests
# ----------------------------------------------------------------

# Test 8: Create course
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/openlms/courses" \
  -H "Content-Type: application/json" \
  -d '{"shortname":"CS101","fullname":"Introduction to Computer Science","categoryid":"1"}')
COURSE_ID=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); c=d.get('course',{}); print(c.get('id','') if c else '')" 2>/dev/null || echo "")
[ "$COURSE_ID" = "2" ] && pass "Create course returns course id" || fail "Create course id mismatch (got: $COURSE_ID)"

COURSE_SHORT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); c=d.get('course',{}); print(c.get('shortname','') if c else '')" 2>/dev/null || echo "")
[ "$COURSE_SHORT" = "CS101" ] && pass "Create course returns correct shortname" || fail "Create course shortname mismatch (got: $COURSE_SHORT)"

# Test 10: Get course
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/openlms/courses/get" \
  -H "Content-Type: application/json" \
  -d '{"courseid":"2"}')
GET_COURSE_NAME=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); c=d.get('course',{}); print(c.get('fullname','') if c else '')" 2>/dev/null || echo "")
[ "$GET_COURSE_NAME" = "Introduction to Computer Science" ] && pass "Get course returns correct fullname" || fail "Get course fullname mismatch (got: $GET_COURSE_NAME)"

# Test 11: Search courses
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/openlms/courses/search" \
  -H "Content-Type: application/json" \
  -d '{"criteriavalue":"CS"}')
SEARCH_COURSES=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('courses',[])))" 2>/dev/null || echo "0")
[ "$SEARCH_COURSES" -ge 1 ] && pass "Search courses returns results" || fail "Search courses returned no results (got: $SEARCH_COURSES)"

SEARCH_TOTAL=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total',''))" 2>/dev/null || echo "")
[ "$SEARCH_TOTAL" = "2" ] && pass "Search courses total is 2" || fail "Search courses total mismatch (got: $SEARCH_TOTAL)"

# Test 13: Get course contents
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/openlms/courses/contents" \
  -H "Content-Type: application/json" \
  -d '{"courseid":"2"}')
SECTIONS_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")
[ "$SECTIONS_COUNT" -ge 1 ] && pass "Get course contents returns sections" || fail "Get course contents returned no sections (got: $SECTIONS_COUNT)"

# ----------------------------------------------------------------
# Enrollment Tests
# ----------------------------------------------------------------

# Test 14: Enrol user in course
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/openlms/enrol" \
  -H "Content-Type: application/json" \
  -d '{"userid":"2","courseid":"2","roleid":"5"}')
ENROLLED=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('enrolled',''))" 2>/dev/null || echo "")
[ "$ENROLLED" = "True" ] && pass "Enrol user returns enrolled=true" || fail "Enrol user mismatch (got: $ENROLLED)"

# Test 15: Get enrolled users
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/openlms/enrol/users" \
  -H "Content-Type: application/json" \
  -d '{"courseid":"2"}')
ENROLLED_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")
[ "$ENROLLED_COUNT" -ge 1 ] && pass "Get enrolled users returns users" || fail "Get enrolled users returned none (got: $ENROLLED_COUNT)"

ENROLLED_USER=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); u=d.get('users',[]); print(u[0].get('username','') if u else '')" 2>/dev/null || echo "")
[ "$ENROLLED_USER" = "jdoe" ] && pass "Get enrolled users includes jdoe" || fail "Get enrolled users missing jdoe (got: $ENROLLED_USER)"

# ----------------------------------------------------------------
# Grade Tests
# ----------------------------------------------------------------

# Test 17: Get grades
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/openlms/grades" \
  -H "Content-Type: application/json" \
  -d '{"courseid":"2","userid":"2"}')
GRADE_ITEMS=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('items',[])))" 2>/dev/null || echo "0")
[ "$GRADE_ITEMS" -ge 1 ] && pass "Get grades returns items" || fail "Get grades returned no items (got: $GRADE_ITEMS)"

# Test 18: Get grade items (detailed report)
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/openlms/grades/items" \
  -H "Content-Type: application/json" \
  -d '{"courseid":"2","userid":"2"}')
USER_GRADES=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); ug=d.get('usergrades',[]); print(len(ug[0].get('gradeitems',[])) if ug else 0)" 2>/dev/null || echo "0")
[ "$USER_GRADES" -ge 1 ] && pass "Get grade items returns grade items" || fail "Get grade items returned none (got: $USER_GRADES)"

GRADE_VALUE=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); ug=d.get('usergrades',[]); gi=ug[0].get('gradeitems',[]) if ug else []; print(gi[0].get('gradeformatted','') if gi else '')" 2>/dev/null || echo "")
[ "$GRADE_VALUE" = "85.50" ] && pass "Get grade items first grade is 85.50" || fail "Get grade items value mismatch (got: $GRADE_VALUE)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
