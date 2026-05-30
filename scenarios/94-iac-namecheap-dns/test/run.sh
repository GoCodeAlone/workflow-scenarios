#!/usr/bin/env bash
# Scenario 94 — IaC Namecheap DNS
# Config-validation only — no live Namecheap API.
set -uo pipefail

SCENARIO="94-iac-namecheap-dns"
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
    skip "wfctl binary not found — config validation skipped"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

echo "Using wfctl: $WFCTL"

[ -f "$CONFIG" ] && pass "config/app.yaml exists" || { fail "config/app.yaml missing"; exit 1; }

python3 -c "import yaml; yaml.safe_load(open('$CONFIG'))" 2>/dev/null \
    && pass "config/app.yaml is valid YAML" \
    || fail "config/app.yaml YAML syntax error"

OUTPUT=$("$WFCTL" validate --skip-unknown-types "$CONFIG" 2>&1)
[ "$?" -eq 0 ] && pass "wfctl validate passes" || fail "wfctl validate: $OUTPUT"

grep -q "type: iac.provider.namecheap" "$CONFIG" \
    && pass "iac.provider.namecheap module defined" \
    || fail "iac.provider.namecheap missing"

grep -q "type: infra.dns" "$CONFIG" \
    && pass "infra.dns resource defined" \
    || fail "infra.dns missing"

grep -q "domain: gocodealone.tech" "$CONFIG" \
    && pass "DNS zone gocodealone.tech declared" \
    || fail "DNS zone missing"

grep -q "type: A" "$CONFIG" && pass "A record declared" || fail "A record missing"
grep -q "type: CNAME" "$CONFIG" && pass "CNAME record declared" || fail "CNAME missing"
grep -q "type: TXT" "$CONFIG" && pass "TXT record declared" || fail "TXT missing"

grep -q "type: step.iac_plan" "$CONFIG" && pass "iac_plan step" || fail "iac_plan missing"
grep -q "type: step.iac_apply" "$CONFIG" && pass "iac_apply step" || fail "iac_apply missing"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
