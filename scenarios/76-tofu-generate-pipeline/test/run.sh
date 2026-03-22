#!/usr/bin/env bash
# Scenario 76 — Tofu Generate Pipeline (Multi-Cloud)
# Config-validation only: validates HCL generation for aws, gcp, azure, digitalocean.
# Tests that one tofu.generator per provider is defined and that step.iac_generate_hcl
# steps reference the correct generator modules.
set -uo pipefail

SCENARIO="76-tofu-generate-pipeline"
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

# Test 4: 4 tofu.generator modules (one per provider)
TOFU_COUNT=$(grep -c "type: tofu.generator" "$CONFIG" || echo "0")
[ "$TOFU_COUNT" -ge 4 ] \
    && pass "4 tofu.generator modules defined ($TOFU_COUNT found)" \
    || fail "expected 4 tofu.generator modules (found $TOFU_COUNT)"

# Test 5: per-provider source references
grep -q "hashicorp/aws" "$CONFIG" \
    && pass "AWS provider source (hashicorp/aws) defined" \
    || fail "AWS provider source (hashicorp/aws) missing"

grep -q "hashicorp/google" "$CONFIG" \
    && pass "GCP provider source (hashicorp/google) defined" \
    || fail "GCP provider source (hashicorp/google) missing"

grep -q "hashicorp/azurerm" "$CONFIG" \
    && pass "Azure provider source (hashicorp/azurerm) defined" \
    || fail "Azure provider source (hashicorp/azurerm) missing"

grep -q "digitalocean/digitalocean" "$CONFIG" \
    && pass "DigitalOcean provider source (digitalocean/digitalocean) defined" \
    || fail "DigitalOcean provider source (digitalocean/digitalocean) missing"

# Test 6: 4 iac.provider modules
IAC_PROVIDER_COUNT=$(grep -c "type: iac.provider" "$CONFIG" || echo "0")
[ "$IAC_PROVIDER_COUNT" -ge 4 ] \
    && pass "4 iac.provider modules defined ($IAC_PROVIDER_COUNT found)" \
    || fail "expected 4 iac.provider modules (found $IAC_PROVIDER_COUNT)"

# Test 7: step.iac_generate_hcl steps
GENERATE_STEPS=$(grep -c "type: step.iac_generate_hcl" "$CONFIG" || echo "0")
[ "$GENERATE_STEPS" -ge 4 ] \
    && pass "at least 4 step.iac_generate_hcl steps defined ($GENERATE_STEPS found)" \
    || fail "expected at least 4 step.iac_generate_hcl steps (found $GENERATE_STEPS)"

# Test 8: per-cloud generate pipelines
grep -q "generate-aws:" "$CONFIG" \
    && pass "generate-aws pipeline defined" \
    || fail "generate-aws pipeline missing"

grep -q "generate-gcp:" "$CONFIG" \
    && pass "generate-gcp pipeline defined" \
    || fail "generate-gcp pipeline missing"

grep -q "generate-azure:" "$CONFIG" \
    && pass "generate-azure pipeline defined" \
    || fail "generate-azure pipeline missing"

grep -q "generate-do:" "$CONFIG" \
    && pass "generate-do pipeline defined" \
    || fail "generate-do pipeline missing"

# Test 9: generate-all pipeline
grep -q "generate-all:" "$CONFIG" \
    && pass "generate-all pipeline defined" \
    || fail "generate-all pipeline missing"

# Test 10: per-provider output directories
grep -q "outputDir: /tmp/tofu-output/aws" "$CONFIG" \
    && pass "AWS tofu outputDir configured" \
    || fail "AWS tofu outputDir missing"

grep -q "outputDir: /tmp/tofu-output/gcp" "$CONFIG" \
    && pass "GCP tofu outputDir configured" \
    || fail "GCP tofu outputDir missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
