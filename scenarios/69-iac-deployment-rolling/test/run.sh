#!/usr/bin/env bash
# Scenario 69 — IaC Deployment Rolling
# Config-validation only: validates YAML syntax and rolling deployment wiring.
# Tests that infra.container_service, step.deploy_rolling, and step.deploy_verify
# are correctly defined with expected rolling update parameters.
set -uo pipefail

SCENARIO="69-iac-deployment-rolling"
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

# Test 4: iac.provider and iac.state
grep -q "type: iac.provider" "$CONFIG" \
    && pass "iac.provider module defined" \
    || fail "iac.provider module missing"

grep -q "provider: digitalocean" "$CONFIG" \
    && pass "iac.provider uses provider: digitalocean" \
    || fail "iac.provider missing provider: digitalocean"

grep -q "type: iac.state" "$CONFIG" \
    && pass "iac.state module defined" \
    || fail "iac.state module missing"

# Test 5: infra.container_service with rollingUpdate config
grep -q "type: infra.container_service" "$CONFIG" \
    && pass "infra.container_service module defined" \
    || fail "infra.container_service module missing"

grep -q "rollingUpdate:" "$CONFIG" \
    && pass "rollingUpdate config block defined" \
    || fail "rollingUpdate config block missing"

grep -q "maxSurge:" "$CONFIG" \
    && pass "rollingUpdate.maxSurge defined" \
    || fail "rollingUpdate.maxSurge missing"

grep -q "maxUnavailable:" "$CONFIG" \
    && pass "rollingUpdate.maxUnavailable defined" \
    || fail "rollingUpdate.maxUnavailable missing"

grep -q "healthCheckPath:" "$CONFIG" \
    && pass "healthCheckPath defined" \
    || fail "healthCheckPath missing"

# Test 6: step.deploy_rolling with required fields
grep -q "type: step.deploy_rolling" "$CONFIG" \
    && pass "step.deploy_rolling step defined" \
    || fail "step.deploy_rolling step missing"

grep -q "service: app-service" "$CONFIG" \
    && pass "step.deploy_rolling references service: app-service" \
    || fail "step.deploy_rolling missing service reference"

# Test 7: step.deploy_verify present
grep -q "type: step.deploy_verify" "$CONFIG" \
    && pass "step.deploy_verify step defined" \
    || fail "step.deploy_verify step missing"

# Test 8: deploy-rolling pipeline
grep -q "deploy-rolling:" "$CONFIG" \
    && pass "deploy-rolling pipeline defined" \
    || fail "deploy-rolling pipeline missing"

# Test 9: deploy-status pipeline
grep -q "deploy-status:" "$CONFIG" \
    && pass "deploy-status pipeline defined" \
    || fail "deploy-status pipeline missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
