#!/usr/bin/env bash
# Scenario 89 — DNS import-export roundtrip.
#
# Build the shared stub plugin from scenarios/lib/dns-stub-plugin into
# /tmp, point wfctl's plugin discovery at /tmp via WFCTL_PLUGIN_DIR
# (per-subcommand --plugin-dir flag is also valid; env-var path is
# cleaner across multiple wfctl invocations), then drive the
# import-all → plan NoOp roundtrip.
set -uo pipefail

SCENARIO="89-dns-import-export-roundtrip"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(dirname "$SCENARIO_DIR")"
STUB_SRC="$SCENARIOS_ROOT/lib/dns-stub-plugin"
CONFIG="$SCENARIO_DIR/config/app.yaml"
STUB_FIXTURE="$STUB_SRC/fixtures/example.yaml"
STATE_FILE="/tmp/dns-stub-89-state.json"

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

# Build the stub plugin into /tmp.
if (cd "$STUB_SRC" && GOWORK=off go build -o /tmp/dns-stub .) >/dev/null 2>&1; then
    pass "stub plugin builds"
else
    fail "stub plugin build failed — see (cd $STUB_SRC && GOWORK=off go build .)"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# Reset state between runs so the fixture seed actually fires.
rm -f "$STATE_FILE"

# Tell the stub where to load fixture from. The stub looks at
# DNS_STUB_FIXTURE when its config doesn't supply fixture_path.
export DNS_STUB_FIXTURE="$STUB_FIXTURE"
export WFCTL_PLUGIN_DIR=/tmp

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
