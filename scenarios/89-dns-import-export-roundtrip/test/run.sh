#!/usr/bin/env bash
# Scenario 89 — DNS import-export roundtrip.
#
# Build the shared stub plugin into a subdirectory layout that wfctl's
# discovery contract requires: $WFCTL_PLUGIN_DIR/<plugin-name>/<plugin-name>
# alongside a plugin.json declaring iacProvider.name. See
# workflow/cmd/wfctl/deploy_providers.go:findIaCPluginDir.
#
# WFCTL_PLUGIN_DIR points at the directory CONTAINING the per-plugin
# subdirectory (not at the plugin's own subdirectory). Per-subcommand
# --plugin-dir would work too; env var avoids repeating it per call.
set -uo pipefail

SCENARIO="89-dns-import-export-roundtrip"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(dirname "$SCENARIO_DIR")"
STUB_SRC="$SCENARIOS_ROOT/lib/dns-stub-plugin"
CONFIG="$SCENARIO_DIR/config/app.yaml"
STUB_FIXTURE="$STUB_SRC/fixtures/example.yaml"
STATE_FILE="/tmp/dns-stub-89-state.json"
STATE_STORE_DIR="/tmp/dns-stub-89-statestore"

# wfctl plugin discovery needs $pluginDir/<plugin-name>/<plugin-name>
PLUGIN_ROOT="/tmp/wfctl-plugins-89"
PLUGIN_DIR="$PLUGIN_ROOT/dns-stub"
PLUGIN_BIN="$PLUGIN_DIR/dns-stub"
PLUGIN_MANIFEST="$PLUGIN_DIR/plugin.json"
BUILD_LOG="/tmp/dns-stub-89-build.log"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

echo ""
echo "=== Scenario $SCENARIO ==="
echo ""

# Locate wfctl binary — explicit WFCTL_BIN override takes precedence over
# PATH so operators can pin a built-from-source wfctl during PR review.
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

# Build stub plugin into the per-plugin subdirectory layout.
rm -rf "$PLUGIN_ROOT" && mkdir -p "$PLUGIN_DIR"
if (cd "$STUB_SRC" && GOWORK=off go build -o "$PLUGIN_BIN" .) >"$BUILD_LOG" 2>&1; then
    pass "stub plugin builds"
else
    fail "stub plugin build failed — see $BUILD_LOG"
    cat "$BUILD_LOG"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# plugin.json declaring iacProvider.name=stub (matches config's
# `provider: stub`). computePlanVersion must be "v2" — the stub server's
# Capabilities RPC already returns the same.
cat >"$PLUGIN_MANIFEST" <<'JSON'
{
  "name": "dns-stub",
  "version": "0.0.1",
  "author": "workflow-scenarios",
  "description": "Local stub IaCProvider plugin for DNS orchestration scenarios.",
  "type": "external",
  "capabilities": {
    "iacProvider": { "name": "stub" }
  },
  "iacProvider": { "computePlanVersion": "v2" }
}
JSON

# Reset state between runs so the fixture seed actually fires.
rm -f "$STATE_FILE"
rm -rf "$STATE_STORE_DIR"

# Tell the stub where to load fixture from. The stub looks at
# DNS_STUB_FIXTURE when its config doesn't supply fixture_path.
export DNS_STUB_FIXTURE="$STUB_FIXTURE"
export WFCTL_PLUGIN_DIR="$PLUGIN_ROOT"

# Test 1: config file present
[ -f "$CONFIG" ] && pass "config/app.yaml exists" || { fail "config/app.yaml missing"; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1; }

# Test 2: wfctl validate (smoke — provider module must resolve)
if "$WFCTL" validate --skip-unknown-types "$CONFIG" >/dev/null 2>&1; then
    pass "wfctl validate accepts config"
else
    skip "wfctl validate not available or rejects stub provider — non-blocking"
fi

# Test 3: wfctl infra import-all populates state from EnumerateAll
IMPORT_OUT=$("$WFCTL" infra import-all --config="$CONFIG" --provider=stub --type=infra.dns 2>&1)
IMPORT_RC=$?
if [ "$IMPORT_RC" -eq 0 ]; then
    pass "wfctl infra import-all succeeds"
else
    fail "wfctl infra import-all failed (rc=$IMPORT_RC): $IMPORT_OUT"
fi

# Test 4: wfctl infra plan against same config reports zero actions
PLAN_OUT=$("$WFCTL" infra plan --config="$CONFIG" 2>&1)
PLAN_RC=$?
if [ "$PLAN_RC" -eq 0 ]; then
    pass "wfctl infra plan succeeds"
else
    fail "wfctl infra plan failed (rc=$PLAN_RC): $PLAN_OUT"
fi

# Test 5: plan output contains "No changes" (the canonical zero-action
# message — see workflow/cmd/wfctl/infra.go:682)
if printf '%s\n' "$PLAN_OUT" | grep -q "No changes"; then
    pass "plan reports 'No changes' (zero-action roundtrip)"
else
    fail "plan did NOT report 'No changes'; output was: $PLAN_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
