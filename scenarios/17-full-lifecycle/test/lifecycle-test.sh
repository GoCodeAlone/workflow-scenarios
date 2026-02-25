#!/usr/bin/env bash
set -euo pipefail

# Lifecycle test for Scenario 17: Full Developer Workflow
#
# Tests the complete local developer pipeline:
#   config → wfctl api extract → OpenAPI spec
#   → wfctl ui scaffold → React project
#   → wfctl build-ui → dist/
#   → wfctl diff → config comparison
#
# Gracefully SKIPs each test if the required wfctl subcommand is absent.
# Does NOT require a running k8s cluster.
#
# Outputs PASS: / FAIL: / SKIP: lines for each test.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$SCENARIO_DIR/config"
GEN_DIR="$SCENARIO_DIR/generated"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { echo "SKIP: $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

# Detect wfctl
WFCTL=$(command -v wfctl 2>/dev/null || echo "")

if [ -z "$WFCTL" ]; then
    echo "INFO: wfctl not found in PATH — all lifecycle tests will be SKIP"
fi

# Check if a wfctl subcommand is available
wfctl_has() {
    local subcmd="$1"
    if [ -z "$WFCTL" ]; then
        return 1
    fi
    "$WFCTL" help 2>&1 | grep -q "$subcmd" || \
    "$WFCTL" "$subcmd" --help 2>&1 | grep -qv "unknown command" 2>/dev/null || \
    "$WFCTL" "$subcmd" 2>&1 | grep -qv "unknown command" 2>/dev/null
    return $?
}

mkdir -p "$GEN_DIR"

echo ""
echo "========================================"
echo "LIFECYCLE TESTS: Config → API → UI → Deploy → Evolve"
echo "========================================"
echo "Config dir:    $CONFIG_DIR"
echo "Generated dir: $GEN_DIR"
echo ""

# ----------------------------------------------------------------
# Phase 1: Extract API from v1 config
# ----------------------------------------------------------------
echo "--- Phase 1: v1-contacts lifecycle ---"

# Test 1: wfctl api extract from v1 config
if ! wfctl_has "api"; then
    skip "Lifecycle 1: wfctl api extract — subcommand not available"
else
    V1_SPEC="$GEN_DIR/openapi-v1.json"
    if "$WFCTL" api extract "$CONFIG_DIR/v1-contacts.yaml" -o "$V1_SPEC" 2>/dev/null; then
        if [ -f "$V1_SPEC" ]; then
            pass "Lifecycle 1: wfctl api extract v1-contacts.yaml → openapi-v1.json"
        else
            fail "Lifecycle 1: wfctl api extract ran but no output file: $V1_SPEC"
        fi
    else
        fail "Lifecycle 1: wfctl api extract v1-contacts.yaml failed"
    fi
fi

# Test 2: v1 spec has contacts endpoints
if [ -f "$GEN_DIR/openapi-v1.json" ]; then
    if grep -q "contacts" "$GEN_DIR/openapi-v1.json" 2>/dev/null; then
        pass "Lifecycle 2: v1 OpenAPI spec contains contacts endpoints"
    else
        fail "Lifecycle 2: v1 OpenAPI spec missing contacts endpoints"
    fi
else
    skip "Lifecycle 2: v1 OpenAPI spec not generated — skipping content check"
fi

# Test 3: v1 spec endpoint count
if [ -f "$GEN_DIR/openapi-v1.json" ]; then
    V1_ENDPOINT_COUNT=$(python3 -c "
import json, sys
try:
    spec = json.load(open('$GEN_DIR/openapi-v1.json'))
    paths = spec.get('paths', {})
    count = sum(len(v) for v in paths.values())
    print(count)
except:
    print(0)
" 2>/dev/null || echo "0")
    if [ "$V1_ENDPOINT_COUNT" -ge "5" ]; then
        pass "Lifecycle 3: v1 spec has $V1_ENDPOINT_COUNT endpoints (>= 5 for CRUD)"
    else
        fail "Lifecycle 3: v1 spec has $V1_ENDPOINT_COUNT endpoints (expected >= 5)"
    fi
else
    skip "Lifecycle 3: v1 spec not available — skipping endpoint count"
fi

# Test 4: Scaffold React UI from v1 spec
if ! wfctl_has "ui"; then
    skip "Lifecycle 4: wfctl ui scaffold — subcommand not available"
elif [ ! -f "$GEN_DIR/openapi-v1.json" ]; then
    skip "Lifecycle 4: v1 spec not available — cannot scaffold"
else
    UI_V1_DIR="$GEN_DIR/ui-v1"
    if "$WFCTL" ui scaffold -spec "$GEN_DIR/openapi-v1.json" -output "$UI_V1_DIR" 2>/dev/null; then
        if [ -d "$UI_V1_DIR" ]; then
            pass "Lifecycle 4: wfctl ui scaffold from v1 spec → ui-v1/"
        else
            fail "Lifecycle 4: wfctl ui scaffold ran but no output directory"
        fi
    else
        fail "Lifecycle 4: wfctl ui scaffold from v1 spec failed"
    fi
fi

# Test 5: Scaffolded v1 UI has contact-related files
if [ -d "$GEN_DIR/ui-v1" ]; then
    CONTACT_FILES=$(find "$GEN_DIR/ui-v1" -name "*contact*" -o -name "*Contact*" 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "${CONTACT_FILES:-0}" -gt "0" ]; then
        pass "Lifecycle 5: v1 scaffolded UI has $CONTACT_FILES contact-related file(s)"
    else
        fail "Lifecycle 5: v1 scaffolded UI has no contact-related files in $GEN_DIR/ui-v1"
    fi
else
    skip "Lifecycle 5: ui-v1 not generated — skipping file check"
fi

# Test 6: Build v1 UI
if ! wfctl_has "build-ui"; then
    skip "Lifecycle 6: wfctl build-ui — subcommand not available"
elif [ ! -d "$GEN_DIR/ui-v1" ]; then
    skip "Lifecycle 6: ui-v1 not scaffolded — cannot build"
else
    if "$WFCTL" build-ui "$GEN_DIR/ui-v1" 2>/dev/null; then
        if [ -d "$GEN_DIR/ui-v1/dist" ]; then
            pass "Lifecycle 6: wfctl build-ui v1 → ui-v1/dist/ generated"
        else
            fail "Lifecycle 6: wfctl build-ui ran but no dist/ directory"
        fi
    else
        fail "Lifecycle 6: wfctl build-ui v1 failed"
    fi
fi

# Test 7: v1 dist/ has at least one HTML/JS file
if [ -d "$GEN_DIR/ui-v1/dist" ]; then
    DIST_FILES=$(find "$GEN_DIR/ui-v1/dist" -name "*.html" -o -name "*.js" 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "${DIST_FILES:-0}" -gt "0" ]; then
        pass "Lifecycle 7: v1 dist/ has $DIST_FILES HTML/JS file(s)"
    else
        fail "Lifecycle 7: v1 dist/ is empty — no HTML/JS produced"
    fi
else
    skip "Lifecycle 7: ui-v1/dist not generated — skipping file check"
fi

# ----------------------------------------------------------------
# Phase 2: Extract API from v2 config, verify MORE endpoints
# ----------------------------------------------------------------
echo ""
echo "--- Phase 2: v2-notes lifecycle ---"

# Test 8: wfctl api extract from v2 config
if ! wfctl_has "api"; then
    skip "Lifecycle 8: wfctl api extract — subcommand not available"
else
    V2_SPEC="$GEN_DIR/openapi-v2.json"
    if "$WFCTL" api extract "$CONFIG_DIR/v2-notes.yaml" -o "$V2_SPEC" 2>/dev/null; then
        if [ -f "$V2_SPEC" ]; then
            pass "Lifecycle 8: wfctl api extract v2-notes.yaml → openapi-v2.json"
        else
            fail "Lifecycle 8: wfctl api extract ran but no output file: $V2_SPEC"
        fi
    else
        fail "Lifecycle 8: wfctl api extract v2-notes.yaml failed"
    fi
fi

# Test 9: v2 spec has notes and tags endpoints (more than v1)
if [ -f "$GEN_DIR/openapi-v2.json" ]; then
    if grep -q "notes" "$GEN_DIR/openapi-v2.json" 2>/dev/null && \
       grep -q "tags" "$GEN_DIR/openapi-v2.json" 2>/dev/null; then
        pass "Lifecycle 9: v2 OpenAPI spec contains notes and tags endpoints"
    else
        fail "Lifecycle 9: v2 OpenAPI spec missing notes/tags endpoints"
    fi
else
    skip "Lifecycle 9: v2 OpenAPI spec not generated — skipping content check"
fi

# Test 10: v2 spec has MORE endpoints than v1
if [ -f "$GEN_DIR/openapi-v1.json" ] && [ -f "$GEN_DIR/openapi-v2.json" ]; then
    V1_COUNT=$(python3 -c "
import json
spec = json.load(open('$GEN_DIR/openapi-v1.json'))
paths = spec.get('paths', {})
print(sum(len(v) for v in paths.values()))
" 2>/dev/null || echo "0")
    V2_COUNT=$(python3 -c "
import json
spec = json.load(open('$GEN_DIR/openapi-v2.json'))
paths = spec.get('paths', {})
print(sum(len(v) for v in paths.values()))
" 2>/dev/null || echo "0")
    if [ "$V2_COUNT" -gt "$V1_COUNT" ]; then
        pass "Lifecycle 10: v2 spec has more endpoints than v1 ($V2_COUNT > $V1_COUNT)"
    else
        fail "Lifecycle 10: v2 spec endpoint count ($V2_COUNT) not greater than v1 ($V1_COUNT)"
    fi
else
    skip "Lifecycle 10: One or both specs not available — skipping comparison"
fi

# Test 11: Scaffold React UI from v2 spec
if ! wfctl_has "ui"; then
    skip "Lifecycle 11: wfctl ui scaffold — subcommand not available"
elif [ ! -f "$GEN_DIR/openapi-v2.json" ]; then
    skip "Lifecycle 11: v2 spec not available — cannot scaffold"
else
    UI_V2_DIR="$GEN_DIR/ui-v2"
    if "$WFCTL" ui scaffold -spec "$GEN_DIR/openapi-v2.json" -output "$UI_V2_DIR" 2>/dev/null; then
        if [ -d "$UI_V2_DIR" ]; then
            pass "Lifecycle 11: wfctl ui scaffold from v2 spec → ui-v2/"
        else
            fail "Lifecycle 11: wfctl ui scaffold ran but no output directory"
        fi
    else
        fail "Lifecycle 11: wfctl ui scaffold from v2 spec failed"
    fi
fi

# Test 12: v2 UI has notes-related files (more than v1)
if [ -d "$GEN_DIR/ui-v2" ]; then
    NOTE_FILES=$(find "$GEN_DIR/ui-v2" -name "*note*" -o -name "*Note*" 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "${NOTE_FILES:-0}" -gt "0" ]; then
        pass "Lifecycle 12: v2 scaffolded UI has $NOTE_FILES note-related file(s)"
    else
        fail "Lifecycle 12: v2 scaffolded UI has no note-related files in $GEN_DIR/ui-v2"
    fi
else
    skip "Lifecycle 12: ui-v2 not generated — skipping file check"
fi

# Test 13: Build v2 UI
if ! wfctl_has "build-ui"; then
    skip "Lifecycle 13: wfctl build-ui — subcommand not available"
elif [ ! -d "$GEN_DIR/ui-v2" ]; then
    skip "Lifecycle 13: ui-v2 not scaffolded — cannot build"
else
    if "$WFCTL" build-ui "$GEN_DIR/ui-v2" 2>/dev/null; then
        if [ -d "$GEN_DIR/ui-v2/dist" ]; then
            pass "Lifecycle 13: wfctl build-ui v2 → ui-v2/dist/ generated"
        else
            fail "Lifecycle 13: wfctl build-ui v2 ran but no dist/"
        fi
    else
        fail "Lifecycle 13: wfctl build-ui v2 failed"
    fi
fi

# ----------------------------------------------------------------
# Phase 3: wfctl diff
# ----------------------------------------------------------------
echo ""
echo "--- Phase 3: Config diff ---"

# Test 14: wfctl diff v1 vs v2 configs
if ! wfctl_has "diff"; then
    skip "Lifecycle 14: wfctl diff — subcommand not available"
else
    DIFF_OUT=$("$WFCTL" diff "$CONFIG_DIR/v1-contacts.yaml" "$CONFIG_DIR/v2-notes.yaml" 2>/dev/null || echo "")
    if [ -n "$DIFF_OUT" ]; then
        pass "Lifecycle 14: wfctl diff v1 vs v2 produces output"
    else
        fail "Lifecycle 14: wfctl diff returned empty output (expected differences)"
    fi
fi

# Test 15: wfctl inspect v2 config
if ! wfctl_has "inspect"; then
    skip "Lifecycle 15: wfctl inspect — subcommand not available"
else
    INSPECT_OUT=$("$WFCTL" inspect "$CONFIG_DIR/v2-notes.yaml" 2>/dev/null || echo "")
    if [ -n "$INSPECT_OUT" ]; then
        pass "Lifecycle 15: wfctl inspect v2-notes.yaml produces output"
    else
        fail "Lifecycle 15: wfctl inspect returned empty output"
    fi
fi

# ====================================================================
# Summary
# ====================================================================
echo ""
echo "========================================"
echo "LIFECYCLE RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
echo "========================================"
if [ "$FAIL_COUNT" -gt "0" ]; then
    exit 1
fi
