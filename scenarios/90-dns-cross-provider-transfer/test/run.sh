#!/usr/bin/env bash
# Scenario 90 — DNS cross-provider transfer.
#
# Apply the same record set via two stub provider modules (stub-A,
# stub-B), import both states, then diff (type, name, data, ttl) per
# the lossiness charter.
set -uo pipefail

SCENARIO="90-dns-cross-provider-transfer"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(dirname "$SCENARIO_DIR")"
STUB_SRC="$SCENARIOS_ROOT/lib/dns-stub-plugin"

SOURCE_CFG="$SCENARIO_DIR/config/source.yaml"
TARGET_CFG="$SCENARIO_DIR/config/target.yaml"
LOSSINESS="$SCENARIO_DIR/config/lossiness.yaml"
VERIFY="$SCRIPT_DIR/verify-transfer.py"

SOURCE_STATE_FILE="/tmp/dns-stub-90-source.json"
TARGET_STATE_FILE="/tmp/dns-stub-90-target.json"
SOURCE_IMPORT="/tmp/dns-stub-90-source-import.json"
TARGET_IMPORT="/tmp/dns-stub-90-target-import.json"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

echo ""
echo "=== Scenario $SCENARIO ==="
echo ""

WFCTL=""
for candidate in \
    "$(which wfctl 2>/dev/null)" \
    "${WFCTL_BIN:-}"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        WFCTL="$candidate"
        break
    fi
done
if [ -z "$WFCTL" ]; then
    skip "wfctl binary not found — scenario skipped (set WFCTL_BIN to override)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi
echo "Using wfctl: $WFCTL"

if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available — cross-provider parity check skipped"
fi

if (cd "$STUB_SRC" && GOWORK=off go build -o /tmp/dns-stub .) >/dev/null 2>&1; then
    pass "stub plugin builds"
else
    fail "stub plugin build failed"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# Fresh state per run.
rm -f "$SOURCE_STATE_FILE" "$TARGET_STATE_FILE" "$SOURCE_IMPORT" "$TARGET_IMPORT"

export WFCTL_PLUGIN_DIR=/tmp
unset DNS_STUB_FIXTURE # scenario 90 builds state via apply, not fixture seed

# Step 1: apply source → populate stub-A state
APPLY_SOURCE=$("$WFCTL" infra apply --config="$SOURCE_CFG" 2>&1)
APPLY_SOURCE_RC=$?
if [ "$APPLY_SOURCE_RC" -eq 0 ]; then
    pass "wfctl infra apply source.yaml succeeds"
else
    fail "apply source failed (rc=$APPLY_SOURCE_RC): $APPLY_SOURCE"
fi

# Step 2: import-all from source → capture state
IMPORT_SOURCE=$("$WFCTL" infra import-all --config="$SOURCE_CFG" --provider=stub-A --type=infra.dns --output="$SOURCE_IMPORT" 2>&1)
IMPORT_SOURCE_RC=$?
if [ "$IMPORT_SOURCE_RC" -eq 0 ] && [ -f "$SOURCE_IMPORT" ]; then
    pass "wfctl infra import-all source captured state"
else
    fail "import source failed (rc=$IMPORT_SOURCE_RC): $IMPORT_SOURCE"
fi

# Step 3: apply target → populate stub-B state
APPLY_TARGET=$("$WFCTL" infra apply --config="$TARGET_CFG" 2>&1)
APPLY_TARGET_RC=$?
if [ "$APPLY_TARGET_RC" -eq 0 ]; then
    pass "wfctl infra apply target.yaml succeeds"
else
    fail "apply target failed (rc=$APPLY_TARGET_RC): $APPLY_TARGET"
fi

# Step 4: import-all from target → capture state
IMPORT_TARGET=$("$WFCTL" infra import-all --config="$TARGET_CFG" --provider=stub-B --type=infra.dns --output="$TARGET_IMPORT" 2>&1)
IMPORT_TARGET_RC=$?
if [ "$IMPORT_TARGET_RC" -eq 0 ] && [ -f "$TARGET_IMPORT" ]; then
    pass "wfctl infra import-all target captured state"
else
    fail "import target failed (rc=$IMPORT_TARGET_RC): $IMPORT_TARGET"
fi

# Step 5: verify-transfer per lossiness charter
if [ -f "$SOURCE_IMPORT" ] && [ -f "$TARGET_IMPORT" ] && command -v python3 >/dev/null 2>&1; then
    VERIFY_OUT=$(python3 "$VERIFY" "$SOURCE_IMPORT" "$TARGET_IMPORT" "$LOSSINESS" 2>&1)
    VERIFY_RC=$?
    if [ "$VERIFY_RC" -eq 0 ]; then
        pass "verify-transfer: $VERIFY_OUT"
    else
        fail "verify-transfer: $VERIFY_OUT"
    fi
else
    skip "verify-transfer skipped (missing inputs or python3)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
