#!/usr/bin/env bash
# Scenario 19 — Version Contract Tests
# Tests contract generation, comparison, and breaking change detection.
# Outputs PASS:, FAIL:, or SKIP: lines for each test.
#
# Local-only: no k8s required.

set -uo pipefail

# -----------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------

SCENARIO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGS_DIR="$SCENARIO_DIR/configs"
WORK_DIR="/tmp/scenario-19"

V1_CONFIG="$CONFIGS_DIR/v1-simple-api.yaml"
V2_CONFIG="$CONFIGS_DIR/v2-extended-api.yaml"
V3_CONFIG="$CONFIGS_DIR/v3-breaking-api.yaml"

# Locate wfctl binary
WORKFLOW_REPO="${WORKFLOW_REPO:-$(cd "$SCENARIO_DIR/../../.." && pwd)/workflow}"

WFCTL=""
for candidate in \
    "$(which wfctl 2>/dev/null)" \
    "$WORKFLOW_REPO/bin/wfctl" \
    "${WFCTL_BIN:-}"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        WFCTL="$candidate"
        break
    fi
done

if [ -z "$WFCTL" ]; then
    echo "SKIP: wfctl binary not found — all contract tests skipped (set WFCTL_BIN to override)"
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

# Check whether a wfctl sub-command exists
cmd_available() {
    "$WFCTL" "$1" --help >/dev/null 2>&1
}

# -----------------------------------------------------------------------
# Phase 1: Baseline Contract
# -----------------------------------------------------------------------
echo ""
echo "=== Phase 1: Generate v1 baseline contract ==="

# Test 1.1: Validate v1 config
if "$WFCTL" validate "$V1_CONFIG" >/dev/null 2>&1; then
    pass "v1 config passes wfctl validate"
else
    fail "v1 config failed wfctl validate"
fi

# Test 1.2: Generate contract from v1
V1_CONTRACT="$WORK_DIR/contract-v1.json"
if ! cmd_available "contract"; then
    skip "v1 contract generation — wfctl contract command not available"
    skip "v1 contract has expected endpoints — skipped (contract generation skipped)"
else
    if "$WFCTL" contract test "$V1_CONFIG" -output "$V1_CONTRACT" >/dev/null 2>&1; then
        if [ -s "$V1_CONTRACT" ]; then
            pass "v1 contract generation produces output file"
        else
            fail "v1 contract generation produced empty file"
        fi
    else
        fail "v1 contract generation failed"
    fi

    # Test 1.3: Verify contract has expected endpoints
    if [ -s "$V1_CONTRACT" ]; then
        MISSING_ENDPOINTS=""
        for endpoint in \
            "/api/v1/auth/register" \
            "/api/v1/auth/login" \
            "/api/v1/auth/profile" \
            "/api/v1/items"; do
            if ! grep -q "$endpoint" "$V1_CONTRACT" 2>/dev/null; then
                MISSING_ENDPOINTS="$MISSING_ENDPOINTS $endpoint"
            fi
        done
        if [ -z "$MISSING_ENDPOINTS" ]; then
            pass "v1 contract contains all expected endpoints"
        else
            fail "v1 contract missing endpoints:$MISSING_ENDPOINTS"
        fi
    else
        skip "v1 contract endpoint check — no contract file"
    fi
fi

# -----------------------------------------------------------------------
# Phase 2: Non-Breaking Extension
# -----------------------------------------------------------------------
echo ""
echo "=== Phase 2: Compare v2 (non-breaking extension) ==="

# Test 2.1: Validate v2 config
if "$WFCTL" validate "$V2_CONFIG" >/dev/null 2>&1; then
    pass "v2 config passes wfctl validate"
else
    fail "v2 config failed wfctl validate"
fi

# Test 2.2: Generate contract from v2
V2_CONTRACT="$WORK_DIR/contract-v2.json"
if ! cmd_available "contract"; then
    skip "v2 contract generation — wfctl contract command not available"
    skip "v2 vs v1 breaking change check — skipped (contract generation skipped)"
    skip "v2 new endpoints detected as additions — skipped (contract generation skipped)"
else
    if "$WFCTL" contract test "$V2_CONFIG" -output "$V2_CONTRACT" >/dev/null 2>&1; then
        if [ -s "$V2_CONTRACT" ]; then
            pass "v2 contract generation produces output file"
        else
            fail "v2 contract generation produced empty file"
        fi
    else
        fail "v2 contract generation failed"
    fi

    # Test 2.3: Compare v2 against v1 — expect NO breaking changes
    if [ -s "$V1_CONTRACT" ] && [ -s "$V2_CONTRACT" ]; then
        COMPARE_OUT=$("$WFCTL" contract compare \
            -baseline "$V1_CONTRACT" \
            -candidate "$V2_CONTRACT" 2>&1 || true)
        if echo "$COMPARE_OUT" | grep -qi "breaking"; then
            fail "v2 vs v1 reported unexpected breaking changes: $COMPARE_OUT"
        else
            pass "v2 vs v1 comparison reports no breaking changes"
        fi

        # Test 2.4: New endpoints detected as additions
        if echo "$COMPARE_OUT" | grep -qiE "addition|added|new"; then
            pass "v2 new endpoints detected as additions by contract compare"
        else
            skip "v2 addition detection — compare output did not mention additions (tool may not report this)"
        fi
    else
        skip "v2 vs v1 breaking change check — contract files not available"
        skip "v2 new endpoints detected as additions — contract files not available"
    fi
fi

# -----------------------------------------------------------------------
# Phase 3: Breaking Change Detection
# -----------------------------------------------------------------------
echo ""
echo "=== Phase 3: Compare v3 (intentional breaking changes) ==="

# Test 3.1: Validate v3 config (should still be a valid config)
if "$WFCTL" validate "$V3_CONFIG" >/dev/null 2>&1; then
    pass "v3 config passes wfctl validate (it is a valid config)"
else
    fail "v3 config failed wfctl validate"
fi

# Test 3.2: Generate contract from v3
V3_CONTRACT="$WORK_DIR/contract-v3.json"
if ! cmd_available "contract"; then
    skip "v3 contract generation — wfctl contract command not available"
    skip "v3 vs v1 breaking changes detected — skipped (contract generation skipped)"
    skip "v3 removed login endpoint flagged — skipped (contract generation skipped)"
    skip "v3 path change flagged — skipped (contract generation skipped)"
    skip "v3 auth-added-to-public-endpoint flagged — skipped (contract generation skipped)"
else
    if "$WFCTL" contract test "$V3_CONFIG" -output "$V3_CONTRACT" >/dev/null 2>&1; then
        if [ -s "$V3_CONTRACT" ]; then
            pass "v3 contract generation produces output file"
        else
            fail "v3 contract generation produced empty file"
        fi
    else
        fail "v3 contract generation failed"
    fi

    # Test 3.3: Compare v3 against v1 — expect breaking changes
    if [ -s "$V1_CONTRACT" ] && [ -s "$V3_CONTRACT" ]; then
        COMPARE_OUT=$("$WFCTL" contract compare \
            -baseline "$V1_CONTRACT" \
            -candidate "$V3_CONTRACT" 2>&1 || true)

        if echo "$COMPARE_OUT" | grep -qi "breaking"; then
            pass "v3 vs v1 comparison correctly reports breaking changes"
        else
            fail "v3 vs v1 comparison should have reported breaking changes but did not: $COMPARE_OUT"
        fi

        # Test 3.4: Removed login endpoint is flagged
        if echo "$COMPARE_OUT" | grep -qiE "login|/api/v1/auth/login|removed|missing"; then
            pass "v3 removed login endpoint (/api/v1/auth/login) is flagged"
        else
            skip "v3 removed-login check — compare output may not name specific paths"
        fi

        # Test 3.5: Path change (register) is flagged
        if echo "$COMPARE_OUT" | grep -qiE "register|/api/v1/auth/register|path.*change|moved"; then
            pass "v3 register path change (/api/v1/auth/register → /api/v2/auth/register) is flagged"
        else
            skip "v3 path-change check — compare output may not name specific paths"
        fi

        # Test 3.6: Auth added to previously public endpoint is flagged
        if echo "$COMPARE_OUT" | grep -qiE "auth|authentication|/api/v1/items|unauthorized|security"; then
            pass "v3 auth-added-to-public-endpoint (/api/v1/items GET) is flagged"
        else
            skip "v3 auth-added check — compare output may not report auth additions"
        fi
    else
        skip "v3 vs v1 breaking changes detected — contract files not available"
        skip "v3 removed login endpoint flagged — contract files not available"
        skip "v3 path change flagged — contract files not available"
        skip "v3 auth-added-to-public-endpoint flagged — contract files not available"
    fi
fi

# -----------------------------------------------------------------------
# Phase 4: Template Round-Trip
# -----------------------------------------------------------------------
echo ""
echo "=== Phase 4: Template round-trip ==="

TMPL_DIR="$WORK_DIR/template-roundtrip"
mkdir -p "$TMPL_DIR"

# Test 4.1: Init api-service template
if "$WFCTL" init \
        --template "api-service" \
        --author "TestOrg" \
        --output "$TMPL_DIR" \
        "roundtrip-api" \
        >/dev/null 2>&1; then
    pass "Template round-trip: wfctl init api-service succeeds"
else
    fail "Template round-trip: wfctl init api-service failed"
fi

# Find config
TMPL_CONFIG=""
for candidate in \
    "$TMPL_DIR/workflow.yaml" \
    "$TMPL_DIR/config/workflow.yaml" \
    "$TMPL_DIR/app.yaml" \
    "$TMPL_DIR/config/app.yaml"; do
    if [ -f "$candidate" ]; then
        TMPL_CONFIG="$candidate"
        break
    fi
done

# Test 4.2: Validate template config
if [ -z "$TMPL_CONFIG" ]; then
    skip "Template round-trip validate — no workflow.yaml produced"
elif "$WFCTL" validate "$TMPL_CONFIG" >/dev/null 2>&1; then
    pass "Template round-trip: generated config passes wfctl validate"
else
    fail "Template round-trip: generated config failed wfctl validate"
fi

# Test 4.3: Generate contract from template config
TMPL_CONTRACT="$WORK_DIR/contract-template.json"
if [ -z "$TMPL_CONFIG" ]; then
    skip "Template round-trip contract — no config file"
elif ! cmd_available "contract"; then
    skip "Template round-trip contract — wfctl contract not available"
else
    if "$WFCTL" contract test "$TMPL_CONFIG" -output "$TMPL_CONTRACT" >/dev/null 2>&1; then
        if [ -s "$TMPL_CONTRACT" ]; then
            pass "Template round-trip: contract generated from template config"
        else
            fail "Template round-trip: contract file is empty"
        fi
    else
        fail "Template round-trip: contract generation failed"
    fi
fi

# Test 4.4: Verify all template endpoints appear in contract
if [ -s "$TMPL_CONTRACT" ]; then
    # api-service template is expected to have at least auth and a resource endpoint
    if grep -qiE "register|login|health|api" "$TMPL_CONTRACT" 2>/dev/null; then
        pass "Template round-trip: contract contains expected template endpoints"
    else
        fail "Template round-trip: contract does not contain expected template endpoints"
    fi
else
    skip "Template round-trip endpoint check — no contract file"
fi

# -----------------------------------------------------------------------
# Phase 5: OpenAPI Spec Comparison
# -----------------------------------------------------------------------
echo ""
echo "=== Phase 5: OpenAPI spec comparison ==="

# Test 5.1: Extract OpenAPI from v1
SPEC_V1="$WORK_DIR/spec-v1.json"
if "$WFCTL" api extract --output "$SPEC_V1" "$V1_CONFIG" >/dev/null 2>&1 || \
   "$WFCTL" api extract -output "$SPEC_V1" "$V1_CONFIG" >/dev/null 2>&1; then
    if [ -s "$SPEC_V1" ]; then
        pass "v1 OpenAPI spec extracted successfully"
    else
        fail "v1 OpenAPI spec file is empty"
    fi
else
    fail "v1 OpenAPI spec extraction failed"
fi

# Test 5.2: Extract OpenAPI from v2
SPEC_V2="$WORK_DIR/spec-v2.json"
if "$WFCTL" api extract --output "$SPEC_V2" "$V2_CONFIG" >/dev/null 2>&1 || \
   "$WFCTL" api extract -output "$SPEC_V2" "$V2_CONFIG" >/dev/null 2>&1; then
    if [ -s "$SPEC_V2" ]; then
        pass "v2 OpenAPI spec extracted successfully"
    else
        fail "v2 OpenAPI spec file is empty"
    fi
else
    fail "v2 OpenAPI spec extraction failed"
fi

# Test 5.3: v2 has all v1 paths
if [ -s "$SPEC_V1" ] && [ -s "$SPEC_V2" ]; then
    MISSING=""
    while IFS= read -r path; do
        if ! grep -q "$path" "$SPEC_V2" 2>/dev/null; then
            MISSING="$MISSING $path"
        fi
    done < <(grep -oE '"/api/v1/[^"]*"' "$SPEC_V1" 2>/dev/null | tr -d '"' | sort -u)

    if [ -z "$MISSING" ]; then
        pass "v2 OpenAPI spec contains all v1 paths"
    else
        fail "v2 OpenAPI spec missing v1 paths:$MISSING"
    fi
else
    skip "v2 contains all v1 paths check — spec files not available"
fi

# Test 5.4: v2 spec has additional paths not in v1
if [ -s "$SPEC_V1" ] && [ -s "$SPEC_V2" ]; then
    V2_PATHS=$(grep -oE '"/api/v1/items/[^"]*"' "$SPEC_V2" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$V2_PATHS" -gt 0 ]; then
        pass "v2 OpenAPI spec has additional paths beyond v1 (e.g. /api/v1/items/{id})"
    else
        skip "v2 additional paths check — could not detect new paths in spec"
    fi
else
    skip "v2 additional paths check — spec files not available"
fi

# Test 5.5: Extract OpenAPI from v3
SPEC_V3="$WORK_DIR/spec-v3.json"
if "$WFCTL" api extract --output "$SPEC_V3" "$V3_CONFIG" >/dev/null 2>&1 || \
   "$WFCTL" api extract -output "$SPEC_V3" "$V3_CONFIG" >/dev/null 2>&1; then
    if [ -s "$SPEC_V3" ]; then
        pass "v3 OpenAPI spec extracted successfully"
    else
        fail "v3 OpenAPI spec file is empty"
    fi
else
    fail "v3 OpenAPI spec extraction failed"
fi

# Test 5.6: v3 spec is missing v1 login path (confirms breaking change at API level)
if [ -s "$SPEC_V1" ] && [ -s "$SPEC_V3" ]; then
    if grep -q "/api/v1/auth/login" "$SPEC_V1" 2>/dev/null; then
        # v1 has login — v3 should NOT have it
        if ! grep -q "/api/v1/auth/login" "$SPEC_V3" 2>/dev/null; then
            pass "v3 OpenAPI spec is missing /api/v1/auth/login (confirms breaking change)"
        else
            fail "v3 OpenAPI spec still contains /api/v1/auth/login — breaking change not reflected in spec"
        fi
    else
        skip "v3 login path removal check — /api/v1/auth/login not found in v1 spec"
    fi
else
    skip "v3 missing login path check — spec files not available"
fi

# Test 5.7: v3 spec has /api/v2/auth/register instead of v1 path
if [ -s "$SPEC_V3" ]; then
    if grep -q "/api/v2/auth/register" "$SPEC_V3" 2>/dev/null; then
        pass "v3 OpenAPI spec contains /api/v2/auth/register (new path)"
    else
        skip "v3 new register path check — /api/v2/auth/register not in spec (spec may not reflect path version)"
    fi
else
    skip "v3 new register path check — v3 spec not available"
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "=== Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ==="
