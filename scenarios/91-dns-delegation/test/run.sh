#!/usr/bin/env bash
# Scenario 91 — DNS delegation across two providers.
#
# Pre-loads parent + child zone fixtures into stub-A and stub-B
# respectively, then imports each and asserts the delegation NS
# records survive the roundtrip via jq matchers on
# .applied_config.records[] (json tag from
# workflow/interfaces/iac_state.go:37).
#
# Uses fixture-seed (not `wfctl infra apply`) for the same reason as
# scenario 90 — see run.sh comment there.
set -uo pipefail

SCENARIO="91-dns-delegation"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(dirname "$SCENARIO_DIR")"
STUB_SRC="$SCENARIOS_ROOT/lib/dns-stub-plugin"

CONFIG="$SCENARIO_DIR/config/app.yaml"
PARENT_IMPORT="/tmp/dns-stub-91-parent-import.json"
CHILD_IMPORT="/tmp/dns-stub-91-child-import.json"

PLUGIN_ROOT="/tmp/wfctl-plugins-91"
PLUGIN_A_DIR="$PLUGIN_ROOT/dns-stub-a"
PLUGIN_B_DIR="$PLUGIN_ROOT/dns-stub-b"
BUILD_LOG="/tmp/dns-stub-91-build.log"

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

if ! command -v jq >/dev/null 2>&1; then
    skip "jq not installed — delegation roundtrip assertions skipped"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# Build stub once, deploy under two per-plugin subdirs (stub-A, stub-B).
rm -rf "$PLUGIN_ROOT" && mkdir -p "$PLUGIN_A_DIR" "$PLUGIN_B_DIR"
if (cd "$STUB_SRC" && GOWORK=off go build -o /tmp/dns-stub-91-shared .) >"$BUILD_LOG" 2>&1; then
    pass "stub plugin builds"
else
    fail "stub plugin build failed — see $BUILD_LOG"
    cat "$BUILD_LOG"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi
cp /tmp/dns-stub-91-shared "$PLUGIN_A_DIR/dns-stub-a"
cp /tmp/dns-stub-91-shared "$PLUGIN_B_DIR/dns-stub-b"
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

# Deploy per-stub fixtures to absolute paths.
cp "$SCENARIO_DIR/fixtures/parent-zone.yaml" /tmp/dns-stub-91-parent-fixture.yaml
cp "$SCENARIO_DIR/fixtures/child-zone.yaml" /tmp/dns-stub-91-child-fixture.yaml

# Fresh state per run so the fixture seed fires on first Initialize.
rm -f /tmp/dns-stub-91-parent.json /tmp/dns-stub-91-child.json
rm -f "$PARENT_IMPORT" "$CHILD_IMPORT"
rm -rf /tmp/dns-stub-91-statestore

export WFCTL_PLUGIN_DIR="$PLUGIN_ROOT"
unset DNS_STUB_FIXTURE

# Step 1: import parent provider state (stub-A; fixture pre-seeds NS rows)
IMPORT_PARENT=$("$WFCTL" infra import-all --config="$CONFIG" --provider=stub-A --type=infra.dns --output="$PARENT_IMPORT" 2>&1)
IMPORT_PARENT_RC=$?
if [ "$IMPORT_PARENT_RC" -eq 0 ] && [ -f "$PARENT_IMPORT" ]; then
    pass "wfctl infra import-all stub-A captured state"
else
    fail "import stub-A failed (rc=$IMPORT_PARENT_RC): $IMPORT_PARENT"
fi

# Step 2: import child provider state
IMPORT_CHILD=$("$WFCTL" infra import-all --config="$CONFIG" --provider=stub-B --type=infra.dns --output="$CHILD_IMPORT" 2>&1)
IMPORT_CHILD_RC=$?
if [ "$IMPORT_CHILD_RC" -eq 0 ] && [ -f "$CHILD_IMPORT" ]; then
    pass "wfctl infra import-all stub-B captured state"
else
    fail "import stub-B failed (rc=$IMPORT_CHILD_RC): $IMPORT_CHILD"
fi

# Step 3: parent state contains NS delegation records for child.example.test.
# Use `..` recursive descent so this assertion survives a "resources":[...]
# wrapping vs a flat top-level list across wfctl output shapes.
if [ -f "$PARENT_IMPORT" ]; then
    NS_FOUND=$(jq -r '
        [.. | objects | select(.applied_config?) | .applied_config.records?[]? | select(.type=="NS" and .name=="child.example.test") | .data]
        | length' "$PARENT_IMPORT")
    if [ "$NS_FOUND" -ge 2 ]; then
        pass "parent state has ≥2 NS records for child.example.test"
    else
        fail "parent state: expected ≥2 NS delegation records; got $NS_FOUND"
    fi
fi

# Step 4: child state has ≥2 records on its zone.
if [ -f "$CHILD_IMPORT" ]; then
    CHILD_RECS=$(jq -r '
        [.. | objects | select(.applied_config?) | .applied_config.records?[]?]
        | length' "$CHILD_IMPORT")
    if [ "$CHILD_RECS" -ge 2 ]; then
        pass "child state has ≥2 records on child.example.test"
    else
        fail "child state: expected ≥2 records; got $CHILD_RECS"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
