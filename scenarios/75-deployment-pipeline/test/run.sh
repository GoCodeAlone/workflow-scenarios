#!/usr/bin/env bash
# Scenario 75 — Deployment Pipeline
# Config-validation only: validates end-to-end CI/CD pipeline wiring.
# Tests that step.iac_plan → step.iac_apply → step.container_build →
# step.deploy_rolling → step.deploy_verify are all present in sequence.
set -uo pipefail

SCENARIO="75-deployment-pipeline"
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

# Test 4: infrastructure modules
grep -q "type: iac.provider" "$CONFIG" \
    && pass "iac.provider module defined" \
    || fail "iac.provider module missing"

grep -q "provider: digitalocean" "$CONFIG" \
    && pass "iac.provider uses provider: digitalocean" \
    || fail "iac.provider missing provider: digitalocean"

grep -q "type: iac.state" "$CONFIG" \
    && pass "iac.state module defined" \
    || fail "iac.state module missing"

grep -q "type: infra.registry" "$CONFIG" \
    && pass "infra.registry module defined" \
    || fail "infra.registry module missing"

grep -q "type: infra.container_service" "$CONFIG" \
    && pass "infra.container_service module defined" \
    || fail "infra.container_service module missing"

# Test 5: all pipeline steps in the deploy sequence
grep -q "type: step.iac_plan" "$CONFIG" \
    && pass "step.iac_plan defined" \
    || fail "step.iac_plan missing"

grep -q "type: step.iac_apply" "$CONFIG" \
    && pass "step.iac_apply defined" \
    || fail "step.iac_apply missing"

grep -q "type: step.container_build" "$CONFIG" \
    && pass "step.container_build defined" \
    || fail "step.container_build missing"

grep -q "type: step.deploy_rolling" "$CONFIG" \
    && pass "step.deploy_rolling defined" \
    || fail "step.deploy_rolling missing"

grep -q "type: step.deploy_verify" "$CONFIG" \
    && pass "step.deploy_verify defined" \
    || fail "step.deploy_verify missing"

# Test 6: container_build config
grep -q "registry: prod-registry" "$CONFIG" \
    && pass "container_build references prod-registry" \
    || fail "container_build registry reference missing"

grep -q "push: true" "$CONFIG" \
    && pass "container_build push: true configured" \
    || fail "container_build push: true missing"

# Test 7: deploy pipeline
grep -q "deploy-pipeline:" "$CONFIG" \
    && pass "deploy-pipeline pipeline defined" \
    || fail "deploy-pipeline pipeline missing"

# Test 8: rollback pipeline
grep -q "rollback-pipeline:" "$CONFIG" \
    && pass "rollback-pipeline pipeline defined" \
    || fail "rollback-pipeline pipeline missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
