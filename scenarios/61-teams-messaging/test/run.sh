#!/usr/bin/env bash
# Scenario 61: Teams Messaging
# Tests workflow-plugin-teams step types against a mock Microsoft Graph API server.
set -euo pipefail

PORT=18061
NAMESPACE="${NAMESPACE:-wf-scenario-61}"
BASE_URL="${BASE_URL:-http://localhost:${PORT}}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 61: Teams Messaging ==="

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
[ "$SCENARIO" = "61-teams-messaging" ] && pass "Health check identifies scenario 61" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# ----------------------------------------------------------------
# Send Message
# ----------------------------------------------------------------

# Test 3: Send plain text message
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/teams/send" \
  -H "Content-Type: application/json" \
  -d '{"team_id":"team-abc","channel_id":"channel-xyz","content":"Hello Teams!"}')
MSG_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
[ -n "$MSG_ID" ] && pass "Send message returns message id" || fail "Send message missing id (got: $RESULT)"

WEB_URL=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('web_url',''))" 2>/dev/null || echo "")
[ -n "$WEB_URL" ] && pass "Send message returns web_url" || fail "Send message missing web_url (got: $RESULT)"

# ----------------------------------------------------------------
# Send Adaptive Card
# ----------------------------------------------------------------

# Test 5: Send adaptive card
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/teams/card" \
  -H "Content-Type: application/json" \
  -d '{"team_id":"team-abc","channel_id":"channel-xyz","card":{"type":"AdaptiveCard","version":"1.3","body":[{"type":"TextBlock","text":"Alert!"}]}}')
CARD_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
[ -n "$CARD_ID" ] && pass "Send card returns message id" || fail "Send card missing id (got: $RESULT)"

CARD_URL=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('web_url',''))" 2>/dev/null || echo "")
[ -n "$CARD_URL" ] && pass "Send card returns web_url" || fail "Send card missing web_url (got: $RESULT)"

# ----------------------------------------------------------------
# Reply to Message
# ----------------------------------------------------------------

# Test 7: Reply to existing message
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/teams/reply" \
  -H "Content-Type: application/json" \
  -d '{"team_id":"team-abc","channel_id":"channel-xyz","message_id":"mock-msg-1","content":"This is a reply"}')
REPLY_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
[ -n "$REPLY_ID" ] && pass "Reply message returns reply id" || fail "Reply message missing id (got: $RESULT)"

REPLY_TO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reply_to_id',''))" 2>/dev/null || echo "")
[ "$REPLY_TO" = "mock-msg-1" ] && pass "Reply message has correct reply_to_id" || fail "Reply message reply_to_id mismatch (got: $REPLY_TO)"

# ----------------------------------------------------------------
# Create Channel
# ----------------------------------------------------------------

# Test 9: Create new channel
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/teams/channel" \
  -H "Content-Type: application/json" \
  -d '{"team_id":"team-abc","name":"announcements","description":"Company announcements"}')
CHAN_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
[ -n "$CHAN_ID" ] && pass "Create channel returns channel id" || fail "Create channel missing id (got: $RESULT)"

CHAN_NAME=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('display_name',''))" 2>/dev/null || echo "")
[ "$CHAN_NAME" = "announcements" ] && pass "Create channel returns correct name" || fail "Create channel name mismatch (got: $CHAN_NAME)"

CHAN_URL=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('web_url',''))" 2>/dev/null || echo "")
[ -n "$CHAN_URL" ] && pass "Create channel returns web_url" || fail "Create channel missing web_url (got: $RESULT)"

# Test 12: Create channel without description
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/teams/channel" \
  -H "Content-Type: application/json" \
  -d '{"team_id":"team-abc","name":"general-discussion"}')
CHAN2_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
[ -n "$CHAN2_ID" ] && pass "Create channel without description returns channel id" || fail "Create channel no-description failed (got: $RESULT)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
