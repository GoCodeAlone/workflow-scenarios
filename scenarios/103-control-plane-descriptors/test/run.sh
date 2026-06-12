#!/usr/bin/env bash
# Scenario 103 — Control-plane descriptor bundle proof.
#
# Runs the real Go validator against committed descriptor bundle artifacts.
# PASS/FAIL lines are produced from validator execution, not static fixtures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
VALIDATOR_DIR="$SCENARIO_DIR/validator"
VALID_DIR="$SCENARIO_DIR/bundles/valid"
INVALID_DIR="$SCENARIO_DIR/bundles/invalid"

echo ""
echo "=== Scenario 103 — Control Plane Descriptor Bundles ==="
echo ""

if [ ! -d "$VALIDATOR_DIR" ]; then
  echo "FAIL: validator directory missing"
  exit 1
fi

OUTPUT=$(cd "$VALIDATOR_DIR" && GOWORK=off go run . --valid-dir "$VALID_DIR" --invalid-dir "$INVALID_DIR" 2>&1)
STATUS=$?
echo "$OUTPUT"

if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: control-plane descriptor bundle validator exited $STATUS"
  exit "$STATUS"
fi

if echo "$OUTPUT" | grep -q 'SUMMARY: valid=3 invalid=4 public_contract=control-plane.v1alpha1'; then
  echo "PASS: validator summary proves released control-plane contract execution"
else
  echo "FAIL: validator summary missing expected contract/count evidence"
  exit 1
fi
