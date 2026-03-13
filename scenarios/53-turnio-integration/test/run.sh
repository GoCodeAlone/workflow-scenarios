#!/usr/bin/env bash
# Scenario 53: turn.io Integration
# Tests turn.io plugin steps against a mock turn.io API server.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:18053}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 53: turn.io Integration ==="
echo ""

# Test 1: Health check
RESULT=$(curl -s "$BASE_URL/healthz")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$STATUS" = "ok" ] && pass "Health check returns ok" || fail "Health check failed (got: $STATUS)"

SCENARIO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('scenario',''))" 2>/dev/null || echo "")
[ "$SCENARIO" = "53-turnio-integration" ] && pass "Health check identifies scenario 53" || fail "Health check missing scenario identifier (got: $SCENARIO)"

# Test 2: Send text message
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/turnio/send" \
  -H "Content-Type: application/json" \
  -d '{"to":"+1234567890","body":"Hello from scenario 53"}')
MSG_ID=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
# response key contains JSON string of the turn.io response
resp=d.get('response','')
if resp:
    inner=json.loads(resp)
    msgs=inner.get('messages',[])
    print(msgs[0]['id'] if msgs else '')
else:
    print('')
" 2>/dev/null || echo "")
[ -n "$MSG_ID" ] && [ "$MSG_ID" != "null" ] && pass "Send text returns message id" || fail "Send text missing message id (got: $RESULT)"

HAS_WAMID=$(echo "$MSG_ID" | python3 -c "import sys; v=sys.stdin.read().strip(); print('yes' if v.startswith('wamid.') else 'no')" 2>/dev/null || echo "no")
[ "$HAS_WAMID" = "yes" ] && pass "Send text message id has wamid format" || fail "Send text message id not wamid format (got: $MSG_ID)"

# Test 3: Send template message
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/turnio/template" \
  -H "Content-Type: application/json" \
  -d '{"to":"+1234567890","template_name":"hello_world","language_code":"en"}')
TMPL_MSG_ID=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
resp=d.get('response','')
if resp:
    inner=json.loads(resp)
    msgs=inner.get('messages',[])
    print(msgs[0]['id'] if msgs else '')
else:
    print('')
" 2>/dev/null || echo "")
[ -n "$TMPL_MSG_ID" ] && [ "$TMPL_MSG_ID" != "null" ] && pass "Send template returns message id" || fail "Send template missing message id (got: $RESULT)"

TMPL_TO=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('to',''))" 2>/dev/null || echo "")
[ "$TMPL_TO" = "+1234567890" ] && pass "Send template echoes to field" || fail "Send template to field mismatch (got: $TMPL_TO)"

# Test 4: Check contact
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/turnio/contacts" \
  -H "Content-Type: application/json" \
  -d '{"phone":"+1234567890"}')
CONTACT_STATUS=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
contacts_raw=d.get('contacts','')
if contacts_raw:
    contacts=json.loads(contacts_raw)
    ct=contacts.get('contacts',[])
    print(ct[0]['status'] if ct else '')
else:
    print('')
" 2>/dev/null || echo "")
[ "$CONTACT_STATUS" = "valid" ] && pass "Check contact returns status valid" || fail "Check contact status mismatch (got: $CONTACT_STATUS, full: $RESULT)"

CONTACT_WA=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
contacts_raw=d.get('contacts','')
if contacts_raw:
    contacts=json.loads(contacts_raw)
    ct=contacts.get('contacts',[])
    print(ct[0].get('wa_id','') if ct else '')
else:
    print('')
" 2>/dev/null || echo "")
[ -n "$CONTACT_WA" ] && pass "Check contact returns wa_id" || fail "Check contact missing wa_id (got: $RESULT)"

# Test 5: List templates
RESULT=$(curl -s "$BASE_URL/api/v1/turnio/templates")
TEMPLATE_COUNT=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
templates_raw=d.get('templates','')
if templates_raw:
    templates=json.loads(templates_raw)
    tlist=templates.get('waba_templates',[])
    print(len(tlist))
else:
    print(0)
" 2>/dev/null || echo "0")
[ "$TEMPLATE_COUNT" -gt 0 ] && pass "List templates returns non-empty array" || fail "List templates returned empty or error (got: $RESULT)"

# Test 6: Create template
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/turnio/templates" \
  -H "Content-Type: application/json" \
  -d '{"template_name":"scenario53_tmpl","category":"UTILITY","language_code":"en"}')
TMPL_ID=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
tmpl_raw=d.get('template','')
if tmpl_raw:
    tmpl=json.loads(tmpl_raw)
    print(tmpl.get('id',''))
else:
    print('')
" 2>/dev/null || echo "")
[ -n "$TMPL_ID" ] && [ "$TMPL_ID" != "null" ] && pass "Create template returns id" || fail "Create template missing id (got: $RESULT)"

TMPL_NAME=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
tmpl_raw=d.get('template','')
if tmpl_raw:
    tmpl=json.loads(tmpl_raw)
    print(tmpl.get('name',''))
else:
    print('')
" 2>/dev/null || echo "")
[ -n "$TMPL_NAME" ] && pass "Create template returns name" || fail "Create template missing name (got: $RESULT)"

# Test 7: Create flow
RESULT=$(curl -s -X POST "$BASE_URL/api/v1/turnio/flows" \
  -H "Content-Type: application/json" \
  -d '{"flow_name":"onboarding-flow","description":"New user onboarding"}')
FLOW_ID=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
flow_raw=d.get('flow','')
if flow_raw:
    flow=json.loads(flow_raw)
    print(flow.get('id',''))
else:
    print('')
" 2>/dev/null || echo "")
[ -n "$FLOW_ID" ] && [ "$FLOW_ID" != "null" ] && pass "Create flow returns id" || fail "Create flow missing id (got: $RESULT)"

FLOW_NAME=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
flow_raw=d.get('flow','')
if flow_raw:
    flow=json.loads(flow_raw)
    print(flow.get('name',''))
else:
    print('')
" 2>/dev/null || echo "")
[ -n "$FLOW_NAME" ] && pass "Create flow returns name" || fail "Create flow missing name (got: $RESULT)"

FLOW_STATUS=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
flow_raw=d.get('flow','')
if flow_raw:
    flow=json.loads(flow_raw)
    print(flow.get('status',''))
else:
    print('')
" 2>/dev/null || echo "")
[ -n "$FLOW_STATUS" ] && pass "Create flow returns status" || fail "Create flow missing status (got: $RESULT)"

# Test 8: List flows
RESULT=$(curl -s "$BASE_URL/api/v1/turnio/flows")
FLOW_COUNT=$(echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
flows_raw=d.get('flows','')
if flows_raw:
    flows=json.loads(flows_raw)
    flist=flows.get('flows',[])
    print(len(flist))
else:
    print(0)
" 2>/dev/null || echo "0")
[ "$FLOW_COUNT" -gt 0 ] && pass "List flows returns non-empty array" || fail "List flows returned empty or error (got: $RESULT)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
