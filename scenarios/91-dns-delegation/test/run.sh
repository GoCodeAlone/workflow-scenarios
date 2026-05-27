#!/usr/bin/env bash
# Scenario 91 — DNS delegation across two providers in a single apply.
#
# Apply parent + child zones via stub-A + stub-B respectively, then
# import each provider's state and assert via jq that:
#   - the parent state contains the NS delegation records pointing at
#     the child provider's nameservers
#   - the child state contains the per-zone records intact
#
# Uses .applied_config.records[] (json tag from
# workflow/interfaces/iac_state.go:37) NOT .config.records.
set -uo pipefail

SCENARIO="91-dns-delegation"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIOS_ROOT="$(dirname "$SCENARIO_DIR")"
STUB_SRC="$SCENARIOS_ROOT/lib/dns-stub-plugin"

CONFIG="$SCENARIO_DIR/config/app.yaml"
PARENT_STATE_FILE="/tmp/dns-stub-91-parent.json"
CHILD_STATE_FILE="/tmp/dns-stub-91-child.json"
PARENT_IMPORT="/tmp/dns-stub-91-parent-import.json"
CHILD_IMPORT="/tmp/dns-stub-91-child-import.json"

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

if ! command -v jq >/dev/null 2>&1; then
    skip "jq not installed — delegation roundtrip assertions skipped"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

if (cd "$STUB_SRC" && GOWORK=off go build -o /tmp/dns-stub .) >/dev/null 2>&1; then
    pass "stub plugin builds"
else
    fail "stub plugin build failed"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# Fresh per-provider state per run.
rm -f "$PARENT_STATE_FILE" "$CHILD_STATE_FILE" "$PARENT_IMPORT" "$CHILD_IMPORT"

export WFCTL_PLUGIN_DIR=/tmp
unset DNS_STUB_FIXTURE

# Step 1: single apply manages both providers
APPLY_OUT=$("$WFCTL" infra apply --config="$CONFIG" 2>&1)
APPLY_RC=$?
if [ "$APPLY_RC" -eq 0 ]; then
    pass "wfctl infra apply (parent + child zones) succeeds"
else
    fail "apply failed (rc=$APPLY_RC): $APPLY_OUT"
fi

# Step 2: import parent provider state
IMPORT_PARENT=$("$WFCTL" infra import-all --config="$CONFIG" --provider=stub-A --type=infra.dns --output="$PARENT_IMPORT" 2>&1)
IMPORT_PARENT_RC=$?
if [ "$IMPORT_PARENT_RC" -eq 0 ] && [ -f "$PARENT_IMPORT" ]; then
    pass "wfctl infra import-all stub-A captured state"
else
    fail "import stub-A failed (rc=$IMPORT_PARENT_RC): $IMPORT_PARENT"
fi

# Step 3: import child provider state
IMPORT_CHILD=$("$WFCTL" infra import-all --config="$CONFIG" --provider=stub-B --type=infra.dns --output="$CHILD_IMPORT" 2>&1)
IMPORT_CHILD_RC=$?
if [ "$IMPORT_CHILD_RC" -eq 0 ] && [ -f "$CHILD_IMPORT" ]; then
    pass "wfctl infra import-all stub-B captured state"
else
    fail "import stub-B failed (rc=$IMPORT_CHILD_RC): $IMPORT_CHILD"
fi

# Step 4: parent state contains NS delegation records for child.example.test
# Resource path varies by wfctl output shape; use `..` recursive descent so
# this assertion survives a "resources":[...] wrapping vs a flat top-level
# list — both shapes have been seen across wfctl versions.
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

# Step 5: child state has ≥2 records on its zone
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
