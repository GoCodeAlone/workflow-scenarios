#!/usr/bin/env bash
# Scenario 98 — CI generate smart (plan then generate).
#
# Drives wfctl ci plan + wfctl ci generate --from-plan and asserts the
# generated GitHub Actions YAML is structurally correct (secret env wiring,
# plugin install step, migration step, smoke test job).
#
# ADAPTATION NOTE: the generated migration step is
#   wfctl ci run --config '...' --phase migrate
# NOT "wfctl migrations up". The assertion matches the real binary output.
set -uo pipefail

SCENARIO="98-ci-generate-smart"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
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

# Locate wfctl binary.
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

# Per-run isolated tmp directory.
TMP_ROOT="$(mktemp -d /tmp/sc98-XXXXXX)"
export SC98_STORE_DIR="$TMP_ROOT/store"
export SC98_STATE_DIR="$TMP_ROOT/iac-state"
PLAN_FILE="$TMP_ROOT/plan.json"
OUT_DIR="$TMP_ROOT/out"
mkdir -p "$SC98_STORE_DIR" "$SC98_STATE_DIR" "$OUT_DIR"

echo "TMP_ROOT: $TMP_ROOT"
echo ""

set +e

# Test 1: config file present.
[ -f "$CONFIG" ] && pass "config/app.yaml exists" || { fail "config/app.yaml missing"; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1; }

# Test 2: wfctl validate passes.
VALIDATE_OUT=$("$WFCTL" validate --skip-unknown-types "$CONFIG" 2>&1)
VALIDATE_RC=$?
[ "$VALIDATE_RC" -eq 0 ] \
    && pass "wfctl validate --skip-unknown-types passes" \
    || fail "wfctl validate failed (rc=$VALIDATE_RC): $VALIDATE_OUT"

# Test 3: wfctl ci plan emits valid JSON with expected fields.
PLAN_OUT=$("$WFCTL" ci plan -c "$CONFIG" --out "$PLAN_FILE" 2>&1)
PLAN_RC=$?
[ "$PLAN_RC" -eq 0 ] \
    && pass "wfctl ci plan exits 0" \
    || fail "wfctl ci plan failed (rc=$PLAN_RC): $PLAN_OUT"

if [ -f "$PLAN_FILE" ]; then
    python3 -c 'import json,sys; json.load(sys.stdin)' < "$PLAN_FILE" 2>/dev/null \
        && pass "plan.json is valid JSON" \
        || fail "plan.json is not valid JSON"

    # Assert secrets array contains APP_DB_URL and APP_JWT.
    python3 - "$PLAN_FILE" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
secrets = {s['name'] for s in data.get('secrets', [])}
missing = {'APP_DB_URL', 'APP_JWT'} - secrets
if missing:
    print(f"FAIL: plan.secrets missing {missing}")
    sys.exit(1)
else:
    print("PASS: plan.secrets contains APP_DB_URL and APP_JWT")
PYEOF
    PY_RC=$?
    [ "$PY_RC" -eq 0 ] \
        && : \
        || fail "plan.secrets assertion script exited non-zero"

    # Assert warnings array is non-empty.
    python3 - "$PLAN_FILE" << 'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
warnings = data.get('warnings', [])
if not warnings:
    print("FAIL: plan.warnings is empty (expected at least one warning)")
    sys.exit(1)
else:
    print(f"PASS: plan.warnings has {len(warnings)} warning(s)")
PYEOF
else
    fail "plan.json was not written to $PLAN_FILE"
fi

# Test 4: wfctl ci generate --from-plan writes a .github/workflows/*.yml.
GEN_OUT=$("$WFCTL" ci generate \
    --from-plan "$PLAN_FILE" \
    --platform github_actions \
    --out "$OUT_DIR" \
    --write 2>&1)
GEN_RC=$?
[ "$GEN_RC" -eq 0 ] \
    && pass "wfctl ci generate --from-plan exits 0" \
    || fail "wfctl ci generate failed (rc=$GEN_RC): $GEN_OUT"

# Find the generated YAML file.
GEN_FILE=$(find "$OUT_DIR/.github/workflows" -name "*.yml" 2>/dev/null | head -1)
if [ -n "$GEN_FILE" ]; then
    pass "generated .github/workflows/*.yml file exists: $(basename "$GEN_FILE")"
else
    fail "no .github/workflows/*.yml file found under $OUT_DIR"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# Test 5: generated YAML parses as valid YAML.
python3 -c "
import sys, yaml
with open(sys.argv[1]) as f:
    yaml.safe_load(f)
print('PASS: generated YAML parses with yaml.safe_load')
" "$GEN_FILE" 2>/dev/null \
    || fail "generated YAML failed yaml.safe_load"

# Test 6: generated YAML contains secret env wiring for APP_JWT.
grep -q 'secrets\.APP_JWT' "$GEN_FILE" \
    && pass "generated YAML wires \${{ secrets.APP_JWT }}" \
    || fail "generated YAML missing secrets.APP_JWT wiring"

# Test 7: generated YAML contains a wfctl plugin install step.
grep -q 'plugin install' "$GEN_FILE" \
    && pass "generated YAML includes a wfctl plugin install step" \
    || fail "generated YAML missing wfctl plugin install step"

# Test 8: generated YAML contains a migration step (wfctl ci run --phase migrate).
grep -q 'phase migrate' "$GEN_FILE" \
    && pass "generated YAML includes a migration step (--phase migrate)" \
    || fail "generated YAML missing migration step"

# Test 9: generated YAML contains a smoke-test job hitting app.example.com/healthz.
grep -q 'app\.example\.com/healthz' "$GEN_FILE" \
    && pass "generated YAML includes smoke test against app.example.com/healthz" \
    || fail "generated YAML missing smoke test for app.example.com/healthz"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
