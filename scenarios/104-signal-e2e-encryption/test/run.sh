#!/usr/bin/env bash
# Scenario 104 — Signal E2E Encryption.
#
# Demonstration-fidelity: this script runs the real released
# workflow-plugin-signal v0.9.0 typed step tests. PASS/FAIL lines are derived
# from `go test` output, not from hard-coded expected output.
set -uo pipefail

PLUGIN_VERSION="${PLUGIN_VERSION:-v0.9.0}"
PKG="github.com/GoCodeAlone/workflow-plugin-signal/internal"
TEST_RE='TestSignalSessionPrepareEncryptDecryptRoundTrip|TestSignalDecryptDeniesUnauthorizedPrincipalWithoutPlaintext'

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 104 — Signal E2E Encryption ==="
echo ""

if ! WORKDIR="$(mktemp -d)"; then
  fail "could not create temporary module workspace"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi
trap 'rm -rf "$WORKDIR"' EXIT

(
  cd "$WORKDIR" || exit 1
  go mod init scenario-104-signal-e2e >/dev/null
  go get "${PKG}@${PLUGIN_VERSION}" >/dev/null
)
if [ "$?" -eq 0 ]; then
  pass "pinned workflow-plugin-signal ${PLUGIN_VERSION}"
else
  fail "could not pin workflow-plugin-signal ${PLUGIN_VERSION}"
fi

OUTPUT="$(
  cd "$WORKDIR" && go test "$PKG" -run "$TEST_RE" -count=1 -v 2>&1
)"
STATUS=$?
echo "$OUTPUT"

if [ "$STATUS" -eq 0 ]; then
  pass "released Signal plugin E2E encryption tests passed"
else
  fail "released Signal plugin E2E encryption tests failed"
fi

echo "$OUTPUT" | grep -q 'TestSignalSessionPrepareEncryptDecryptRoundTrip' \
  && pass "session prepare -> encrypt -> decrypt round trip executed" \
  || fail "round-trip test did not execute"

echo "$OUTPUT" | grep -q 'TestSignalDecryptDeniesUnauthorizedPrincipalWithoutPlaintext' \
  && pass "unauthorized principal denial executed" \
  || fail "unauthorized principal denial test did not execute"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
