#!/usr/bin/env bash
set -euo pipefail

NS="wf-scenario-26"
BASE="http://localhost:18026"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Port-forward
kubectl port-forward -n "$NS" svc/workflow-server 18026:8080 &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

echo ""
echo "=== Scenario 26: Config-to-Binary (step.build_binary dry-run) ==="
echo ""

# Test 1: Health check
RESP=$(curl -sf "$BASE/healthz" 2>/dev/null || echo "")
if echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('status')=='ok'" 2>/dev/null; then
    pass "Health check returns {status: ok}"
else
    fail "Health check failed: $RESP"
fi

# Test 2: POST to build endpoint returns 200
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/v1/build/binary" \
    -H "Content-Type: application/json" \
    -d '{}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "POST /api/v1/build/binary returns 200"
else
    fail "POST /api/v1/build/binary returned $HTTP_CODE (expected 200)"
fi

# Capture full build response for subsequent assertions
BUILD_RESP=$(curl -sf -X POST "$BASE/api/v1/build/binary" \
    -H "Content-Type: application/json" \
    -d '{}' 2>/dev/null || echo "")

# Test 3: Response contains dry_run flag
if echo "$BUILD_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('dry_run') is True" 2>/dev/null; then
    pass "Response contains dry_run=true"
else
    fail "Response missing dry_run=true: $BUILD_RESP"
fi

# Test 4: Response contains files list
if echo "$BUILD_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('files'), list)" 2>/dev/null; then
    pass "Response contains files list"
else
    fail "Response missing files list: $BUILD_RESP"
fi

# Test 5: files list contains go.mod
if echo "$BUILD_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'go.mod' in d.get('files', [])" 2>/dev/null; then
    pass "files list contains go.mod"
else
    fail "files list missing go.mod: $BUILD_RESP"
fi

# Test 6: files list contains main.go
if echo "$BUILD_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'main.go' in d.get('files', [])" 2>/dev/null; then
    pass "files list contains main.go"
else
    fail "files list missing main.go: $BUILD_RESP"
fi

# Test 7: files list contains app.yaml
if echo "$BUILD_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'app.yaml' in d.get('files', [])" 2>/dev/null; then
    pass "files list contains app.yaml"
else
    fail "files list missing app.yaml: $BUILD_RESP"
fi

# Test 8: main.go contains go:embed directive
if echo "$BUILD_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
contents = d.get('file_contents', {})
main_go = contents.get('main.go', '')
assert '//go:embed app.yaml' in main_go, f'embed directive missing from main.go: {main_go!r}'
" 2>/dev/null; then
    pass "main.go contains //go:embed app.yaml directive"
else
    fail "main.go missing //go:embed directive: $BUILD_RESP"
fi

# Test 9: go.mod contains correct module path
if echo "$BUILD_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
contents = d.get('file_contents', {})
go_mod = contents.get('go.mod', '')
assert 'module generated-app' in go_mod, f'module path missing from go.mod: {go_mod!r}'
" 2>/dev/null; then
    pass "go.mod contains correct module path (generated-app)"
else
    fail "go.mod missing correct module path: $BUILD_RESP"
fi

# Test 10: go.mod contains go version
if echo "$BUILD_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
contents = d.get('file_contents', {})
go_mod = contents.get('go.mod', '')
assert 'go 1.22' in go_mod, f'go version missing from go.mod: {go_mod!r}'
" 2>/dev/null; then
    pass "go.mod contains go version (1.22)"
else
    fail "go.mod missing go version: $BUILD_RESP"
fi

# Test 11: go.mod references workflow dependency
if echo "$BUILD_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
contents = d.get('file_contents', {})
go_mod = contents.get('go.mod', '')
assert 'github.com/GoCodeAlone/workflow' in go_mod, f'workflow dep missing from go.mod: {go_mod!r}'
" 2>/dev/null; then
    pass "go.mod references github.com/GoCodeAlone/workflow dependency"
else
    fail "go.mod missing workflow dependency: $BUILD_RESP"
fi

# Test 12: app.yaml content is non-empty
if echo "$BUILD_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
contents = d.get('file_contents', {})
app_yaml = contents.get('app.yaml', '')
assert len(app_yaml) > 10, f'app.yaml too short: {app_yaml!r}'
" 2>/dev/null; then
    pass "app.yaml content is non-empty (config embedded correctly)"
else
    fail "app.yaml content missing or too short: $BUILD_RESP"
fi

# Test 13: main.go contains embed import
if echo "$BUILD_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
contents = d.get('file_contents', {})
main_go = contents.get('main.go', '')
assert '_ \"embed\"' in main_go, f'embed import missing from main.go'
" 2>/dev/null; then
    pass "main.go contains embed import"
else
    fail "main.go missing embed import: $BUILD_RESP"
fi

# Test 14: response contains target_os and target_arch
if echo "$BUILD_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('target_os') == 'linux', f'expected target_os=linux, got {d.get(\"target_os\")}'
assert d.get('target_arch') == 'amd64', f'expected target_arch=amd64, got {d.get(\"target_arch\")}'
" 2>/dev/null; then
    pass "Response contains target_os=linux and target_arch=amd64"
else
    fail "Response missing target_os/target_arch: $BUILD_RESP"
fi

# Test 15: main.go is valid Go (package main declaration)
if echo "$BUILD_RESP" | python3 -c "
import json, sys
d = json.load(sys.stdin)
contents = d.get('file_contents', {})
main_go = contents.get('main.go', '')
assert 'package main' in main_go, 'main.go missing package main'
assert 'func main()' in main_go, 'main.go missing func main()'
" 2>/dev/null; then
    pass "main.go has valid package main and func main() declarations"
else
    fail "main.go missing expected Go declarations: $BUILD_RESP"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $( [ "$FAIL" -eq 0 ] && echo 0 || echo 1 )
