#!/usr/bin/env bash
# Scenario 65 — IaC AWS Basic
# Config-validation only: validates YAML syntax and module wiring via wfctl.
# No live cloud API calls, no k8s required.
set -uo pipefail

SCENARIO="65-iac-aws-basic"
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

# Test 4: iac.provider with provider: aws
grep -q "type: iac.provider" "$CONFIG" \
    && pass "iac.provider module defined" \
    || fail "iac.provider module missing"

grep -q "provider: aws" "$CONFIG" \
    && pass "iac.provider uses provider: aws" \
    || fail "iac.provider missing provider: aws"

# Test 5: iac.state backend: memory
grep -q "type: iac.state" "$CONFIG" \
    && pass "iac.state module defined" \
    || fail "iac.state module missing"

grep -q "backend: memory" "$CONFIG" \
    && pass "iac.state uses backend: memory" \
    || fail "iac.state missing backend: memory"

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

# Test 7: ECS Fargate config
grep -q "launchType: fargate" "$CONFIG" \
    && pass "container_service launchType is fargate" \
    || fail "container_service launchType not set to fargate"

# Test 8: RDS PostgreSQL 16
grep -q "engine: postgres" "$CONFIG" \
    && pass "database engine is postgres" \
    || fail "database engine not set to postgres"

grep -q 'version: "16"' "$CONFIG" \
    && pass "database version is 16" \
    || fail "database version not set to 16"

# Test 9: nginx:latest with 2 replicas
grep -q "image: nginx:latest" "$CONFIG" \
    && pass "container_service image is nginx:latest" \
    || fail "container_service image not set"

grep -q "replicas: 2" "$CONFIG" \
    && pass "container_service replicas: 2" \
    || fail "container_service replicas not set to 2"

# Test 10: IaC pipeline steps
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
