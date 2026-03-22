#!/usr/bin/env bash
# Scenario 67 — IaC OpenTofu HCL Generation
# Config-validation only: validates YAML syntax and tofu.generator module wiring.
# Tests that expected .tf output file references are present in the config.
set -uo pipefail

SCENARIO="67-iac-tofu-generate"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
WORKFLOW_REPO="${WORKFLOW_REPO:-$(cd "$SCENARIO_DIR/../../.." && pwd)/workflow}"
CONFIG="$SCENARIO_DIR/config/app.yaml"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

echo ""
echo "=== Scenario $SCENARIO ==="
echo ""

# Locate wfctl binary
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
    skip "wfctl binary not found — config validation skipped (set WFCTL_BIN to override)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

echo "Using wfctl: $WFCTL"

# Test 1: config file exists
[ -f "$CONFIG" ] && pass "config/app.yaml exists" || { fail "config/app.yaml missing"; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1; }

# Test 2: YAML syntax is valid
python3 -c "import sys, yaml; yaml.safe_load(open('$CONFIG'))" 2>/dev/null \
    && pass "config/app.yaml is valid YAML" \
    || fail "config/app.yaml YAML syntax error"

# Test 3: wfctl validate
OUTPUT=$("$WFCTL" validate -c "$CONFIG" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "wfctl validate passes" || fail "wfctl validate failed: $OUTPUT"

# Test 4: tofu.generator module
grep -q "type: tofu.generator" "$CONFIG" \
    && pass "tofu.generator module defined" \
    || fail "tofu.generator module missing"

grep -q "outputDir:" "$CONFIG" \
    && pass "tofu.generator outputDir configured" \
    || fail "tofu.generator outputDir missing"

# Test 5: iac.provider and iac.state
grep -q "type: iac.provider" "$CONFIG" \
    && pass "iac.provider module defined" \
    || fail "iac.provider module missing"

grep -q "type: iac.state" "$CONFIG" \
    && pass "iac.state module defined" \
    || fail "iac.state module missing"

# Test 6: infra resource modules
grep -q "type: infra.vpc" "$CONFIG" \
    && pass "infra.vpc module defined" \
    || fail "infra.vpc module missing"

grep -q "type: infra.database" "$CONFIG" \
    && pass "infra.database module defined" \
    || fail "infra.database module missing"

grep -q "type: infra.container_service" "$CONFIG" \
    && pass "infra.container_service module defined" \
    || fail "infra.container_service module missing"

# Test 7: step.tofu_generate steps for each resource
GENERATE_STEPS=$(grep -c "type: step.tofu_generate" "$CONFIG" || echo "0")
[ "$GENERATE_STEPS" -ge 3 ] \
    && pass "at least 3 step.tofu_generate steps defined ($GENERATE_STEPS found)" \
    || fail "expected at least 3 step.tofu_generate steps (found $GENERATE_STEPS)"

# Test 8: expected .tf output files referenced
grep -q "outputFile: vpc.tf" "$CONFIG" \
    && pass "vpc.tf output file referenced" \
    || fail "vpc.tf output file reference missing"

grep -q "outputFile: database.tf" "$CONFIG" \
    && pass "database.tf output file referenced" \
    || fail "database.tf output file reference missing"

grep -q "outputFile: ecs.tf" "$CONFIG" \
    && pass "ecs.tf output file referenced" \
    || fail "ecs.tf output file reference missing"

# Test 9: tofu validate and plan steps
grep -q "type: step.tofu_validate" "$CONFIG" \
    && pass "step.tofu_validate step defined" \
    || fail "step.tofu_validate step missing"

grep -q "type: step.tofu_plan" "$CONFIG" \
    && pass "step.tofu_plan step defined" \
    || fail "step.tofu_plan step missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
