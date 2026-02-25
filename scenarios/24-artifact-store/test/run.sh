#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 24: Artifact Store
# Tests upload, download, list, delete, and edge cases.
# Outputs PASS: or FAIL: lines for each test.

NS="${NAMESPACE:-wf-scenario-24}"
PORT=18024
BASE="http://localhost:$PORT"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

start_pf() {
    pkill -f "port-forward.*$PORT" 2>/dev/null || true
    sleep 1
    kubectl port-forward svc/workflow-server "$PORT":8080 -n "$NS" &
    PF_PID=$!
    sleep 4
}

cleanup() {
    pkill -f "port-forward.*$PORT" 2>/dev/null || true
}
trap cleanup EXIT

start_pf

UNIQUE="test-$(date +%s)"

# ====================================================================
# Test 1: Health check
# ====================================================================
RESP=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "ERROR")
if echo "$RESP" | grep -q '"ok"'; then
    pass "Health check returns ok"
else
    fail "Health check failed: $RESP"
fi

# ====================================================================
# Test 2: Health check identifies scenario
# ====================================================================
if echo "$RESP" | grep -q "24-artifact-store"; then
    pass "Health check identifies scenario 24-artifact-store"
else
    fail "Health check missing scenario identifier: $RESP"
fi

# ====================================================================
# Test 3: Upload artifact — status 201
# ====================================================================
CONTENT=$(echo "hello artifact $UNIQUE" | base64)
UPLOAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$BASE/api/v1/artifacts/upload" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"builds/$UNIQUE/app.bin\",\"content\":\"$CONTENT\",\"metadata\":{\"version\":\"1.0\",\"commit\":\"$UNIQUE\"}}" \
    2>/dev/null || echo "000")
if [ "$UPLOAD_CODE" = "201" ]; then
    pass "Upload artifact returns 201"
else
    fail "Upload returned $UPLOAD_CODE (expected 201)"
fi

# ====================================================================
# Test 4: Upload response body contains key
# ====================================================================
UPLOAD_BODY=$(curl -sf \
    -X POST "$BASE/api/v1/artifacts/upload" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"builds/$UNIQUE/app2.bin\",\"content\":\"$CONTENT\"}" \
    2>/dev/null || echo "{}")
if echo "$UPLOAD_BODY" | grep -q "uploaded"; then
    pass "Upload response body contains 'uploaded' status"
else
    fail "Upload response body missing status: $UPLOAD_BODY"
fi

# ====================================================================
# Test 5: Download artifact — exists=true
# ====================================================================
DOWNLOAD_BODY=$(curl -sf \
    "$BASE/api/v1/artifacts/get?key=builds/$UNIQUE/app.bin" \
    2>/dev/null || echo "{}")
if echo "$DOWNLOAD_BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('exists') == True or str(d.get('exists')).lower() == 'true' else 1)" 2>/dev/null; then
    pass "Download returns exists=true for uploaded artifact"
else
    fail "Download exists check failed: $DOWNLOAD_BODY"
fi

# ====================================================================
# Test 6: Download content matches uploaded content
# ====================================================================
DOWNLOADED_B64=$(echo "$DOWNLOAD_BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('content',''))" 2>/dev/null || echo "")
if [ -n "$DOWNLOADED_B64" ]; then
    DECODED=$(echo "$DOWNLOADED_B64" | base64 -d 2>/dev/null || echo "")
    ORIGINAL="hello artifact $UNIQUE"
    if echo "$DECODED" | grep -q "$UNIQUE"; then
        pass "Downloaded content matches uploaded content"
    else
        fail "Content mismatch: decoded='$DECODED', expected to contain '$UNIQUE'"
    fi
else
    fail "Download response missing content field: $DOWNLOAD_BODY"
fi

# ====================================================================
# Test 7: Download nonexistent artifact — exists=false
# ====================================================================
MISS_BODY=$(curl -sf \
    "$BASE/api/v1/artifacts/get?key=nonexistent/ghost.bin" \
    2>/dev/null || echo "{}")
if echo "$MISS_BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('exists') == False or str(d.get('exists')).lower() == 'false' else 1)" 2>/dev/null; then
    pass "Download nonexistent artifact returns exists=false"
else
    fail "Expected exists=false for ghost artifact: $MISS_BODY"
fi

# ====================================================================
# Test 8: Upload second artifact in same prefix
# ====================================================================
CONTENT2=$(echo "second artifact" | base64)
CODE2=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$BASE/api/v1/artifacts/upload" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"builds/$UNIQUE/lib.so\",\"content\":\"$CONTENT2\"}" \
    2>/dev/null || echo "000")
if [ "$CODE2" = "201" ]; then
    pass "Upload second artifact in same prefix returns 201"
else
    fail "Second upload returned $CODE2 (expected 201)"
fi

# ====================================================================
# Test 9: List artifacts — returns uploaded artifacts
# ====================================================================
LIST_BODY=$(curl -sf \
    "$BASE/api/v1/artifacts?prefix=builds/$UNIQUE/" \
    2>/dev/null || echo "{}")
COUNT=$(echo "$LIST_BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")
if [ "$COUNT" -ge "2" ] 2>/dev/null; then
    pass "List returns at least 2 artifacts for prefix builds/$UNIQUE/"
else
    fail "List count=$COUNT (expected >=2): $LIST_BODY"
fi

# ====================================================================
# Test 10: List with no prefix returns all artifacts
# ====================================================================
LIST_ALL=$(curl -sf "$BASE/api/v1/artifacts" 2>/dev/null || echo "{}")
ALL_COUNT=$(echo "$LIST_ALL" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")
if [ "$ALL_COUNT" -ge "2" ] 2>/dev/null; then
    pass "List all (no prefix) returns >= 2 artifacts"
else
    fail "List all count=$ALL_COUNT (expected >=2)"
fi

# ====================================================================
# Test 11: Upload artifact for delete test
# ====================================================================
DEL_CONTENT=$(echo "to be deleted" | base64)
DEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$BASE/api/v1/artifacts/upload" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"temp/$UNIQUE/delete-me.txt\",\"content\":\"$DEL_CONTENT\"}" \
    2>/dev/null || echo "000")
if [ "$DEL_CODE" = "201" ]; then
    pass "Upload artifact for delete test returns 201"
else
    fail "Upload for delete returned $DEL_CODE"
fi

# ====================================================================
# Test 12: Delete artifact — returns 200
# ====================================================================
DELETE_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X DELETE "$BASE/api/v1/artifacts/delete?key=temp/$UNIQUE/delete-me.txt" \
    2>/dev/null || echo "000")
if [ "$DELETE_CODE" = "200" ]; then
    pass "Delete artifact returns 200"
else
    fail "Delete returned $DELETE_CODE (expected 200)"
fi

# ====================================================================
# Test 13: Delete response body contains 'deleted' status
# ====================================================================
DELETE_BODY=$(curl -sf \
    -X DELETE "$BASE/api/v1/artifacts/delete?key=builds/$UNIQUE/lib.so" \
    2>/dev/null || echo "{}")
if echo "$DELETE_BODY" | grep -q "deleted"; then
    pass "Delete response body contains 'deleted' status"
else
    fail "Delete response body missing status: $DELETE_BODY"
fi

# ====================================================================
# Test 14: After delete — artifact no longer in list
# ====================================================================
LIST_AFTER=$(curl -sf \
    "$BASE/api/v1/artifacts?prefix=temp/$UNIQUE/" \
    2>/dev/null || echo "{}")
COUNT_AFTER=$(echo "$LIST_AFTER" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")
if [ "$COUNT_AFTER" -eq "0" ] 2>/dev/null; then
    pass "After delete — temp/$UNIQUE/ prefix shows 0 artifacts"
else
    fail "After delete count=$COUNT_AFTER (expected 0): $LIST_AFTER"
fi

# ====================================================================
# Test 15: List with mismatched prefix returns empty
# ====================================================================
LIST_EMPTY=$(curl -sf \
    "$BASE/api/v1/artifacts?prefix=zzz-no-such-prefix-$UNIQUE/" \
    2>/dev/null || echo "{}")
EMPTY_COUNT=$(echo "$LIST_EMPTY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")
if [ "$EMPTY_COUNT" -eq "0" ] 2>/dev/null; then
    pass "List with nonexistent prefix returns count=0"
else
    fail "Expected count=0 for nonexistent prefix, got $EMPTY_COUNT"
fi

# ====================================================================
# Summary
# ====================================================================
echo ""
echo "========================================"
echo "RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "========================================"
if [ "$FAIL_COUNT" -gt "0" ]; then
    exit 1
fi
