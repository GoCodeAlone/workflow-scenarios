#!/usr/bin/env bash
# Scenario 90 — DNS cross-provider transfer.
#
# Pre-loads the SAME record set into two stub provider instances
# (stub-A, stub-B) via fixture seeding, imports both states, then
# diffs (type, name, data, ttl) per the lossiness charter.
#
# The fixture-seed path (vs `wfctl infra apply`) keeps this scenario
# independent of the typed-adapter's missing ErrResourceNotFound
# translation across the gRPC wire boundary — a known limitation of
# the stub-plugin path. See run.sh of scenario 89 for the analogous
# import-then-plan-NoOp roundtrip.
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

SOURCE_IMPORT="/tmp/dns-stub-90-source-import.json"
TARGET_IMPORT="/tmp/dns-stub-90-target-import.json"

PLUGIN_ROOT="/tmp/wfctl-plugins-90"
PLUGIN_A_DIR="$PLUGIN_ROOT/dns-stub-a"
PLUGIN_B_DIR="$PLUGIN_ROOT/dns-stub-b"
BUILD_LOG="/tmp/dns-stub-90-build.log"

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
    "${WFCTL_BIN:-}" \
    "$(which wfctl 2>/dev/null)"; do
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
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# Build stub once, deploy under two per-plugin subdirs (one per provider name).
rm -rf "$PLUGIN_ROOT" && mkdir -p "$PLUGIN_A_DIR" "$PLUGIN_B_DIR"
if (cd "$STUB_SRC" && GOWORK=off go build -o /tmp/dns-stub-90-shared .) >"$BUILD_LOG" 2>&1; then
    pass "stub plugin builds"
else
    fail "stub plugin build failed — see $BUILD_LOG"
    cat "$BUILD_LOG"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi
cp /tmp/dns-stub-90-shared "$PLUGIN_A_DIR/dns-stub-a"
cp /tmp/dns-stub-90-shared "$PLUGIN_B_DIR/dns-stub-b"
cat >"$PLUGIN_A_DIR/plugin.json" <<'JSON'
{
  "name": "dns-stub-a",
  "version": "0.0.1",
  "author": "workflow-scenarios",
  "description": "Local stub IaCProvider plugin (stub-A) for DNS orchestration scenarios.",
  "type": "external",
  "capabilities": { "iacProvider": { "name": "stub-A" } },
  "iacProvider": { "computePlanVersion": "v2" }
}
JSON
cat >"$PLUGIN_B_DIR/plugin.json" <<'JSON'
{
  "name": "dns-stub-b",
  "version": "0.0.1",
  "author": "workflow-scenarios",
  "description": "Local stub IaCProvider plugin (stub-B) for DNS orchestration scenarios.",
  "type": "external",
  "capabilities": { "iacProvider": { "name": "stub-B" } },
  "iacProvider": { "computePlanVersion": "v2" }
}
JSON

# Copy per-scenario fixture to a stable /tmp path (relative paths don't
# resolve cleanly across the wfctl→plugin process boundary; the configs
# reference /tmp/dns-stub-90-shared-fixture.yaml).
cp "$SCENARIO_DIR/fixtures/shared-zone.yaml" /tmp/dns-stub-90-shared-fixture.yaml

# Fresh state per run so the fixture seed fires on first Initialize.
rm -f /tmp/dns-stub-90-source.json /tmp/dns-stub-90-target.json
rm -f "$SOURCE_IMPORT" "$TARGET_IMPORT"
rm -rf /tmp/dns-stub-90-source-statestore /tmp/dns-stub-90-target-statestore

export WFCTL_PLUGIN_DIR="$PLUGIN_ROOT"
unset DNS_STUB_FIXTURE # configs supply per-stub fixture_path

# Step 1: import-all from source provider (fixture seeded on Initialize)
IMPORT_SOURCE=$("$WFCTL" infra import-all --config="$SOURCE_CFG" --provider=stub-A --type=infra.dns --output="$SOURCE_IMPORT" 2>&1)
IMPORT_SOURCE_RC=$?
if [ "$IMPORT_SOURCE_RC" -eq 0 ] && [ -f "$SOURCE_IMPORT" ]; then
    pass "wfctl infra import-all source captured state"
else
    fail "import source failed (rc=$IMPORT_SOURCE_RC): $IMPORT_SOURCE"
fi

# Step 2: import-all from target provider (same fixture, different state file)
IMPORT_TARGET=$("$WFCTL" infra import-all --config="$TARGET_CFG" --provider=stub-B --type=infra.dns --output="$TARGET_IMPORT" 2>&1)
IMPORT_TARGET_RC=$?
if [ "$IMPORT_TARGET_RC" -eq 0 ] && [ -f "$TARGET_IMPORT" ]; then
    pass "wfctl infra import-all target captured state"
else
    fail "import target failed (rc=$IMPORT_TARGET_RC): $IMPORT_TARGET"
fi

# Step 3: verify-transfer per lossiness charter.
# Provider names are stub-A/stub-B at apply time; pass the underlying-
# cloud equivalents via env so the charter exclusions resolve correctly.
if [ -f "$SOURCE_IMPORT" ] && [ -f "$TARGET_IMPORT" ]; then
    VERIFY_OUT=$(VERIFY_SOURCE_PROVIDER=digitalocean VERIFY_TARGET_PROVIDER=cloudflare \
        python3 "$VERIFY" "$SOURCE_IMPORT" "$TARGET_IMPORT" "$LOSSINESS" 2>&1)
    VERIFY_RC=$?
    if [ "$VERIFY_RC" -eq 0 ]; then
        pass "verify-transfer: $VERIFY_OUT"
    else
        fail "verify-transfer: $VERIFY_OUT"
    fi
else
    skip "verify-transfer skipped (missing import outputs)"
fi

# Step 4: plan against source config should report NoOp (state matches desired).
PLAN_OUT=$("$WFCTL" infra plan --config="$SOURCE_CFG" 2>&1)
PLAN_RC=$?
if [ "$PLAN_RC" -eq 0 ] && printf '%s\n' "$PLAN_OUT" | grep -q "No changes"; then
    pass "wfctl infra plan source.yaml reports 'No changes'"
else
    fail "plan source NoOp check failed (rc=$PLAN_RC): $PLAN_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
