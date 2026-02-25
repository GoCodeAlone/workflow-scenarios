#!/usr/bin/env bash
# Scenario 18 — Template Validation Suite
# Tests that ALL project templates produce valid, deployable configs.
# Outputs PASS:, FAIL:, or SKIP: lines for each test.
#
# Local-only: no k8s required.

set -uo pipefail

# -----------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------

SCENARIO="18-template-validation"
WORK_DIR="/tmp/scenario-18"

# Locate wfctl binary
WFCTL=""
for candidate in \
    "$(which wfctl 2>/dev/null)" \
    "/Users/jon/workspace/workflow/bin/wfctl" \
    "${WFCTL_BIN:-}"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        WFCTL="$candidate"
        break
    fi
done

if [ -z "$WFCTL" ]; then
    echo "SKIP: wfctl binary not found — all template tests skipped (set WFCTL_BIN to override)"
    exit 0
fi

echo "Using wfctl: $WFCTL"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# Check whether a wfctl sub-command exists by running it with --help and
# checking the exit code.  Some sub-commands are being built and may not be
# present yet.
cmd_available() {
    local subcmd="$1"
    "$WFCTL" "$subcmd" --help >/dev/null 2>&1
}

# -----------------------------------------------------------------------
# Template loop helper
# -----------------------------------------------------------------------
test_template() {
    local TEMPLATE="$1"
    local OUT="$WORK_DIR/$TEMPLATE"

    echo ""
    echo "--- Template: $TEMPLATE ---"

    # ------------------------------------------------------------------
    # Step 1: Scaffold
    # ------------------------------------------------------------------
    mkdir -p "$OUT"
    if "$WFCTL" init "test-$TEMPLATE" \
            --template "$TEMPLATE" \
            --author "TestOrg" \
            --output "$OUT" \
            >/dev/null 2>&1; then
        pass "[$TEMPLATE] wfctl init scaffolds project"
    else
        fail "[$TEMPLATE] wfctl init failed"
        # Can't continue without a scaffolded project
        skip "[$TEMPLATE] wfctl validate — skipped (scaffold failed)"
        skip "[$TEMPLATE] wfctl template validate — skipped (scaffold failed)"
        skip "[$TEMPLATE] wfctl inspect — skipped (scaffold failed)"
        skip "[$TEMPLATE] wfctl api extract — skipped (scaffold failed)"
        skip "[$TEMPLATE] wfctl contract test — skipped (scaffold failed)"
        skip "[$TEMPLATE] wfctl compat check — skipped (scaffold failed)"
        return
    fi

    # Identify the workflow config file produced by this template.
    CONFIG_FILE=""
    for candidate in \
        "$OUT/workflow.yaml" \
        "$OUT/config/workflow.yaml" \
        "$OUT/app.yaml" \
        "$OUT/config/app.yaml"; do
        if [ -f "$candidate" ]; then
            CONFIG_FILE="$candidate"
            break
        fi
    done

    # ------------------------------------------------------------------
    # Step 2: Validate config
    # ------------------------------------------------------------------
    if [ -z "$CONFIG_FILE" ]; then
        skip "[$TEMPLATE] wfctl validate — no workflow.yaml produced by template"
    elif "$WFCTL" validate "$CONFIG_FILE" >/dev/null 2>&1; then
        pass "[$TEMPLATE] wfctl validate passes"
    else
        fail "[$TEMPLATE] wfctl validate failed for $CONFIG_FILE"
    fi

    # ------------------------------------------------------------------
    # Step 3: Template validate (may not exist yet)
    # ------------------------------------------------------------------
    if [ -z "$CONFIG_FILE" ]; then
        skip "[$TEMPLATE] wfctl template validate — no config file"
    elif ! cmd_available "template"; then
        skip "[$TEMPLATE] wfctl template validate — command not available"
    else
        if "$WFCTL" template validate -config "$CONFIG_FILE" >/dev/null 2>&1; then
            pass "[$TEMPLATE] wfctl template validate passes"
        else
            fail "[$TEMPLATE] wfctl template validate failed"
        fi
    fi

    # ------------------------------------------------------------------
    # Step 4: Inspect — verify modules and pipelines are listed
    # ------------------------------------------------------------------
    if [ -z "$CONFIG_FILE" ]; then
        skip "[$TEMPLATE] wfctl inspect — no config file"
    else
        INSPECT_OUT=$("$WFCTL" inspect "$CONFIG_FILE" 2>&1 || true)
        if echo "$INSPECT_OUT" | grep -qiE "module|pipeline"; then
            pass "[$TEMPLATE] wfctl inspect lists modules/pipelines"
        else
            fail "[$TEMPLATE] wfctl inspect produced no modules/pipelines output: $INSPECT_OUT"
        fi
    fi

    # ------------------------------------------------------------------
    # Step 5: API extract — verify OpenAPI spec is generated
    # ------------------------------------------------------------------
    OPENAPI_FILE=""
    if [ -z "$CONFIG_FILE" ]; then
        skip "[$TEMPLATE] wfctl api extract — no config file"
    else
        OPENAPI_FILE="$OUT/openapi.json"
        if "$WFCTL" api extract "$CONFIG_FILE" --output "$OPENAPI_FILE" >/dev/null 2>&1 || \
           "$WFCTL" api extract "$CONFIG_FILE" -output "$OPENAPI_FILE" >/dev/null 2>&1; then
            if [ -s "$OPENAPI_FILE" ]; then
                pass "[$TEMPLATE] wfctl api extract generates OpenAPI spec"
            else
                fail "[$TEMPLATE] wfctl api extract produced empty file"
                OPENAPI_FILE=""
            fi
        else
            fail "[$TEMPLATE] wfctl api extract failed"
            OPENAPI_FILE=""
        fi
    fi

    # ------------------------------------------------------------------
    # Step 6: Contract generate (may not exist yet)
    # ------------------------------------------------------------------
    if [ -z "$CONFIG_FILE" ]; then
        skip "[$TEMPLATE] wfctl contract test — no config file"
    elif ! cmd_available "contract"; then
        skip "[$TEMPLATE] wfctl contract test — command not available"
    else
        CONTRACT_FILE="$OUT/contract.json"
        if "$WFCTL" contract test "$CONFIG_FILE" -output "$CONTRACT_FILE" >/dev/null 2>&1; then
            if [ -s "$CONTRACT_FILE" ]; then
                pass "[$TEMPLATE] wfctl contract test generates contract"
            else
                fail "[$TEMPLATE] wfctl contract test produced empty file"
            fi
        else
            fail "[$TEMPLATE] wfctl contract test failed"
        fi
    fi

    # ------------------------------------------------------------------
    # Step 7: Compat check (may not exist yet)
    # ------------------------------------------------------------------
    if [ -z "$CONFIG_FILE" ]; then
        skip "[$TEMPLATE] wfctl compat check — no config file"
    elif ! cmd_available "compat"; then
        skip "[$TEMPLATE] wfctl compat check — command not available"
    else
        if "$WFCTL" compat check "$CONFIG_FILE" >/dev/null 2>&1; then
            pass "[$TEMPLATE] wfctl compat check passes"
        else
            fail "[$TEMPLATE] wfctl compat check failed"
        fi
    fi
}

# -----------------------------------------------------------------------
# Run all 5 templates
# -----------------------------------------------------------------------
echo "=== Scenario 18: Template Validation Suite ==="

for TMPL in api-service event-processor full-stack plugin ui-plugin; do
    test_template "$TMPL"
done

# -----------------------------------------------------------------------
# full-stack extra: UI scaffold
# -----------------------------------------------------------------------
echo ""
echo "--- full-stack extra: UI scaffold ---"
FULL_STACK_OUT="$WORK_DIR/full-stack"
OPENAPI_SPEC="$FULL_STACK_OUT/openapi.json"
UI_GEN_DIR="$FULL_STACK_OUT/ui-gen"

if [ ! -d "$FULL_STACK_OUT" ]; then
    skip "full-stack UI scaffold — full-stack template directory missing"
elif [ ! -f "$OPENAPI_SPEC" ]; then
    skip "full-stack UI scaffold — openapi.json not generated (api extract failed)"
elif ! cmd_available "ui"; then
    skip "full-stack UI scaffold — wfctl ui command not available"
else
    mkdir -p "$UI_GEN_DIR"
    if "$WFCTL" ui scaffold \
            -spec "$OPENAPI_SPEC" \
            -output "$UI_GEN_DIR" \
            >/dev/null 2>&1; then
        # Verify some UI project structure was generated
        if [ "$(ls -A "$UI_GEN_DIR" 2>/dev/null)" ]; then
            pass "full-stack UI scaffold generates UI project from OpenAPI spec"
        else
            fail "full-stack UI scaffold produced empty directory"
        fi
    else
        fail "full-stack UI scaffold command failed"
    fi
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "=== Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ==="
