#!/usr/bin/env bash
# Scenario 59: Discord Messaging
# Tests workflow-plugin-discord step types against a mock Discord API server.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:18059}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 59: Discord Messaging ==="
echo ""

# Test 1: Health check
RESULT=$(curl -s "$BASE_URL/healthz")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$STATUS" = "ok" ] && pass "Health check returns ok" || fail "Health check failed (got: $STATUS)"

SCENARIO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scenario',''))" 2>/dev/null || echo "")
[ "$SCENARIO" = "59-discord-messaging" ] && pass "Health check identifies scenario 59" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# ----------------------------------------------------------------
# Send Message
# ----------------------------------------------------------------

# Test 3: Send plain message
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/discord/send" \
  -H "Content-Type: application/json" \
  -d '{"channel_id":"123456789","content":"Hello from workflow!"}')
MSG_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
[ -n "$MSG_ID" ] && pass "Send message returns message id" || fail "Send message missing message id (got: $RESULT)"

CHAN_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('channel_id',''))" 2>/dev/null || echo "")
[ "$CHAN_ID" = "123456789" ] && pass "Send message returns correct channel_id" || fail "Send message channel_id mismatch (got: $CHAN_ID)"

# ----------------------------------------------------------------
# Send Embed
# ----------------------------------------------------------------

# Test 5: Send embed message
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/discord/embed" \
  -H "Content-Type: application/json" \
  -d '{"channel_id":"123456789","title":"Alert","description":"Something happened","color":"0xFF0000"}')
EMBED_MSG_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
[ -n "$EMBED_MSG_ID" ] && pass "Send embed returns message id" || fail "Send embed missing message id (got: $RESULT)"

EMBED_CHAN=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('channel_id',''))" 2>/dev/null || echo "")
[ "$EMBED_CHAN" = "123456789" ] && pass "Send embed returns correct channel_id" || fail "Send embed channel_id mismatch (got: $EMBED_CHAN)"

# Test 7: Send embed with default color
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/discord/embed" \
  -H "Content-Type: application/json" \
  -d '{"channel_id":"111222333","title":"Info","description":"Default color test"}')
DEFAULT_EMBED_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
[ -n "$DEFAULT_EMBED_ID" ] && pass "Send embed with default color returns message id" || fail "Send embed default color failed (got: $RESULT)"

# ----------------------------------------------------------------
# Add Reaction
# ----------------------------------------------------------------

# Test 8: Add emoji reaction
RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/v1/discord/react" \
  -H "Content-Type: application/json" \
  -d '{"channel_id":"123456789","message_id":"987654321","emoji":"👍"}')
[ "$RESULT" = "200" ] && pass "Add reaction returns 200" || fail "Add reaction status mismatch (got: $RESULT)"

# Test 9: Add reaction returns success field
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/discord/react" \
  -H "Content-Type: application/json" \
  -d '{"channel_id":"123456789","message_id":"987654321","emoji":"🎉"}')
SUCCESS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',''))" 2>/dev/null || echo "")
[ "$SUCCESS" = "True" ] && pass "Add reaction returns success=true" || fail "Add reaction success mismatch (got: $RESULT)"

# ----------------------------------------------------------------
# Create Thread
# ----------------------------------------------------------------

# Test 10: Create thread without starter message
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/discord/thread" \
  -H "Content-Type: application/json" \
  -d '{"channel_id":"123456789","name":"Discussion Thread"}')
THREAD_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('thread_id',''))" 2>/dev/null || echo "")
[ -n "$THREAD_ID" ] && pass "Create thread returns thread_id" || fail "Create thread missing thread_id (got: $RESULT)"

THREAD_NAME=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
[ "$THREAD_NAME" = "Discussion Thread" ] && pass "Create thread returns correct name" || fail "Create thread name mismatch (got: $THREAD_NAME)"

# Test 12: Create thread from existing message
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/discord/thread" \
  -H "Content-Type: application/json" \
  -d '{"channel_id":"123456789","name":"Reply Thread","message_id":"111222333"}')
THREAD_ID2=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('thread_id',''))" 2>/dev/null || echo "")
[ -n "$THREAD_ID2" ] && pass "Create thread from message returns thread_id" || fail "Create thread from message failed (got: $RESULT)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
