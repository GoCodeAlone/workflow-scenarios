#!/usr/bin/env bash
# Scenario 96 — IaC Dynamic DNS Multi-Provider
set -uo pipefail

SCENARIO="96-iac-dyndns-multiprovider"
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

WFCTL=""
for candidate in "$(which wfctl 2>/dev/null)" "$WORKFLOW_REPO/bin/wfctl" "${WFCTL_BIN:-}"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        WFCTL="$candidate"
        break
    fi
done

if [ -z "$WFCTL" ]; then
    skip "wfctl binary not found"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

echo "Using wfctl: $WFCTL"

[ -f "$CONFIG" ] && pass "config exists" || { fail "config missing"; exit 1; }
python3 -c "import yaml; yaml.safe_load(open('$CONFIG'))" 2>/dev/null && pass "YAML parses" || fail "YAML invalid"
OUTPUT=$("$WFCTL" validate --skip-unknown-types "$CONFIG" 2>&1)
[ "$?" -eq 0 ] && pass "wfctl validate" || fail "wfctl validate: $OUTPUT"

# Three dyndns instances, one per provider.
COUNT=$(grep -c "type: infra.dyndns" "$CONFIG")
[ "$COUNT" -eq 3 ] && pass "3 infra.dyndns modules" || fail "expected 3 dyndns modules; got $COUNT"

grep -q "provider: do-provider" "$CONFIG" && pass "DO dyndns wired" || fail "DO dyndns missing"
grep -q "provider: namecheap" "$CONFIG" && pass "Namecheap dyndns wired" || fail "Namecheap dyndns missing"
grep -q "provider: hover" "$CONFIG" && pass "Hover dyndns wired" || fail "Hover dyndns missing"

grep -q "icanhazip" "$CONFIG" && pass "icanhazip detector configured" || fail "icanhazip missing"
grep -q "ifconfig.me" "$CONFIG" && pass "ifconfig.me detector configured" || fail "ifconfig.me missing"
grep -q "ipify" "$CONFIG" && pass "ipify detector configured" || fail "ipify missing"

grep -q "quorum: 2" "$CONFIG" && pass "quorum configured" || fail "quorum missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
