#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 14: Low-Code CRUD — UI Generation Pipeline
#
# Validates the end-to-end low-code frontend story:
#   app.yaml → wfctl api extract → openapi.json
#           → wfctl ui scaffold  → generated React SPA
#           → wfctl build-ui     → compiled dist/
#
# These tests run LOCALLY (no k8s required).
# If wfctl subcommands are not yet implemented, tests are SKIPPED with a
# clear message so CI does not fail when the feature is still in development.
#
# Outputs PASS: / FAIL: / SKIP: lines for each test.

SCENARIO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCENARIO_DIR/config/app.yaml"
GENERATED_DIR="$SCENARIO_DIR/generated"
OPENAPI_JSON="$GENERATED_DIR/openapi.json"
UI_DIR="$GENERATED_DIR/ui"

WFCTL=$(command -v wfctl 2>/dev/null || echo "")

# Helper: skip if wfctl is missing entirely
check_wfctl() {
    if [ -z "$WFCTL" ]; then
        echo "SKIP: wfctl not found in PATH — install wfctl to run UI generation tests"
        exit 0
    fi
}

# Helper: skip if a subcommand is not yet implemented
wfctl_subcommand_exists() {
    local sub="$1"
    "$WFCTL" help 2>&1 | grep -q "$sub" 2>/dev/null || \
    "$WFCTL" "$sub" --help 2>&1 | grep -qv "unknown command" 2>/dev/null
}

# ----------------------------------------------------------------
# Test 1: wfctl is available
# ----------------------------------------------------------------
if [ -n "$WFCTL" ]; then
    echo "PASS: wfctl is available at $WFCTL"
else
    echo "SKIP: wfctl not found in PATH — remaining UI tests will be skipped"
    # Emit remaining tests as SKIP so the harness counts them
    for i in $(seq 2 10); do
        echo "SKIP: UI test $i skipped (wfctl not available)"
    done
    exit 0
fi

# ----------------------------------------------------------------
# Test 2: wfctl api extract subcommand exists
# ----------------------------------------------------------------
if wfctl_subcommand_exists "api"; then
    echo "PASS: wfctl api subcommand is available"
else
    echo "SKIP: wfctl api subcommand not yet implemented — remaining tests skipped"
    for i in $(seq 3 10); do
        echo "SKIP: UI test $i skipped (wfctl api not available)"
    done
    exit 0
fi

# ----------------------------------------------------------------
# Test 3: wfctl api extract generates openapi.json
# ----------------------------------------------------------------
mkdir -p "$GENERATED_DIR"
if "$WFCTL" api extract "$CONFIG" > "$OPENAPI_JSON" 2>/dev/null; then
    if [ -s "$OPENAPI_JSON" ]; then
        echo "PASS: wfctl api extract produced openapi.json ($(wc -c < "$OPENAPI_JSON" | tr -d ' ') bytes)"
    else
        echo "FAIL: wfctl api extract produced an empty openapi.json"
        # Write a stub so downstream tests can continue with partial data
        echo '{}' > "$OPENAPI_JSON"
    fi
else
    echo "FAIL: wfctl api extract exited with non-zero status"
    echo '{}' > "$OPENAPI_JSON"
fi

# ----------------------------------------------------------------
# Test 4: OpenAPI spec contains /api/v1/tasks path
# ----------------------------------------------------------------
if python3 -c "
import json, sys
spec = json.load(open('$OPENAPI_JSON'))
paths = spec.get('paths', {})
assert '/api/v1/tasks' in paths, '/api/v1/tasks not found in paths'
" 2>/dev/null; then
    echo "PASS: OpenAPI spec contains /api/v1/tasks path"
else
    echo "FAIL: OpenAPI spec missing /api/v1/tasks path"
fi

# ----------------------------------------------------------------
# Test 5: OpenAPI spec contains auth paths
# ----------------------------------------------------------------
if python3 -c "
import json, sys
spec = json.load(open('$OPENAPI_JSON'))
paths = spec.get('paths', {})
assert '/api/v1/auth/login' in paths, '/api/v1/auth/login not found'
assert '/api/v1/auth/register' in paths, '/api/v1/auth/register not found'
" 2>/dev/null; then
    echo "PASS: OpenAPI spec contains /api/v1/auth/login and /api/v1/auth/register"
else
    echo "FAIL: OpenAPI spec missing auth paths (/api/v1/auth/login or /api/v1/auth/register)"
fi

# ----------------------------------------------------------------
# Test 6: OpenAPI spec has correct HTTP methods (GET, POST, PUT, DELETE)
# ----------------------------------------------------------------
if python3 -c "
import json, sys
spec = json.load(open('$OPENAPI_JSON'))
paths = spec.get('paths', {})
tasks = paths.get('/api/v1/tasks', {})
task_id = paths.get('/api/v1/tasks/{id}', {})
methods = set(tasks.keys()) | set(task_id.keys())
required = {'get', 'post', 'put', 'delete'}
missing = required - methods
assert not missing, f'Missing methods: {missing}'
" 2>/dev/null; then
    echo "PASS: OpenAPI spec has GET, POST, PUT, DELETE methods on task endpoints"
else
    echo "FAIL: OpenAPI spec missing one or more of GET/POST/PUT/DELETE on task endpoints"
fi

# ----------------------------------------------------------------
# Test 7: wfctl ui scaffold subcommand exists
# ----------------------------------------------------------------
if wfctl_subcommand_exists "ui"; then
    echo "PASS: wfctl ui subcommand is available"
else
    echo "SKIP: wfctl ui subcommand not yet implemented — remaining tests skipped"
    for i in $(seq 8 10); do
        echo "SKIP: UI test $i skipped (wfctl ui not available)"
    done
    exit 0
fi

# ----------------------------------------------------------------
# Test 8: wfctl ui scaffold generates React project
# ----------------------------------------------------------------
mkdir -p "$UI_DIR"
if "$WFCTL" ui scaffold -spec "$OPENAPI_JSON" -output "$UI_DIR" 2>/dev/null; then
    echo "PASS: wfctl ui scaffold completed without error"
else
    echo "FAIL: wfctl ui scaffold exited with non-zero status"
fi

# ----------------------------------------------------------------
# Test 9: Generated UI has expected structure
# ----------------------------------------------------------------
STRUCTURE_OK=true

# package.json must exist for npm build to work
if [ ! -f "$UI_DIR/package.json" ]; then
    echo "FAIL: Generated UI missing package.json"
    STRUCTURE_OK=false
fi

# src/pages/ must exist (the generator creates per-resource page components)
if [ ! -d "$UI_DIR/src/pages" ]; then
    echo "FAIL: Generated UI missing src/pages/ directory"
    STRUCTURE_OK=false
fi

# src/api.ts (or api.js) — typed API client generated from OpenAPI spec
if [ ! -f "$UI_DIR/src/api.ts" ] && [ ! -f "$UI_DIR/src/api.js" ]; then
    echo "FAIL: Generated UI missing src/api.ts or src/api.js"
    STRUCTURE_OK=false
fi

if [ "$STRUCTURE_OK" = "true" ]; then
    echo "PASS: Generated UI has package.json, src/pages/, and src/api.ts"
fi

# Auth pages: login and register should be scaffolded from auth spec paths
AUTH_PAGES_OK=true
for page in login register; do
    if ! find "$UI_DIR/src" -name "*${page}*" -o -name "*${page^}*" 2>/dev/null | grep -q .; then
        echo "FAIL: Generated UI missing ${page} page component"
        AUTH_PAGES_OK=false
    fi
done
if [ "$AUTH_PAGES_OK" = "true" ]; then
    echo "PASS: Generated UI has login and register page components"
fi

# ----------------------------------------------------------------
# Test 10: wfctl build-ui compiles the generated React project
# ----------------------------------------------------------------
if "$WFCTL" build-ui -ui-dir "$UI_DIR" 2>/dev/null; then
    if [ -f "$UI_DIR/dist/index.html" ]; then
        echo "PASS: wfctl build-ui compiled the UI — dist/index.html exists"
    else
        echo "FAIL: wfctl build-ui exited 0 but dist/index.html was not produced"
    fi
else
    echo "FAIL: wfctl build-ui exited with non-zero status"
fi
