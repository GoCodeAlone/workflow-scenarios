#!/usr/bin/env bash
# Scenario 74 — IaC Full Stack
# Config-validation only: validates all 13 infra.* module types in one config.
# Tests that vpc, database, cache, container_service, load_balancer, dns,
# registry, firewall, iam_role, storage, certificate, cdn, secret are all defined.
set -uo pipefail

SCENARIO="74-iac-full-stack"
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

grep -q "provider: aws" "$CONFIG" \
    && pass "iac.provider uses provider: aws" \
    || fail "iac.provider missing provider: aws"

grep -q "type: iac.state" "$CONFIG" \
    && pass "iac.state module defined" \
    || fail "iac.state module missing"

# Test 5: all 13 infra.* module types
for MODULE_TYPE in \
    infra.vpc \
    infra.database \
    infra.cache \
    infra.container_service \
    infra.load_balancer \
    infra.dns \
    infra.registry \
    infra.firewall \
    infra.iam_role \
    infra.storage \
    infra.certificate \
    infra.cdn \
    infra.secret; do
    grep -q "type: $MODULE_TYPE" "$CONFIG" \
        && pass "$MODULE_TYPE module defined" \
        || fail "$MODULE_TYPE module missing"
done

# Test 6: key config fields for critical modules
grep -q "multiAZ: true" "$CONFIG" \
    && pass "database multiAZ configured" \
    || fail "database multiAZ missing"

grep -q "engine: redis" "$CONFIG" \
    && pass "cache engine: redis defined" \
    || fail "cache engine: redis missing"

grep -q "launchType: fargate" "$CONFIG" \
    && pass "container_service launchType: fargate defined" \
    || fail "container_service launchType: fargate missing"

grep -q "validationMethod: dns" "$CONFIG" \
    && pass "certificate validationMethod: dns defined" \
    || fail "certificate validationMethod: dns missing"

# Test 7: IaC lifecycle pipelines
grep -q "stack-plan:" "$CONFIG" \
    && pass "stack-plan pipeline defined" \
    || fail "stack-plan pipeline missing"

grep -q "stack-apply:" "$CONFIG" \
    && pass "stack-apply pipeline defined" \
    || fail "stack-apply pipeline missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
