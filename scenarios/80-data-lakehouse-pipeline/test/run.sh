#!/usr/bin/env bash
# Scenario 80 — Data Lakehouse Pipeline
# Config-validation only: validates lakehouse ingestion pipeline with Iceberg,
# quality checks, schema registry, and maintenance scheduling.
set -uo pipefail

SCENARIO="80-data-lakehouse-pipeline"
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

# Test 4: catalog.iceberg module
grep -q "type: catalog.iceberg" "$CONFIG" \
    && pass "catalog.iceberg module defined" \
    || fail "catalog.iceberg module missing"

grep -q "endpoint: http://iceberg-rest" "$CONFIG" \
    && pass "catalog.iceberg has REST endpoint" \
    || fail "catalog.iceberg missing REST endpoint"

grep -q "warehouse: s3://" "$CONFIG" \
    && pass "catalog.iceberg has S3 warehouse path" \
    || fail "catalog.iceberg missing warehouse path"

grep -q "namespace: analytics" "$CONFIG" \
    && pass "catalog.iceberg has namespace: analytics" \
    || fail "catalog.iceberg missing namespace: analytics"

# Test 5: lakehouse.table module
grep -q "type: lakehouse.table" "$CONFIG" \
    && pass "lakehouse.table module defined" \
    || fail "lakehouse.table module missing"

grep -q "catalog: iceberg-catalog" "$CONFIG" \
    && pass "lakehouse.table references iceberg-catalog" \
    || fail "lakehouse.table missing catalog: iceberg-catalog"

grep -q "writeFormat: parquet" "$CONFIG" \
    && pass "lakehouse.table uses writeFormat: parquet" \
    || fail "lakehouse.table missing writeFormat: parquet"

grep -q "partitionStrategy:" "$CONFIG" \
    && pass "lakehouse.table has partitionStrategy config" \
    || fail "lakehouse.table missing partitionStrategy config"

# Test 6: quality.checks module
grep -q "type: quality.checks" "$CONFIG" \
    && pass "quality.checks module defined" \
    || fail "quality.checks module missing"

grep -q "type: not_null" "$CONFIG" \
    && pass "quality.checks has not_null check type" \
    || fail "quality.checks missing not_null check type"

grep -q "type: freshness" "$CONFIG" \
    && pass "quality.checks has freshness check type" \
    || fail "quality.checks missing freshness check type"

grep -q "quarantineTable:" "$CONFIG" \
    && pass "quality.checks has quarantineTable config" \
    || fail "quality.checks missing quarantineTable config"

# Test 7: catalog.schema_registry module
grep -q "type: catalog.schema_registry" "$CONFIG" \
    && pass "catalog.schema_registry module defined" \
    || fail "catalog.schema_registry module missing"

grep -q "compatibility: BACKWARD_TRANSITIVE" "$CONFIG" \
    && pass "catalog.schema_registry uses BACKWARD_TRANSITIVE compatibility" \
    || fail "catalog.schema_registry missing compatibility config"

grep -q "endpoint: http://schema-registry" "$CONFIG" \
    && pass "catalog.schema_registry has endpoint config" \
    || fail "catalog.schema_registry missing endpoint config"

# Test 8: all lakehouse step types present
grep -q "type: step.lakehouse_create_table" "$CONFIG" \
    && pass "step.lakehouse_create_table defined" \
    || fail "step.lakehouse_create_table missing"

grep -q "type: step.lakehouse_evolve_schema" "$CONFIG" \
    && pass "step.lakehouse_evolve_schema defined" \
    || fail "step.lakehouse_evolve_schema missing"

grep -q "type: step.lakehouse_write" "$CONFIG" \
    && pass "step.lakehouse_write defined" \
    || fail "step.lakehouse_write missing"

grep -q "type: step.lakehouse_compact" "$CONFIG" \
    && pass "step.lakehouse_compact defined" \
    || fail "step.lakehouse_compact missing"

grep -q "type: step.lakehouse_expire_snapshots" "$CONFIG" \
    && pass "step.lakehouse_expire_snapshots defined" \
    || fail "step.lakehouse_expire_snapshots missing"

grep -q "type: step.lakehouse_query" "$CONFIG" \
    && pass "step.lakehouse_query defined" \
    || fail "step.lakehouse_query missing"

grep -q "type: step.quality_check" "$CONFIG" \
    && pass "step.quality_check defined" \
    || fail "step.quality_check missing"

grep -q "type: step.quality_profile" "$CONFIG" \
    && pass "step.quality_profile defined" \
    || fail "step.quality_profile missing"

grep -q "type: step.schema_register" "$CONFIG" \
    && pass "step.schema_register defined" \
    || fail "step.schema_register missing"

grep -q "type: step.schema_validate" "$CONFIG" \
    && pass "step.schema_validate defined" \
    || fail "step.schema_validate missing"

# Test 9: pipeline names
grep -q "ingest_to_lakehouse:" "$CONFIG" \
    && pass "ingest_to_lakehouse pipeline defined" \
    || fail "ingest_to_lakehouse pipeline missing"

grep -q "lakehouse_maintenance:" "$CONFIG" \
    && pass "lakehouse_maintenance pipeline defined" \
    || fail "lakehouse_maintenance pipeline missing"

grep -q "schema_evolution:" "$CONFIG" \
    && pass "schema_evolution pipeline defined" \
    || fail "schema_evolution pipeline missing"

# Test 10: maintenance pipeline has cron schedule
MAINT_CRON=$(python3 -c "
import yaml, sys
cfg = yaml.safe_load(open('$CONFIG'))
pipelines = cfg.get('pipelines', {})
p = pipelines.get('lakehouse_maintenance', {})
trig = p.get('trigger', {})
conf = trig.get('config', {})
print(conf.get('cron', ''))
" 2>/dev/null)
[ -n "$MAINT_CRON" ] \
    && pass "lakehouse_maintenance has cron schedule: $MAINT_CRON" \
    || fail "lakehouse_maintenance missing cron schedule"

MAINT_TRIGGER=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('$CONFIG'))
p = cfg.get('pipelines', {}).get('lakehouse_maintenance', {})
print(p.get('trigger', {}).get('type', ''))
" 2>/dev/null)
[ "$MAINT_TRIGGER" = "scheduler" ] \
    && pass "lakehouse_maintenance trigger type is scheduler" \
    || fail "lakehouse_maintenance trigger type must be scheduler (got: $MAINT_TRIGGER)"

# Test 11: ingest pipeline uses event trigger
INGEST_TRIGGER=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('$CONFIG'))
p = cfg.get('pipelines', {}).get('ingest_to_lakehouse', {})
print(p.get('trigger', {}).get('type', ''))
" 2>/dev/null)
[ "$INGEST_TRIGGER" = "event" ] \
    && pass "ingest_to_lakehouse trigger type is event" \
    || fail "ingest_to_lakehouse trigger type must be event (got: $INGEST_TRIGGER)"

# Test 12: ingest pipeline step ordering — quality_check → lakehouse_write → schema_register
QUALITY_LINE=$(grep -n "type: step.quality_check" "$CONFIG" | head -1 | cut -d: -f1)
WRITE_LINE=$(grep -n "type: step.lakehouse_write" "$CONFIG" | head -1 | cut -d: -f1)
SCHEMA_REG_LINE=$(grep -n "type: step.schema_register" "$CONFIG" | head -1 | cut -d: -f1)
if [ -n "$QUALITY_LINE" ] && [ -n "$WRITE_LINE" ] && [ -n "$SCHEMA_REG_LINE" ]; then
    if [ "$QUALITY_LINE" -lt "$WRITE_LINE" ] && [ "$WRITE_LINE" -lt "$SCHEMA_REG_LINE" ]; then
        pass "ingest pipeline: quality_check → lakehouse_write → schema_register ordering correct"
    else
        fail "ingest pipeline: step ordering must be quality_check → lakehouse_write → schema_register"
    fi
else
    fail "ingest pipeline: cannot verify step ordering (steps not found)"
fi

# Test 13: maintenance pipeline — compact before expire_snapshots
COMPACT_LINE=$(grep -n "type: step.lakehouse_compact" "$CONFIG" | head -1 | cut -d: -f1)
EXPIRE_LINE=$(grep -n "type: step.lakehouse_expire_snapshots" "$CONFIG" | head -1 | cut -d: -f1)
if [ -n "$COMPACT_LINE" ] && [ -n "$EXPIRE_LINE" ]; then
    [ "$COMPACT_LINE" -lt "$EXPIRE_LINE" ] \
        && pass "maintenance: lakehouse_compact precedes lakehouse_expire_snapshots" \
        || fail "maintenance: compact must come before expire_snapshots"
else
    fail "maintenance: cannot verify compact/expire ordering"
fi

# Test 14: expr syntax used (not Go templates)
if grep -q '{{' "$CONFIG"; then
    fail "config uses Go template syntax {{ }} — must use expr syntax \${ }"
else
    pass "config uses expr syntax \${ } (no Go templates)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
