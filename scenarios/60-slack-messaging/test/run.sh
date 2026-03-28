#!/usr/bin/env bash
# Scenario 60: Slack Messaging
# Tests workflow-plugin-slack step types against a mock Slack API server.
set -euo pipefail

PORT=18060
NAMESPACE="${NAMESPACE:-wf-scenario-60}"
BASE_URL="${BASE_URL:-http://localhost:${PORT}}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 60: Slack Messaging ==="

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
[ "$SCENARIO" = "60-slack-messaging" ] && pass "Health check identifies scenario 60" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# ----------------------------------------------------------------
# Send Message
# ----------------------------------------------------------------

# Test 3: Send plain text message
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/slack/send" \
  -H "Content-Type: application/json" \
  -d '{"channel_id":"C1234567890","content":"Hello from workflow!"}')
OK=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',''))" 2>/dev/null || echo "")
[ "$OK" = "True" ] && pass "Send message returns ok=true" || fail "Send message ok mismatch (got: $RESULT)"

TS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ts',''))" 2>/dev/null || echo "")
[ -n "$TS" ] && pass "Send message returns timestamp" || fail "Send message missing timestamp (got: $RESULT)"

CHANNEL=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('channel',''))" 2>/dev/null || echo "")
[ "$CHANNEL" = "C1234567890" ] && pass "Send message returns correct channel" || fail "Send message channel mismatch (got: $CHANNEL)"

# ----------------------------------------------------------------
# Send Blocks
# ----------------------------------------------------------------

# Test 6: Send blocks message
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/slack/blocks" \
  -H "Content-Type: application/json" \
  -d '{"channel_id":"C1234567890","text":"Fallback text","blocks":[{"type":"section","text":{"type":"mrkdwn","text":"*Alert*: Something happened"}}]}')
BLOCKS_OK=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',''))" 2>/dev/null || echo "")
[ "$BLOCKS_OK" = "True" ] && pass "Send blocks returns ok=true" || fail "Send blocks ok mismatch (got: $RESULT)"

BLOCKS_TS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ts',''))" 2>/dev/null || echo "")
[ -n "$BLOCKS_TS" ] && pass "Send blocks returns timestamp" || fail "Send blocks missing timestamp (got: $RESULT)"

# Test 8: Send blocks with default text
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/slack/blocks" \
  -H "Content-Type: application/json" \
  -d '{"channel_id":"C9876543210","blocks":[{"type":"divider"}]}')
DEFAULT_OK=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',''))" 2>/dev/null || echo "")
[ "$DEFAULT_OK" = "True" ] && pass "Send blocks with default text returns ok=true" || fail "Send blocks default text failed (got: $RESULT)"

# ----------------------------------------------------------------
# Thread Reply
# ----------------------------------------------------------------

# Test 9: Send thread reply
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/slack/thread" \
  -H "Content-Type: application/json" \
  -d '{"channel_id":"C1234567890","thread_ts":"1700000001.000001","content":"This is a reply"}')
REPLY_OK=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',''))" 2>/dev/null || echo "")
[ "$REPLY_OK" = "True" ] && pass "Thread reply returns ok=true" || fail "Thread reply ok mismatch (got: $RESULT)"

REPLY_TS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ts',''))" 2>/dev/null || echo "")
[ -n "$REPLY_TS" ] && pass "Thread reply returns timestamp" || fail "Thread reply missing timestamp (got: $RESULT)"

THREAD_TS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('thread_ts',''))" 2>/dev/null || echo "")
[ "$THREAD_TS" = "1700000001.000001" ] && pass "Thread reply preserves thread_ts" || fail "Thread reply thread_ts mismatch (got: $THREAD_TS)"

# ----------------------------------------------------------------
# Set Topic
# ----------------------------------------------------------------

# Test 12: Set channel topic
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/slack/topic" \
  -H "Content-Type: application/json" \
  -d '{"channel_id":"C1234567890","topic":"Sprint 42 — on track"}')
TOPIC_OK=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',''))" 2>/dev/null || echo "")
[ "$TOPIC_OK" = "True" ] && pass "Set topic returns ok=true" || fail "Set topic ok mismatch (got: $RESULT)"

TOPIC_VAL=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); ch=d.get('channel',{}); t=ch.get('topic',{}); print(t.get('value',''))" 2>/dev/null || echo "")
[ "$TOPIC_VAL" = "Sprint 42 — on track" ] && pass "Set topic returns updated topic value" || fail "Set topic value mismatch (got: $TOPIC_VAL)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
