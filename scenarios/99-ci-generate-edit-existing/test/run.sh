#!/usr/bin/env bash
# Scenario 99 — CI generate drift detection (edit existing workflow).
#
# Validates that wfctl ci generate --diff --exit-code:
#   - exits 1 and prints a diff when the on-disk file has manual edits
#   - exits 0 and prints no diff after a clean --write regeneration
#
# This is the "idempotent re-generation" CI lint gate contract.
set -uo pipefail

SCENARIO="99-ci-generate-edit-existing"
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
TMP_ROOT="$(mktemp -d /tmp/sc99-XXXXXX)"
export SC99_STORE_DIR="$TMP_ROOT/store"
export SC99_STATE_DIR="$TMP_ROOT/iac-state"
OUT_DIR="$TMP_ROOT/out"
mkdir -p "$SC99_STORE_DIR" "$SC99_STATE_DIR" "$OUT_DIR"

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

# Test 3: first generation writes .github/workflows/*.yml.
GEN1_OUT=$("$WFCTL" ci generate \
    -c "$CONFIG" \
    --platform github_actions \
    --out "$OUT_DIR" \
    --write 2>&1)
GEN1_RC=$?
[ "$GEN1_RC" -eq 0 ] \
    && pass "first wfctl ci generate --write exits 0" \
    || fail "first generate failed (rc=$GEN1_RC): $GEN1_OUT"

GEN_FILE=$(find "$OUT_DIR/.github/workflows" -name "*.yml" 2>/dev/null | head -1)
if [ -n "$GEN_FILE" ]; then
    pass "first generation produced .github/workflows/$(basename "$GEN_FILE")"
else
    fail "no .github/workflows/*.yml file found after first generate"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# Test 4: append stray line to simulate a manual edit.
printf '# stray-edit-by-hand\n' >> "$GEN_FILE"
pass "appended stray line to simulate manual edit"

# Test 5: --diff --exit-code exits 1 (drift detected) and prints output.
DIFF1_OUT=$("$WFCTL" ci generate \
    -c "$CONFIG" \
    --platform github_actions \
    --out "$OUT_DIR" \
    --diff --exit-code 2>&1)
DIFF1_RC=$?
if [ "$DIFF1_RC" -ne 0 ]; then
    pass "--diff --exit-code exits non-zero when drift detected (rc=$DIFF1_RC)"
else
    fail "--diff --exit-code should have exited non-zero (drift present), got rc=0"
fi
if [ -n "$DIFF1_OUT" ]; then
    pass "--diff --exit-code printed diff output (drift is visible)"
else
    fail "--diff --exit-code produced no output — expected a diff"
fi

# Test 6: regenerate cleanly via --write.
GEN2_OUT=$("$WFCTL" ci generate \
    -c "$CONFIG" \
    --platform github_actions \
    --out "$OUT_DIR" \
    --write 2>&1)
GEN2_RC=$?
[ "$GEN2_RC" -eq 0 ] \
    && pass "clean --write regeneration exits 0" \
    || fail "clean regeneration failed (rc=$GEN2_RC): $GEN2_OUT"

# Test 7: after clean regeneration, --diff --exit-code exits 0 (no drift).
DIFF2_OUT=$("$WFCTL" ci generate \
    -c "$CONFIG" \
    --platform github_actions \
    --out "$OUT_DIR" \
    --diff --exit-code 2>&1)
DIFF2_RC=$?
if [ "$DIFF2_RC" -eq 0 ]; then
    pass "--diff --exit-code exits 0 after clean regeneration (no drift)"
else
    fail "--diff --exit-code should exit 0 after clean regeneration, got rc=$DIFF2_RC; output: $DIFF2_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
