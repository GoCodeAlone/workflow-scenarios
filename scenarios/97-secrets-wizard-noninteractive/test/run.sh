#!/usr/bin/env bash
# Scenario 97 — Secrets wizard non-interactive mode.
#
# Showcases wfctl secrets setup --non-interactive --from-env and
# wfctl secrets list --json against a file-backed store. Proves that
# secret VALUES never appear in stdout or in the audit JSONL log.
#
# WFCTL_BIN override takes precedence over PATH so PR reviewers can
# pin a built-from-source wfctl during review.
set -uo pipefail

SCENARIO="97-secrets-wizard-noninteractive"
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

# Per-run isolated tmp directories so the scenario is fully reproducible.
TMP_ROOT="$(mktemp -d /tmp/sc97-XXXXXX)"
export SC97_STORE_DIR="$TMP_ROOT/store"
export XDG_STATE_HOME="$TMP_ROOT/state"
mkdir -p "$SC97_STORE_DIR"

AUDIT_FILE="$TMP_ROOT/state/wfctl/plugins/wfctl/secrets-audit.jsonl"

echo "TMP_ROOT: $TMP_ROOT"
echo ""

# Disable exit-on-error for individual assertion commands so all tests run.
set +e

# Test 1: config file present.
[ -f "$CONFIG" ] && pass "config/app.yaml exists" || { fail "config/app.yaml missing"; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1; }

# Test 2: wfctl validate passes.
VALIDATE_OUT=$("$WFCTL" validate --skip-unknown-types "$CONFIG" 2>&1)
VALIDATE_RC=$?
if [ "$VALIDATE_RC" -eq 0 ]; then
    pass "wfctl validate accepts config"
else
    fail "wfctl validate failed (rc=$VALIDATE_RC): $VALIDATE_OUT"
fi

# Test 3: secrets list --json emits valid JSON and shows both secrets unset.
LIST1_OUT=$("$WFCTL" secrets list -config "$CONFIG" -json 2>&1)
LIST1_RC=$?
if [ "$LIST1_RC" -ne 0 ]; then
    fail "wfctl secrets list --json failed (rc=$LIST1_RC): $LIST1_OUT"
else
    echo "$LIST1_OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
        && pass "secrets list emits valid JSON" \
        || fail "secrets list output is not valid JSON: $LIST1_OUT"

    # Both secrets should be unset initially.
    TOKEN_EXISTS=$(echo "$LIST1_OUT" | python3 -c "
import json,sys
data=json.load(sys.stdin)
items={d['name']:d for d in data}
print(items.get('APP_TOKEN',{}).get('exists','missing'))
" 2>/dev/null)
    SECRET_EXISTS=$(echo "$LIST1_OUT" | python3 -c "
import json,sys
data=json.load(sys.stdin)
items={d['name']:d for d in data}
print(items.get('APP_SECRET',{}).get('exists','missing'))
" 2>/dev/null)
    [ "$TOKEN_EXISTS" = "False" ] \
        && pass "APP_TOKEN is unset before setup" \
        || fail "APP_TOKEN should be unset before setup (exists=$TOKEN_EXISTS)"
    [ "$SECRET_EXISTS" = "False" ] \
        && pass "APP_SECRET is unset before setup" \
        || fail "APP_SECRET should be unset before setup (exists=$SECRET_EXISTS)"
fi

# Test 4: secrets setup --non-interactive --from-env --only APP_TOKEN sets APP_TOKEN.
SETUP1_OUT=$(APP_TOKEN=tok-12345 "$WFCTL" secrets setup \
    -config "$CONFIG" \
    --non-interactive --from-env --only APP_TOKEN 2>&1)
SETUP1_RC=$?
if [ "$SETUP1_RC" -eq 0 ]; then
    pass "secrets setup --non-interactive --from-env --only APP_TOKEN exits 0"
else
    fail "secrets setup failed (rc=$SETUP1_RC): $SETUP1_OUT"
fi
# Output should mention APP_TOKEN as [set].
echo "$SETUP1_OUT" | grep -q "APP_TOKEN" \
    && pass "setup output mentions APP_TOKEN" \
    || fail "setup output did not mention APP_TOKEN: $SETUP1_OUT"

# Test 5: secrets list after setup — APP_TOKEN set, APP_SECRET unset.
LIST2_OUT=$("$WFCTL" secrets list -config "$CONFIG" -json 2>&1)
LIST2_RC=$?
if [ "$LIST2_RC" -eq 0 ]; then
    TOKEN_EXISTS2=$(echo "$LIST2_OUT" | python3 -c "
import json,sys
data=json.load(sys.stdin)
items={d['name']:d for d in data}
print(items.get('APP_TOKEN',{}).get('exists','missing'))
" 2>/dev/null)
    SECRET_EXISTS2=$(echo "$LIST2_OUT" | python3 -c "
import json,sys
data=json.load(sys.stdin)
items={d['name']:d for d in data}
print(items.get('APP_SECRET',{}).get('exists','missing'))
" 2>/dev/null)
    [ "$TOKEN_EXISTS2" = "True" ] \
        && pass "APP_TOKEN is set after setup" \
        || fail "APP_TOKEN should be set after setup (exists=$TOKEN_EXISTS2)"
    [ "$SECRET_EXISTS2" = "False" ] \
        && pass "APP_SECRET remains unset (not in --only)" \
        || fail "APP_SECRET should still be unset (exists=$SECRET_EXISTS2)"
else
    fail "wfctl secrets list (after setup) failed (rc=$LIST2_RC): $LIST2_OUT"
fi

# Test 6: --skip-existing is a no-op (re-run sets nothing).
SETUP2_OUT=$(APP_TOKEN=tok-12345 "$WFCTL" secrets setup \
    -config "$CONFIG" \
    --non-interactive --from-env --only APP_TOKEN --skip-existing 2>&1)
SETUP2_RC=$?
if [ "$SETUP2_RC" -eq 0 ]; then
    pass "secrets setup --skip-existing exits 0"
else
    fail "secrets setup --skip-existing failed (rc=$SETUP2_RC): $SETUP2_OUT"
fi
SET_COUNT=$(echo "$SETUP2_OUT" | python3 -c "
import sys, re
txt = sys.stdin.read()
m = re.search(r'(\d+) set', txt)
print(m.group(1) if m else '?')
" 2>/dev/null)
[ "$SET_COUNT" = "0" ] \
    && pass "--skip-existing sets 0 secrets (no-op)" \
    || fail "--skip-existing should set 0 secrets, got: $SET_COUNT (output: $SETUP2_OUT)"

# Test 7: audit JSONL exists and does NOT contain the secret value.
if [ -f "$AUDIT_FILE" ]; then
    pass "audit JSONL file exists at \$XDG_STATE_HOME path"
    if grep -q "tok-12345" "$AUDIT_FILE" 2>/dev/null; then
        fail "audit JSONL contains raw secret value — value-leak detected"
    else
        pass "audit JSONL does NOT contain raw secret value (value-never-leaked)"
    fi
    # Verify setup stdout also never leaked the value.
    if echo "$SETUP1_OUT" | grep -q "tok-12345"; then
        fail "setup stdout leaked the secret value"
    else
        pass "setup stdout did not leak the secret value"
    fi
else
    skip "audit JSONL not found at $AUDIT_FILE — skipping value-leak check"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
