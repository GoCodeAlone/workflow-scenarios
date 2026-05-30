#!/usr/bin/env bash
# Scenario 95 — IaC Hover DNS
# Config-validation only.
set -uo pipefail

SCENARIO="95-iac-hover-dns"
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

grep -q "type: iac.provider.hover" "$CONFIG" && pass "iac.provider.hover declared" || fail "iac.provider.hover missing"
grep -q "type: infra.dns" "$CONFIG" && pass "infra.dns declared" || fail "infra.dns missing"
grep -q 'totp_secret:' "$CONFIG" && pass "TOTP secret wired" || fail "TOTP secret missing"
grep -q "type: A" "$CONFIG" && pass "A record" || fail "A record missing"
grep -q "type: AAAA" "$CONFIG" && pass "AAAA record" || fail "AAAA missing"
grep -q "type: MX" "$CONFIG" && pass "MX record" || fail "MX missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
