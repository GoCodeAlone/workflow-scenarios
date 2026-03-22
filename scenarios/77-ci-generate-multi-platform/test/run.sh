#!/usr/bin/env bash
# Scenario 77 — CI Generate Multi-Platform
# Config-validation only: validates GitHub Actions + GitLab CI generation
# in a single config. Tests coexistence of both ci.generator modules and
# that step.ci_generate, step.ci_validate, and step.ci_diff are present.
set -uo pipefail

SCENARIO="77-ci-generate-multi-platform"
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

# Test 4: both ci.generator modules
CI_GENERATOR_COUNT=$(grep -c "type: ci.generator" "$CONFIG" || echo "0")
[ "$CI_GENERATOR_COUNT" -ge 2 ] \
    && pass "2 ci.generator modules defined ($CI_GENERATOR_COUNT found)" \
    || fail "expected 2 ci.generator modules (found $CI_GENERATOR_COUNT)"

grep -q "provider: github" "$CONFIG" \
    && pass "ci.generator with provider: github defined" \
    || fail "ci.generator missing provider: github"

grep -q "provider: gitlab" "$CONFIG" \
    && pass "ci.generator with provider: gitlab defined" \
    || fail "ci.generator missing provider: gitlab"

# Test 5: generator config fields
grep -q "defaultBranch: main" "$CONFIG" \
    && pass "ci.generator defaultBranch: main configured" \
    || fail "ci.generator defaultBranch: main missing"

grep -q "goVersion:" "$CONFIG" \
    && pass "ci.generator goVersion configured" \
    || fail "ci.generator goVersion missing"

grep -q "runnerOS:" "$CONFIG" \
    && pass "github ci.generator runnerOS configured" \
    || fail "github ci.generator runnerOS missing"

# Test 6: step.ci_generate for both platforms
CI_GENERATE_COUNT=$(grep -c "type: step.ci_generate" "$CONFIG" || echo "0")
[ "$CI_GENERATE_COUNT" -ge 3 ] \
    && pass "at least 3 step.ci_generate steps defined ($CI_GENERATE_COUNT found)" \
    || fail "expected at least 3 step.ci_generate steps (found $CI_GENERATE_COUNT)"

# Test 7: output files
grep -q '\.github/workflows/ci\.yml' "$CONFIG" \
    && pass "GitHub Actions output file .github/workflows/ci.yml defined" \
    || fail "GitHub Actions output file reference missing"

grep -q '\.gitlab-ci\.yml' "$CONFIG" \
    && pass "GitLab CI output file .gitlab-ci.yml defined" \
    || fail "GitLab CI output file reference missing"

# Test 8: validate and diff steps
grep -q "type: step.ci_validate" "$CONFIG" \
    && pass "step.ci_validate step defined" \
    || fail "step.ci_validate step missing"

grep -q "type: step.ci_diff" "$CONFIG" \
    && pass "step.ci_diff step defined" \
    || fail "step.ci_diff step missing"

# Test 9: platform-specific pipelines
grep -q "generate-github:" "$CONFIG" \
    && pass "generate-github pipeline defined" \
    || fail "generate-github pipeline missing"

grep -q "generate-gitlab:" "$CONFIG" \
    && pass "generate-gitlab pipeline defined" \
    || fail "generate-gitlab pipeline missing"

grep -q "generate-all:" "$CONFIG" \
    && pass "generate-all pipeline defined" \
    || fail "generate-all pipeline missing"

grep -q "diff-ci:" "$CONFIG" \
    && pass "diff-ci pipeline defined" \
    || fail "diff-ci pipeline missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
