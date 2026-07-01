#!/usr/bin/env bash
# Scenario 105 — Encrypted Spaces Proof Workflow.
#
# Demonstration-fidelity: this script runs the real released
# workflow-plugin-encrypted-spaces v0.4.0 typed step tests. PASS/FAIL lines are
# derived from `go test` output, not from hard-coded expected output.
set -uo pipefail

PLUGIN_VERSION="${PLUGIN_VERSION:-v0.4.0}"
PKG="github.com/GoCodeAlone/workflow-plugin-encrypted-spaces/internal"
TEST_RE='TestAppendVerifiedAcceptsVectorBackedProof|TestAppendVerifiedRejectsTamperedProof|TestProofEvidenceRedactsPlaintextAndKeyMaterial|TestVectorReportStepFiltersRequiredDomains'

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== Scenario 105 — Encrypted Spaces Proof Workflow ==="
echo ""

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

(
  cd "$WORKDIR" || exit 1
  go mod init scenario-105-encrypted-spaces >/dev/null
  go get "${PKG}@${PLUGIN_VERSION}" >/dev/null
)
if [ "$?" -eq 0 ]; then
  pass "pinned workflow-plugin-encrypted-spaces ${PLUGIN_VERSION}"
else
  fail "could not pin workflow-plugin-encrypted-spaces ${PLUGIN_VERSION}"
fi

OUTPUT="$(
  cd "$WORKDIR" && go test "$PKG" -run "$TEST_RE" -count=1 -v 2>&1
)"
STATUS=$?
echo "$OUTPUT"

if [ "$STATUS" -eq 0 ]; then
  pass "released Encrypted Spaces proof workflow tests passed"
else
  fail "released Encrypted Spaces proof workflow tests failed"
fi

echo "$OUTPUT" | grep -q 'TestAppendVerifiedAcceptsVectorBackedProof' \
  && pass "vector-backed append verification executed" \
  || fail "vector-backed append verification test did not execute"

echo "$OUTPUT" | grep -q 'TestAppendVerifiedRejectsTamperedProof' \
  && pass "tamper rejection executed" \
  || fail "tamper rejection test did not execute"

echo "$OUTPUT" | grep -q 'TestProofEvidenceRedactsPlaintextAndKeyMaterial' \
  && pass "proof evidence redaction executed" \
  || fail "proof evidence redaction test did not execute"

echo "$OUTPUT" | grep -q 'TestVectorReportStepFiltersRequiredDomains' \
  && pass "required-domain vector coverage executed" \
  || fail "required-domain vector coverage test did not execute"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
