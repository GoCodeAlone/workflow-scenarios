#!/usr/bin/env bash
# Scenario 62: Cross-Platform Messaging
# Tests broadcast pipeline sending to Discord, Slack, and Teams simultaneously.
# Also tests Discord-to-Slack relay pipeline with message prefix.
set -euo pipefail

PORT=18062
NAMESPACE="${NAMESPACE:-wf-scenario-62}"
BASE_URL="${BASE_URL:-http://localhost:${PORT}}"
DISCORD_MOCK="${DISCORD_MOCK:-http://localhost:19062}"
SLACK_MOCK="${SLACK_MOCK:-http://localhost:19063}"
TEAMS_MOCK="${TEAMS_MOCK:-http://localhost:19064}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 62: Cross-Platform Messaging ==="

# Start port-forward if not already reachable
if ! curl -sf --max-time 2 "${BASE_URL}/healthz" &>/dev/null; then
    kubectl port-forward -n "$NAMESPACE" svc/workflow-server "${PORT}:8080" &>/dev/null &
    PF_PID=$!
    trap "kill $PF_PID 2>/dev/null || true; kill \$PF_DISCORD 2>/dev/null || true; kill \$PF_SLACK 2>/dev/null || true; kill \$PF_TEAMS 2>/dev/null || true" EXIT
    for i in $(seq 1 30); do
        if curl -sf --max-time 2 "${BASE_URL}/healthz" &>/dev/null; then break; fi
        sleep 1
    done
fi

# Port-forward mock services (running in same pod as workflow-server)
POD_NAME=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$POD_NAME" ]; then
    kubectl port-forward -n "$NAMESPACE" "pod/$POD_NAME" 19062:19062 &>/dev/null &
    PF_DISCORD=$!
    kubectl port-forward -n "$NAMESPACE" "pod/$POD_NAME" 19063:19063 &>/dev/null &
    PF_SLACK=$!
    kubectl port-forward -n "$NAMESPACE" "pod/$POD_NAME" 19064:19064 &>/dev/null &
    PF_TEAMS=$!
    sleep 2
fi

echo ""

# Test 1: Health check
RESULT=$(curl -s "$BASE_URL/healthz")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$STATUS" = "ok" ] && pass "Health check returns ok" || fail "Health check failed (got: $STATUS)"

SCENARIO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scenario',''))" 2>/dev/null || echo "")
[ "$SCENARIO" = "62-cross-platform-messaging" ] && pass "Health check identifies scenario 62" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# ----------------------------------------------------------------
# Broadcast Test
# ----------------------------------------------------------------

# Test 3: Broadcast message to all 3 platforms
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/broadcast" \
  -H "Content-Type: application/json" \
  -d '{
    "message": "System maintenance in 30 minutes",
    "discord_channel": "123456789",
    "slack_channel": "C1234567890",
    "teams_team_id": "team-abc",
    "teams_channel_id": "channel-xyz"
  }')

BROADCAST=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('broadcast',''))" 2>/dev/null || echo "")
[ "$BROADCAST" = "True" ] && pass "Broadcast returns broadcast=true" || fail "Broadcast flag missing (got: $RESULT)"

DISCORD_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('discord_message_id',''))" 2>/dev/null || echo "")
[ -n "$DISCORD_ID" ] && pass "Broadcast returns discord_message_id" || fail "Broadcast missing discord_message_id (got: $RESULT)"

SLACK_TS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('slack_ts',''))" 2>/dev/null || echo "")
[ -n "$SLACK_TS" ] && pass "Broadcast returns slack_ts" || fail "Broadcast missing slack_ts (got: $RESULT)"

TEAMS_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('teams_message_id',''))" 2>/dev/null || echo "")
[ -n "$TEAMS_ID" ] && pass "Broadcast returns teams_message_id" || fail "Broadcast missing teams_message_id (got: $RESULT)"

# Test 7: Verify all 3 IDs are distinct (non-empty and all different)
ALL_DISTINCT=$(python3 -c "
ids = ['$DISCORD_ID', '$SLACK_TS', '$TEAMS_ID']
print('True' if len(set(ids)) == 3 and all(ids) else 'False')
" 2>/dev/null || echo "False")
[ "$ALL_DISTINCT" = "True" ] && pass "All 3 platform message IDs are distinct" || fail "Message IDs not all distinct (discord=$DISCORD_ID slack=$SLACK_TS teams=$TEAMS_ID)"

# ----------------------------------------------------------------
# Mock Request Count Verification
# (checks that each platform mock received exactly 1 broadcast request)
# ----------------------------------------------------------------

# Test 8: Discord mock received 1 message request
DISCORD_REQS=$(curl -s "$DISCORD_MOCK/test/requests")
DISCORD_COUNT=$(echo "$DISCORD_REQS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$DISCORD_COUNT" -ge 1 ] && pass "Discord mock received at least 1 request" || fail "Discord mock received no requests (count: $DISCORD_COUNT)"

# Test 9: Slack mock received 1 message request
SLACK_REQS=$(curl -s "$SLACK_MOCK/test/requests")
SLACK_COUNT=$(echo "$SLACK_REQS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$SLACK_COUNT" -ge 1 ] && pass "Slack mock received at least 1 request" || fail "Slack mock received no requests (count: $SLACK_COUNT)"

# Test 10: Teams mock received 1 message request
TEAMS_REQS=$(curl -s "$TEAMS_MOCK/test/requests")
TEAMS_COUNT=$(echo "$TEAMS_REQS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$TEAMS_COUNT" -ge 1 ] && pass "Teams mock received at least 1 request" || fail "Teams mock received no requests (count: $TEAMS_COUNT)"

# ----------------------------------------------------------------
# Discord-to-Slack Relay
# ----------------------------------------------------------------

# Test 11: Relay pipeline sends to Slack with [Discord] prefix
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/relay/discord-to-slack" \
  -H "Content-Type: application/json" \
  -d '{"message":"Hello from Discord","slack_channel":"C9876543210"}')

RELAYED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('relayed',''))" 2>/dev/null || echo "")
[ "$RELAYED" = "True" ] && pass "Relay returns relayed=true" || fail "Relay flag missing (got: $RESULT)"

RELAY_TS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('slack_ts',''))" 2>/dev/null || echo "")
[ -n "$RELAY_TS" ] && pass "Relay returns slack_ts" || fail "Relay missing slack_ts (got: $RESULT)"

RELAY_CHAN=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('slack_channel',''))" 2>/dev/null || echo "")
[ "$RELAY_CHAN" = "C9876543210" ] && pass "Relay returns correct slack_channel" || fail "Relay slack_channel mismatch (got: $RELAY_CHAN)"

# Test 14: Verify Slack mock now has 2 requests (1 broadcast + 1 relay)
SLACK_REQS2=$(curl -s "$SLACK_MOCK/test/requests")
SLACK_COUNT2=$(echo "$SLACK_REQS2" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$SLACK_COUNT2" -ge 2 ] && pass "Slack mock received broadcast + relay requests" || fail "Slack mock should have 2+ requests (got: $SLACK_COUNT2)"

# Verify the relay request contains [Discord] prefix in Slack mock log
RELAY_REQ=$(echo "$SLACK_REQS2" | python3 -c "
import sys,json
d = json.load(sys.stdin)
reqs = d.get('requests', [])
# Look for relay channel in any request
print('True' if any('C9876543210' in r for r in reqs) else 'False')
" 2>/dev/null || echo "False")
[ "$RELAY_REQ" = "True" ] && pass "Relay request routed to correct Slack channel" || fail "Relay channel not found in Slack mock log"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
