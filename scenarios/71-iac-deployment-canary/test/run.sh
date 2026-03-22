#!/usr/bin/env bash
# Scenario 71 — IaC Deployment Canary
# Config-validation only: validates YAML syntax and canary deployment wiring.
# Tests that stable + canary container_service modules, step.deploy_canary
# with metric gates and stages, are correctly defined.
set -uo pipefail

SCENARIO="71-iac-deployment-canary"
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

# Test 4: iac.provider (gcp) and iac.state
grep -q "type: iac.provider" "$CONFIG" \
    && pass "iac.provider module defined" \
    || fail "iac.provider module missing"

grep -q "provider: gcp" "$CONFIG" \
    && pass "iac.provider uses provider: gcp" \
    || fail "iac.provider missing provider: gcp"

grep -q "type: iac.state" "$CONFIG" \
    && pass "iac.state module defined" \
    || fail "iac.state module missing"

# Test 5: stable and canary container_service modules
CONTAINER_COUNT=$(grep -c "type: infra.container_service" "$CONFIG" || echo "0")
[ "$CONTAINER_COUNT" -ge 2 ] \
    && pass "at least 2 infra.container_service modules (stable + canary) defined" \
    || fail "expected at least 2 infra.container_service modules (found $CONTAINER_COUNT)"

grep -q "name: app-stable" "$CONFIG" \
    && pass "stable service (app-stable) defined" \
    || fail "stable service (app-stable) missing"

grep -q "name: app-canary" "$CONFIG" \
    && pass "canary service (app-canary) defined" \
    || fail "canary service (app-canary) missing"

# Test 6: step.deploy_canary with required fields
grep -q "type: step.deploy_canary" "$CONFIG" \
    && pass "step.deploy_canary step defined" \
    || fail "step.deploy_canary step missing"

grep -q "stableService:" "$CONFIG" \
    && pass "step.deploy_canary stableService reference defined" \
    || fail "step.deploy_canary stableService reference missing"

grep -q "canaryService:" "$CONFIG" \
    && pass "step.deploy_canary canaryService reference defined" \
    || fail "step.deploy_canary canaryService reference missing"

# Test 7: stages with metric gates defined
grep -q "stages:" "$CONFIG" \
    && pass "canary stages defined" \
    || fail "canary stages missing"

grep -q "metricGates:" "$CONFIG" \
    && pass "canary metricGates defined" \
    || fail "canary metricGates missing"

grep -q "error_rate" "$CONFIG" \
    && pass "error_rate metric gate defined" \
    || fail "error_rate metric gate missing"

grep -q "p99_latency_ms" "$CONFIG" \
    && pass "p99_latency_ms metric gate defined" \
    || fail "p99_latency_ms metric gate missing"

# Test 8: step.deploy_verify
grep -q "type: step.deploy_verify" "$CONFIG" \
    && pass "step.deploy_verify step defined" \
    || fail "step.deploy_verify step missing"

# Test 9: promote and abort pipelines
grep -q "canary-promote:" "$CONFIG" \
    && pass "canary-promote pipeline defined" \
    || fail "canary-promote pipeline missing"

grep -q "canary-abort:" "$CONFIG" \
    && pass "canary-abort pipeline defined" \
    || fail "canary-abort pipeline missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
