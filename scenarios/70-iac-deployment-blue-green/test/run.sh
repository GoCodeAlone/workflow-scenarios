#!/usr/bin/env bash
# Scenario 70 — IaC Deployment Blue-Green
# Config-validation only: validates YAML syntax and blue-green deployment wiring.
# Tests that blue + green container_service modules, step.deploy_blue_green,
# load balancer, and health check configs are correctly defined.
set -uo pipefail

SCENARIO="70-iac-deployment-blue-green"
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

# Test 4: iac.provider (aws) and iac.state
grep -q "type: iac.provider" "$CONFIG" \
    && pass "iac.provider module defined" \
    || fail "iac.provider module missing"

grep -q "provider: aws" "$CONFIG" \
    && pass "iac.provider uses provider: aws" \
    || fail "iac.provider missing provider: aws"

grep -q "type: iac.state" "$CONFIG" \
    && pass "iac.state module defined" \
    || fail "iac.state module missing"

# Test 5: blue and green container_service modules
CONTAINER_COUNT=$(grep -c "type: infra.container_service" "$CONFIG" || echo "0")
[ "$CONTAINER_COUNT" -ge 2 ] \
    && pass "at least 2 infra.container_service modules defined (blue + green)" \
    || fail "expected at least 2 infra.container_service modules (found $CONTAINER_COUNT)"

grep -q "name: app-blue" "$CONFIG" \
    && pass "blue slot (app-blue) defined" \
    || fail "blue slot (app-blue) missing"

grep -q "name: app-green" "$CONFIG" \
    && pass "green slot (app-green) defined" \
    || fail "green slot (app-green) missing"

# Test 6: infra.load_balancer
grep -q "type: infra.load_balancer" "$CONFIG" \
    && pass "infra.load_balancer module defined" \
    || fail "infra.load_balancer module missing"

grep -q "healthCheck:" "$CONFIG" \
    && pass "load balancer healthCheck config defined" \
    || fail "load balancer healthCheck config missing"

# Test 7: step.deploy_blue_green
grep -q "type: step.deploy_blue_green" "$CONFIG" \
    && pass "step.deploy_blue_green step defined" \
    || fail "step.deploy_blue_green step missing"

grep -q "blueService:" "$CONFIG" \
    && pass "step.deploy_blue_green blueService reference defined" \
    || fail "step.deploy_blue_green blueService reference missing"

grep -q "greenService:" "$CONFIG" \
    && pass "step.deploy_blue_green greenService reference defined" \
    || fail "step.deploy_blue_green greenService reference missing"

grep -q "loadBalancer:" "$CONFIG" \
    && pass "step.deploy_blue_green loadBalancer reference defined" \
    || fail "step.deploy_blue_green loadBalancer reference missing"

# Test 8: step.deploy_verify
grep -q "type: step.deploy_verify" "$CONFIG" \
    && pass "step.deploy_verify step defined" \
    || fail "step.deploy_verify step missing"

# Test 9: rollback pipeline
grep -q "rollback:" "$CONFIG" \
    && pass "rollback pipeline defined" \
    || fail "rollback pipeline missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
