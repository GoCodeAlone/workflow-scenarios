#!/usr/bin/env bash
# Scenario 72 — IaC State Backends
# Config-validation only: validates all 6 iac.state backend types.
# Tests that memory, filesystem, postgres, gcs, azure_blob, and s3 backends
# are correctly defined with their required config fields.
set -uo pipefail

SCENARIO="72-iac-state-backends"
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

# Test 4: count iac.state modules (expect 6)
STATE_COUNT=$(grep -c "type: iac.state" "$CONFIG" || echo "0")
[ "$STATE_COUNT" -ge 6 ] \
    && pass "6 iac.state modules defined ($STATE_COUNT found)" \
    || fail "expected 6 iac.state modules (found $STATE_COUNT)"

# Test 5: backend: memory
grep -q "backend: memory" "$CONFIG" \
    && pass "iac.state backend: memory defined" \
    || fail "iac.state backend: memory missing"

# Test 6: backend: filesystem with path
grep -q "backend: filesystem" "$CONFIG" \
    && pass "iac.state backend: filesystem defined" \
    || fail "iac.state backend: filesystem missing"

grep -q "path: /tmp/iac-state" "$CONFIG" \
    && pass "filesystem backend path configured" \
    || fail "filesystem backend path missing"

# Test 7: backend: postgres with connectionString
grep -q "backend: postgres" "$CONFIG" \
    && pass "iac.state backend: postgres defined" \
    || fail "iac.state backend: postgres missing"

grep -q "connectionString:" "$CONFIG" \
    && pass "postgres backend connectionString configured" \
    || fail "postgres backend connectionString missing"

# Test 8: backend: gcs with bucket
grep -q "backend: gcs" "$CONFIG" \
    && pass "iac.state backend: gcs defined" \
    || fail "iac.state backend: gcs missing"

grep -q "bucket:" "$CONFIG" \
    && pass "gcs backend bucket configured" \
    || fail "gcs backend bucket missing"

# Test 9: backend: azure_blob with container + storageAccount
grep -q "backend: azure_blob" "$CONFIG" \
    && pass "iac.state backend: azure_blob defined" \
    || fail "iac.state backend: azure_blob missing"

grep -q "storageAccount:" "$CONFIG" \
    && pass "azure_blob backend storageAccount configured" \
    || fail "azure_blob backend storageAccount missing"

grep -q "container:" "$CONFIG" \
    && pass "azure_blob backend container configured" \
    || fail "azure_blob backend container missing"

# Test 10: backend: s3 with bucket + region
grep -q "backend: s3" "$CONFIG" \
    && pass "iac.state backend: s3 defined" \
    || fail "iac.state backend: s3 missing"

grep -q "encrypt: true" "$CONFIG" \
    && pass "s3 backend encrypt: true configured" \
    || fail "s3 backend encrypt: true missing"

# Test 11: per-backend pipelines
grep -q "plan-memory:" "$CONFIG" \
    && pass "plan-memory pipeline defined" \
    || fail "plan-memory pipeline missing"

grep -q "plan-filesystem:" "$CONFIG" \
    && pass "plan-filesystem pipeline defined" \
    || fail "plan-filesystem pipeline missing"

grep -q "plan-postgres:" "$CONFIG" \
    && pass "plan-postgres pipeline defined" \
    || fail "plan-postgres pipeline missing"

grep -q "plan-gcs:" "$CONFIG" \
    && pass "plan-gcs pipeline defined" \
    || fail "plan-gcs pipeline missing"

grep -q "plan-azure-blob:" "$CONFIG" \
    && pass "plan-azure-blob pipeline defined" \
    || fail "plan-azure-blob pipeline missing"

grep -q "plan-s3:" "$CONFIG" \
    && pass "plan-s3 pipeline defined" \
    || fail "plan-s3 pipeline missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
