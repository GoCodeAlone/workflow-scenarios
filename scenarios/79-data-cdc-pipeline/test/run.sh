#!/usr/bin/env bash
# Scenario 79 — Data CDC Pipeline
# Config-validation only: validates CDC pipeline modules, step types, and
# pipeline flow for change data capture from PostgreSQL via Bento to Kafka.
set -uo pipefail

SCENARIO="79-data-cdc-pipeline"
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

# Test 4: cdc.source module with provider: bento
grep -q "type: cdc.source" "$CONFIG" \
    && pass "cdc.source module defined" \
    || fail "cdc.source module missing"

grep -q "provider: bento" "$CONFIG" \
    && pass "cdc.source uses provider: bento" \
    || fail "cdc.source missing provider: bento"

grep -q "type: postgres" "$CONFIG" \
    && pass "cdc.source has postgres connection type" \
    || fail "cdc.source missing postgres connection type"

grep -q "publication:" "$CONFIG" \
    && pass "cdc.source has publication config" \
    || fail "cdc.source missing publication config"

grep -q "slotName:" "$CONFIG" \
    && pass "cdc.source has slotName config" \
    || fail "cdc.source missing slotName config"

# Test 5: data.tenancy module with schema_per_tenant
grep -q "type: data.tenancy" "$CONFIG" \
    && pass "data.tenancy module defined" \
    || fail "data.tenancy module missing"

grep -q "strategy: schema_per_tenant" "$CONFIG" \
    && pass "data.tenancy uses strategy: schema_per_tenant" \
    || fail "data.tenancy missing strategy: schema_per_tenant"

grep -q "schemaPrefix:" "$CONFIG" \
    && pass "data.tenancy has schemaPrefix config" \
    || fail "data.tenancy missing schemaPrefix config"

# Test 6: messaging.kafka module
grep -q "type: messaging.kafka" "$CONFIG" \
    && pass "messaging.kafka module defined" \
    || fail "messaging.kafka module missing"

grep -q "brokers:" "$CONFIG" \
    && pass "messaging.kafka has brokers config" \
    || fail "messaging.kafka missing brokers config"

grep -q "topic: cdc-events" "$CONFIG" \
    && pass "messaging.kafka configured with cdc-events topic" \
    || fail "messaging.kafka missing cdc-events topic"

# Test 7: all CDC step types present
grep -q "type: step.cdc_start" "$CONFIG" \
    && pass "step.cdc_start defined" \
    || fail "step.cdc_start missing"

grep -q "type: step.cdc_stop" "$CONFIG" \
    && pass "step.cdc_stop defined" \
    || fail "step.cdc_stop missing"

grep -q "type: step.cdc_status" "$CONFIG" \
    && pass "step.cdc_status defined" \
    || fail "step.cdc_status missing"

grep -q "type: step.cdc_snapshot" "$CONFIG" \
    && pass "step.cdc_snapshot defined" \
    || fail "step.cdc_snapshot missing"

grep -q "type: step.cdc_schema_history" "$CONFIG" \
    && pass "step.cdc_schema_history defined" \
    || fail "step.cdc_schema_history missing"

grep -q "type: step.tenant_provision" "$CONFIG" \
    && pass "step.tenant_provision defined" \
    || fail "step.tenant_provision missing"

# Test 8: pipeline names
grep -q "cdc_monitor:" "$CONFIG" \
    && pass "cdc_monitor pipeline defined" \
    || fail "cdc_monitor pipeline missing"

grep -q "tenant_onboard:" "$CONFIG" \
    && pass "tenant_onboard pipeline defined" \
    || fail "tenant_onboard pipeline missing"

grep -q "cdc_snapshot:" "$CONFIG" \
    && pass "cdc_snapshot pipeline defined" \
    || fail "cdc_snapshot pipeline missing"

grep -q "cdc_control:" "$CONFIG" \
    && pass "cdc_control pipeline defined" \
    || fail "cdc_control pipeline missing"

# Test 9: step ordering — cdc_monitor must have cdc_status before cdc_schema_history
MONITOR_STATUS_LINE=$(grep -n "type: step.cdc_status" "$CONFIG" | head -1 | cut -d: -f1)
MONITOR_HISTORY_LINE=$(grep -n "type: step.cdc_schema_history" "$CONFIG" | head -1 | cut -d: -f1)
if [ -n "$MONITOR_STATUS_LINE" ] && [ -n "$MONITOR_HISTORY_LINE" ]; then
    [ "$MONITOR_STATUS_LINE" -lt "$MONITOR_HISTORY_LINE" ] \
        && pass "cdc_monitor: cdc_status precedes cdc_schema_history" \
        || fail "cdc_monitor: cdc_status must come before cdc_schema_history"
else
    fail "cdc_monitor: cannot verify step ordering (steps not found)"
fi

# Test 10: tenant_onboard — tenant_provision before cdc_start
PROVISION_LINE=$(grep -n "type: step.tenant_provision" "$CONFIG" | head -1 | cut -d: -f1)
CDC_START_LINE=$(grep -n "type: step.cdc_start" "$CONFIG" | head -1 | cut -d: -f1)
if [ -n "$PROVISION_LINE" ] && [ -n "$CDC_START_LINE" ]; then
    [ "$PROVISION_LINE" -lt "$CDC_START_LINE" ] \
        && pass "tenant_onboard: tenant_provision precedes cdc_start" \
        || fail "tenant_onboard: tenant_provision must come before cdc_start"
else
    fail "tenant_onboard: cannot verify step ordering"
fi

# Test 11: expr syntax used (not Go templates)
if grep -q '{{' "$CONFIG"; then
    fail "config uses Go template syntax {{ }} — must use expr syntax \${ }"
else
    pass "config uses expr syntax \${ } (no Go templates)"
fi

# Test 12: module references in steps match declared module names
grep -q "source: pg-cdc" "$CONFIG" \
    && pass "CDC steps reference module by name pg-cdc" \
    || fail "CDC steps missing source: pg-cdc reference"

grep -q "registry: tenant-registry" "$CONFIG" \
    && pass "tenant_provision step references tenant-registry module" \
    || fail "tenant_provision step missing registry: tenant-registry reference"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
