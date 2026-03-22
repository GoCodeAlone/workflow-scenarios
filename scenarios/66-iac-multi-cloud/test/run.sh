#!/usr/bin/env bash
# Scenario 66 — IaC Multi-Cloud
# Config-validation only: validates that the same config works with both
# provider: aws and provider: digitalocean by running wfctl validate twice
# with different IAC_PROVIDER env var values.
set -uo pipefail

SCENARIO="66-iac-multi-cloud"
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

# Test 3: wfctl validate with provider: aws
OUTPUT=$(IAC_PROVIDER=aws "$WFCTL" validate -c "$CONFIG" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "wfctl validate passes with IAC_PROVIDER=aws" || fail "wfctl validate failed (aws): $OUTPUT"

# Test 4: wfctl validate with provider: digitalocean
OUTPUT=$(IAC_PROVIDER=digitalocean "$WFCTL" validate -c "$CONFIG" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "wfctl validate passes with IAC_PROVIDER=digitalocean" || fail "wfctl validate failed (digitalocean): $OUTPUT"

# Test 5: iac.provider module present
grep -q "type: iac.provider" "$CONFIG" \
    && pass "iac.provider module defined" \
    || fail "iac.provider module missing"

# Test 6: provider uses config template (not hardcoded)
grep -q 'provider: "{{ config' "$CONFIG" \
    && pass "iac.provider provider is config-templated" \
    || fail "iac.provider provider is hardcoded (should use config template)"

# Test 7: iac.state backend: memory
grep -q "type: iac.state" "$CONFIG" \
    && pass "iac.state module defined" \
    || fail "iac.state module missing"

grep -q "backend: memory" "$CONFIG" \
    && pass "iac.state uses backend: memory" \
    || fail "iac.state missing backend: memory"

# Test 8: infra resource modules
grep -q "type: infra.vpc" "$CONFIG" \
    && pass "infra.vpc module defined" \
    || fail "infra.vpc module missing"

grep -q "type: infra.database" "$CONFIG" \
    && pass "infra.database module defined" \
    || fail "infra.database module missing"

grep -q "type: infra.container_service" "$CONFIG" \
    && pass "infra.container_service module defined" \
    || fail "infra.container_service module missing"

# Test 9: all infra modules reference shared provider
PROVIDER_REFS=$(grep -c "provider: cloud-provider" "$CONFIG" || echo "0")
[ "$PROVIDER_REFS" -ge 3 ] \
    && pass "all infra modules reference shared cloud-provider ($PROVIDER_REFS refs)" \
    || fail "infra modules should all reference cloud-provider (found $PROVIDER_REFS)"

# Test 10: IaC pipeline steps present
grep -q "type: step.iac_plan" "$CONFIG" \
    && pass "step.iac_plan pipeline step defined" \
    || fail "step.iac_plan missing"

grep -q "type: step.iac_apply" "$CONFIG" \
    && pass "step.iac_apply pipeline step defined" \
    || fail "step.iac_apply missing"

grep -q "type: step.iac_destroy" "$CONFIG" \
    && pass "step.iac_destroy pipeline step defined" \
    || fail "step.iac_destroy missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
