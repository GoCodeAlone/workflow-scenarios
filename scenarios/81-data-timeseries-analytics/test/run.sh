#!/usr/bin/env bash
# Scenario 81 — Data Time-Series Analytics
# Config-validation only: validates time-series analytics pipeline with
# InfluxDB, ClickHouse, Druid, and anomaly detection.
set -uo pipefail

SCENARIO="81-data-timeseries-analytics"
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

# Test 4: timeseries.influxdb module
grep -q "type: timeseries.influxdb" "$CONFIG" \
    && pass "timeseries.influxdb module defined" \
    || fail "timeseries.influxdb module missing"

grep -q "url: http://influxdb" "$CONFIG" \
    && pass "timeseries.influxdb has url config" \
    || fail "timeseries.influxdb missing url config"

grep -q "org:" "$CONFIG" \
    && pass "timeseries.influxdb has org config" \
    || fail "timeseries.influxdb missing org config"

grep -q "bucket:" "$CONFIG" \
    && pass "timeseries.influxdb has bucket config" \
    || fail "timeseries.influxdb missing bucket config"

# Test 5: timeseries.clickhouse module
grep -q "type: timeseries.clickhouse" "$CONFIG" \
    && pass "timeseries.clickhouse module defined" \
    || fail "timeseries.clickhouse module missing"

grep -q "endpoints:" "$CONFIG" \
    && pass "timeseries.clickhouse has endpoints config" \
    || fail "timeseries.clickhouse missing endpoints config"

grep -q "database: metrics" "$CONFIG" \
    && pass "timeseries.clickhouse has database: metrics" \
    || fail "timeseries.clickhouse missing database: metrics"

grep -q "ttlDays:" "$CONFIG" \
    && pass "timeseries.clickhouse has ttlDays retention config" \
    || fail "timeseries.clickhouse missing ttlDays config"

# Test 6: timeseries.druid module
grep -q "type: timeseries.druid" "$CONFIG" \
    && pass "timeseries.druid module defined" \
    || fail "timeseries.druid module missing"

grep -q "coordinatorUrl:" "$CONFIG" \
    && pass "timeseries.druid has coordinatorUrl config" \
    || fail "timeseries.druid missing coordinatorUrl config"

grep -q "brokerUrl:" "$CONFIG" \
    && pass "timeseries.druid has brokerUrl config" \
    || fail "timeseries.druid missing brokerUrl config"

grep -q "overlordUrl:" "$CONFIG" \
    && pass "timeseries.druid has overlordUrl config" \
    || fail "timeseries.druid missing overlordUrl config"

# Test 7: quality.checks module with anomaly detection
grep -q "type: quality.checks" "$CONFIG" \
    && pass "quality.checks module defined" \
    || fail "quality.checks module missing"

grep -q "type: zscore" "$CONFIG" \
    && pass "quality.checks has zscore anomaly check type" \
    || fail "quality.checks missing zscore check type"

grep -q "threshold: 3.0" "$CONFIG" \
    && pass "quality.checks zscore threshold is 3.0" \
    || fail "quality.checks missing threshold: 3.0"

grep -q "windowSize:" "$CONFIG" \
    && pass "quality.checks has windowSize config" \
    || fail "quality.checks missing windowSize config"

# Test 8: all time-series step types present
grep -q "type: step.ts_write" "$CONFIG" \
    && pass "step.ts_write defined" \
    || fail "step.ts_write missing"

grep -q "type: step.ts_write_batch" "$CONFIG" \
    && pass "step.ts_write_batch defined" \
    || fail "step.ts_write_batch missing"

grep -q "type: step.ts_query" "$CONFIG" \
    && pass "step.ts_query defined" \
    || fail "step.ts_query missing"

grep -q "type: step.ts_downsample" "$CONFIG" \
    && pass "step.ts_downsample defined" \
    || fail "step.ts_downsample missing"

grep -q "type: step.ts_retention" "$CONFIG" \
    && pass "step.ts_retention defined" \
    || fail "step.ts_retention missing"

grep -q "type: step.ts_druid_ingest" "$CONFIG" \
    && pass "step.ts_druid_ingest defined" \
    || fail "step.ts_druid_ingest missing"

grep -q "type: step.ts_druid_query" "$CONFIG" \
    && pass "step.ts_druid_query defined" \
    || fail "step.ts_druid_query missing"

grep -q "type: step.quality_anomaly" "$CONFIG" \
    && pass "step.quality_anomaly defined" \
    || fail "step.quality_anomaly missing"

# Test 9: pipeline names
grep -q "ingest_metrics:" "$CONFIG" \
    && pass "ingest_metrics pipeline defined" \
    || fail "ingest_metrics pipeline missing"

grep -q "downsample_hourly:" "$CONFIG" \
    && pass "downsample_hourly pipeline defined" \
    || fail "downsample_hourly pipeline missing"

grep -q "anomaly_scan:" "$CONFIG" \
    && pass "anomaly_scan pipeline defined" \
    || fail "anomaly_scan pipeline missing"

grep -q "druid_ingest:" "$CONFIG" \
    && pass "druid_ingest pipeline defined" \
    || fail "druid_ingest pipeline missing"

# Test 10: scheduler pipelines have cron config
DOWNSAMPLE_CRON=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('$CONFIG'))
p = cfg.get('pipelines', {}).get('downsample_hourly', {})
print(p.get('trigger', {}).get('config', {}).get('cron', ''))
" 2>/dev/null)
[ -n "$DOWNSAMPLE_CRON" ] \
    && pass "downsample_hourly has cron schedule: $DOWNSAMPLE_CRON" \
    || fail "downsample_hourly missing cron schedule"

ANOMALY_CRON=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('$CONFIG'))
p = cfg.get('pipelines', {}).get('anomaly_scan', {})
print(p.get('trigger', {}).get('config', {}).get('cron', ''))
" 2>/dev/null)
[ -n "$ANOMALY_CRON" ] \
    && pass "anomaly_scan has cron schedule: $ANOMALY_CRON" \
    || fail "anomaly_scan missing cron schedule"

# Test 11: anomaly scan — ts_query before quality_anomaly
TS_QUERY_LINE=$(grep -n "type: step.ts_query" "$CONFIG" | head -1 | cut -d: -f1)
ANOMALY_LINE=$(grep -n "type: step.quality_anomaly" "$CONFIG" | head -1 | cut -d: -f1)
if [ -n "$TS_QUERY_LINE" ] && [ -n "$ANOMALY_LINE" ]; then
    [ "$TS_QUERY_LINE" -lt "$ANOMALY_LINE" ] \
        && pass "anomaly_scan: ts_query precedes quality_anomaly" \
        || fail "anomaly_scan: ts_query must come before quality_anomaly"
else
    fail "anomaly_scan: cannot verify step ordering"
fi

# Test 12: Druid ingest has Kafka supervisor spec
grep -q "type: kafka" "$CONFIG" \
    && pass "druid_ingest has Kafka supervisor spec" \
    || fail "druid_ingest missing Kafka supervisor spec"

grep -q "segmentGranularity:" "$CONFIG" \
    && pass "druid_ingest has segmentGranularity config" \
    || fail "druid_ingest missing segmentGranularity config"

# Test 13: anomaly detection config has method + threshold
grep -q "method: zscore" "$CONFIG" \
    && pass "quality_anomaly step uses method: zscore" \
    || fail "quality_anomaly step missing method: zscore"

# Test 14: expr syntax used (not Go templates)
if grep -q '{{' "$CONFIG"; then
    fail "config uses Go template syntax {{ }} — must use expr syntax \${ }"
else
    pass "config uses expr syntax \${ } (no Go templates)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
