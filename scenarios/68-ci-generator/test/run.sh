#!/usr/bin/env bash
# Scenario 68 — CI Generator
# Config-validation only: validates YAML syntax and ci.generator module wiring.
# Tests that both GitHub Actions and GitLab CI generator modules are defined
# with correct provider values and that generate/validate/diff steps are present.
set -uo pipefail

SCENARIO="68-ci-generator"
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

# Test 4: ci.generator modules for both providers
CI_GENERATOR_COUNT=$(grep -c "type: ci.generator" "$CONFIG" || echo "0")
[ "$CI_GENERATOR_COUNT" -ge 2 ] \
    && pass "at least 2 ci.generator modules defined ($CI_GENERATOR_COUNT found)" \
    || fail "expected at least 2 ci.generator modules (found $CI_GENERATOR_COUNT)"

grep -q "provider: github" "$CONFIG" \
    && pass "ci.generator with provider: github defined" \
    || fail "ci.generator missing provider: github"

grep -q "provider: gitlab" "$CONFIG" \
    && pass "ci.generator with provider: gitlab defined" \
    || fail "ci.generator missing provider: gitlab"

# Test 5: step.ci_generate steps
CI_GENERATE_STEPS=$(grep -c "type: step.ci_generate" "$CONFIG" || echo "0")
[ "$CI_GENERATE_STEPS" -ge 2 ] \
    && pass "at least 2 step.ci_generate steps defined ($CI_GENERATE_STEPS found)" \
    || fail "expected at least 2 step.ci_generate steps (found $CI_GENERATE_STEPS)"

# Test 6: GitHub Actions output file
grep -q '\.github/workflows/ci\.yml' "$CONFIG" \
    && pass "GitHub Actions output file .github/workflows/ci.yml referenced" \
    || fail "GitHub Actions output file reference missing"

# Test 7: GitLab CI output file
grep -q '\.gitlab-ci\.yml' "$CONFIG" \
    && pass "GitLab CI output file .gitlab-ci.yml referenced" \
    || fail "GitLab CI output file reference missing"

# Test 8: validate and diff steps
grep -q "type: step.ci_validate" "$CONFIG" \
    && pass "step.ci_validate step defined" \
    || fail "step.ci_validate step missing"

grep -q "type: step.ci_diff" "$CONFIG" \
    && pass "step.ci_diff step defined" \
    || fail "step.ci_diff step missing"

# Test 9: generator config has required fields
grep -q "defaultBranch:" "$CONFIG" \
    && pass "ci.generator defaultBranch configured" \
    || fail "ci.generator defaultBranch missing"

grep -q "goVersion:" "$CONFIG" \
    && pass "ci.generator goVersion configured" \
    || fail "ci.generator goVersion missing"

# Test 10: pipelines are present
grep -q "generate-github:" "$CONFIG" \
    && pass "generate-github pipeline defined" \
    || fail "generate-github pipeline missing"

grep -q "generate-gitlab:" "$CONFIG" \
    && pass "generate-gitlab pipeline defined" \
    || fail "generate-gitlab pipeline missing"

grep -q "validate-ci:" "$CONFIG" \
    && pass "validate-ci pipeline defined" \
    || fail "validate-ci pipeline missing"

grep -q "diff-ci:" "$CONFIG" \
    && pass "diff-ci pipeline defined" \
    || fail "diff-ci pipeline missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
