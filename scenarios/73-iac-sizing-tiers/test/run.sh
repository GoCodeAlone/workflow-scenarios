#!/usr/bin/env bash
# Scenario 73 — IaC Sizing Tiers
# Config-validation only: validates all 5 sizing tiers (xs/s/m/l/xl) for
# infra.database and infra.container_service, plus resource hint overrides.
set -uo pipefail

SCENARIO="73-iac-sizing-tiers"
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

# Test 5: infra.database at all 5 tiers
DB_COUNT=$(grep -c "type: infra.database" "$CONFIG" || echo "0")
[ "$DB_COUNT" -ge 5 ] \
    && pass "5 infra.database modules defined ($DB_COUNT found)" \
    || fail "expected 5 infra.database modules (found $DB_COUNT)"

# Test 6: infra.container_service at all 5 tiers
SVC_COUNT=$(grep -c "type: infra.container_service" "$CONFIG" || echo "0")
[ "$SVC_COUNT" -ge 5 ] \
    && pass "5 infra.container_service modules defined ($SVC_COUNT found)" \
    || fail "expected 5 infra.container_service modules (found $SVC_COUNT)"

# Test 7: all 5 size values present
for SIZE in xs s m l xl; do
    grep -q "size: $SIZE" "$CONFIG" \
        && pass "size: $SIZE defined" \
        || fail "size: $SIZE missing"
done

# Test 8: resource hint overrides (on xl tier)
grep -q "resources:" "$CONFIG" \
    && pass "resource hint overrides block defined" \
    || fail "resource hint overrides block missing"

grep -q "cpu:" "$CONFIG" \
    && pass "resource hint cpu override defined" \
    || fail "resource hint cpu override missing"

grep -q "memory:" "$CONFIG" \
    && pass "resource hint memory override defined" \
    || fail "resource hint memory override missing"

# Test 9: named tier modules (spot check)
grep -q "name: db-xs" "$CONFIG" \
    && pass "db-xs module defined" \
    || fail "db-xs module missing"

grep -q "name: db-xl" "$CONFIG" \
    && pass "db-xl module defined" \
    || fail "db-xl module missing"

grep -q "name: svc-xs" "$CONFIG" \
    && pass "svc-xs module defined" \
    || fail "svc-xs module missing"

grep -q "name: svc-xl" "$CONFIG" \
    && pass "svc-xl module defined" \
    || fail "svc-xl module missing"

# Test 10: plan-all pipeline
grep -q "plan-all:" "$CONFIG" \
    && pass "plan-all pipeline defined" \
    || fail "plan-all pipeline missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
