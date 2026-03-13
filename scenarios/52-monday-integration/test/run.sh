#!/usr/bin/env bash
# Scenario 52: monday.com Integration
# Tests monday.com plugin steps against a mock GraphQL API server.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:18052}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 52: monday.com Integration ==="
echo ""

# Test 1: Health check
RESULT=$(curl -s "$BASE_URL/healthz")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$STATUS" = "ok" ] && pass "Health check returns ok" || fail "Health check failed (got: $STATUS)"

SCENARIO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scenario',''))" 2>/dev/null || echo "")
[ "$SCENARIO" = "52-monday-integration" ] && pass "Health check identifies scenario 52" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# Test 2: Create board
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/monday/boards" \
  -H "Content-Type: application/json" \
  -d '{"board_name":"Test Board","board_kind":"public"}')
BOARD_ID=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id', d.get('board_id','')))" 2>/dev/null || echo "")
[ -n "$BOARD_ID" ] && [ "$BOARD_ID" != "null" ] && pass "Create board returns id" || fail "Create board missing id (got: $RESULT)"

BOARD_NAME=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
[ -n "$BOARD_NAME" ] && [ "$BOARD_NAME" != "null" ] && pass "Create board returns name" || fail "Create board missing name (got: $RESULT)"

# Test 3: List boards
RESULT=$(curl -s "$BASE_URL/api/v1/monday/boards")
BOARDS=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); boards=d.get('boards',[]); print(len(boards))" 2>/dev/null || echo "0")
[ "$BOARDS" -gt 0 ] && pass "List boards returns non-empty array" || fail "List boards returned empty or error (got: $RESULT)"

BOARD_STATE=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('boards',[])[0].get('state',''))" 2>/dev/null || echo "")
[ -n "$BOARD_STATE" ] && pass "List boards entries have state field" || fail "List boards entries missing state field (got: $RESULT)"

# Test 4: Create item
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/monday/items" \
  -H "Content-Type: application/json" \
  -d '{"board_id":"1234567890","item_name":"Task Alpha"}')
ITEM_ID=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id', d.get('item_id','')))" 2>/dev/null || echo "")
[ -n "$ITEM_ID" ] && [ "$ITEM_ID" != "null" ] && pass "Create item returns id" || fail "Create item missing id (got: $RESULT)"

ITEM_NAME=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
[ -n "$ITEM_NAME" ] && [ "$ITEM_NAME" != "null" ] && pass "Create item returns name" || fail "Create item missing name (got: $RESULT)"

# Test 5: List items
RESULT=$(curl -s "$BASE_URL/api/v1/monday/items?board_id=1234567890")
ITEMS=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items=d.get('items', d.get('data', {}).get('items_page_by_column_values', {}).get('items', []))
print(len(items))
" 2>/dev/null || echo "0")
[ "$ITEMS" -gt 0 ] && pass "List items returns non-empty array" || fail "List items returned empty or error (got: $RESULT)"

# Test 6: Create group
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/monday/groups" \
  -H "Content-Type: application/json" \
  -d '{"board_id":"1234567890","group_name":"Sprint 1"}')
GROUP_ID=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id', d.get('group_id','')))" 2>/dev/null || echo "")
[ -n "$GROUP_ID" ] && [ "$GROUP_ID" != "null" ] && pass "Create group returns id" || fail "Create group missing id (got: $RESULT)"

GROUP_TITLE=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title',''))" 2>/dev/null || echo "")
[ -n "$GROUP_TITLE" ] && [ "$GROUP_TITLE" != "null" ] && pass "Create group returns title" || fail "Create group missing title (got: $RESULT)"

# Test 7: List groups
RESULT=$(curl -s "$BASE_URL/api/v1/monday/groups?board_id=1234567890")
GROUPS=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
# groups may be nested under boards[0].groups or top-level
groups=d.get('groups', [])
if not groups:
    boards=d.get('boards',[])
    if boards:
        groups=boards[0].get('groups',[])
print(len(groups))
" 2>/dev/null || echo "0")
[ "$GROUPS" -gt 0 ] && pass "List groups returns non-empty array" || fail "List groups returned empty or error (got: $RESULT)"

# Test 8: Generic query
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/monday/query" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ users { id name email } }"}')
HAS_DATA=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d else 'no')" 2>/dev/null || echo "no")
[ "$HAS_DATA" = "yes" ] && pass "Generic query returns data" || fail "Generic query returned empty response"

# Test 9: List users
RESULT=$(curl -s "$BASE_URL/api/v1/monday/users")
USERS=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
users=d.get('users',[])
print(len(users))
" 2>/dev/null || echo "0")
[ "$USERS" -gt 0 ] && pass "List users returns non-empty array" || fail "List users returned empty or error (got: $RESULT)"

USER_NAME=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('users',[])[0].get('name',''))" 2>/dev/null || echo "")
[ -n "$USER_NAME" ] && pass "List users entries have name field" || fail "List users entries missing name field (got: $RESULT)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
