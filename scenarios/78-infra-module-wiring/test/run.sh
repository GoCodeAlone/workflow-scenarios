#!/usr/bin/env bash
# Scenario 78 — Infra Module Wiring
# Config-validation only: validates iac.provider → infra.* → step.iac_* delegation chain.
# Tests that all infra modules explicitly reference the provider by name and that
# all IaC step configs reference iac-state by name.
set -uo pipefail

SCENARIO="78-infra-module-wiring"
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
    "${WFCTL_BIN:-}" \
    "$(which wfctl 2>/dev/null)" \
    "$WORKFLOW_REPO/bin/wfctl" \
    "/tmp/wfctl"; do
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
OUTPUT=$("$WFCTL" validate --skip-unknown-types "$CONFIG" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "wfctl validate passes" || fail "wfctl validate failed: $OUTPUT"

# Test 4: root provider (aws-provider)
grep -q "type: iac.provider" "$CONFIG" \
    && pass "iac.provider module defined" \
    || fail "iac.provider module missing"

grep -q "name: aws-provider" "$CONFIG" \
    && pass "iac.provider named aws-provider" \
    || fail "iac.provider missing name: aws-provider"

grep -q "provider: aws" "$CONFIG" \
    && pass "iac.provider uses provider: aws" \
    || fail "iac.provider missing provider: aws"

# Test 5: iac.state named iac-state
grep -q "type: iac.state" "$CONFIG" \
    && pass "iac.state module defined" \
    || fail "iac.state module missing"

grep -q "name: iac-state" "$CONFIG" \
    && pass "iac.state named iac-state" \
    || fail "iac.state missing name: iac-state"

# Test 6: infra modules referencing aws-provider explicitly
grep -q "type: infra.vpc" "$CONFIG" \
    && pass "infra.vpc module defined" \
    || fail "infra.vpc module missing"

grep -q "type: infra.database" "$CONFIG" \
    && pass "infra.database module defined" \
    || fail "infra.database module missing"

grep -q "type: infra.container_service" "$CONFIG" \
    && pass "infra.container_service module defined" \
    || fail "infra.container_service module missing"

# Count provider references (each infra module should have provider: aws-provider)
PROVIDER_REFS=$(grep -c "provider: aws-provider" "$CONFIG" || echo "0")
[ "$PROVIDER_REFS" -ge 3 ] \
    && pass "at least 3 infra modules reference provider: aws-provider ($PROVIDER_REFS found)" \
    || fail "expected at least 3 provider: aws-provider references (found $PROVIDER_REFS)"

# Test 7: IaC steps reference iac-state
STATE_REFS=$(grep -c "state_store: iac-state" "$CONFIG" || echo "0")
[ "$STATE_REFS" -ge 3 ] \
    && pass "at least 3 IaC steps reference state_store: iac-state ($STATE_REFS found)" \
    || fail "expected at least 3 state_store: iac-state references (found $STATE_REFS)"

# Test 8: plan and apply steps
grep -q "type: step.iac_plan" "$CONFIG" \
    && pass "step.iac_plan defined" \
    || fail "step.iac_plan missing"

grep -q "type: step.iac_apply" "$CONFIG" \
    && pass "step.iac_apply defined" \
    || fail "step.iac_apply missing"

grep -q "type: step.iac_status" "$CONFIG" \
    && pass "step.iac_status defined" \
    || fail "step.iac_status missing"

# Test 9: pipelines
grep -q "plan-all:" "$CONFIG" \
    && pass "plan-all pipeline defined" \
    || fail "plan-all pipeline missing"

grep -q "apply-all:" "$CONFIG" \
    && pass "apply-all pipeline defined" \
    || fail "apply-all pipeline missing"

grep -q "status-check:" "$CONFIG" \
    && pass "status-check pipeline defined" \
    || fail "status-check pipeline missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
