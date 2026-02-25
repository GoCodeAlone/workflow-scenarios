#!/usr/bin/env bash
set -euo pipefail

SCENARIO="$1"
SCENARIO_DIR="scenarios/${SCENARIO}"
TEST_SCRIPT="$SCENARIO_DIR/test/run.sh"

if [ ! -f "$TEST_SCRIPT" ]; then
    echo "ERROR: Test script not found: $TEST_SCRIPT"
    exit 1
fi

NAMESPACE=$(python3 -c "
import json
with open('scenarios.json') as f:
    d = json.load(f)
print(d['scenarios']['$SCENARIO']['namespace'])
")

echo "Testing scenario: $SCENARIO in namespace: $NAMESPACE"
echo "================================================"

# Export for test scripts
export NAMESPACE
export SCENARIO

# Run the test script and capture output
set +e
TEST_OUTPUT=$(bash "$TEST_SCRIPT" 2>&1)
TEST_EXIT=$?
set -e

echo "$TEST_OUTPUT"

# Count PASS/FAIL lines from test output
PASS=$(echo "$TEST_OUTPUT" | grep -c "^PASS:" || true)
FAIL=$(echo "$TEST_OUTPUT" | grep -c "^FAIL:" || true)
TOTAL=$((PASS + FAIL))

if [ $TEST_EXIT -eq 0 ] && [ $FAIL -eq 0 ]; then
    RESULT="pass"
    echo ""
    echo "RESULT: ALL TESTS PASSED ($PASS/$TOTAL)"
else
    RESULT="fail"
    echo ""
    echo "RESULT: TESTS FAILED ($FAIL failed, $PASS passed, $TOTAL total)"
fi

# Update scenarios.json with results
./scripts/update-status.sh "$SCENARIO" test "$RESULT" "$TOTAL" "$PASS" "$FAIL"

# Save test artifacts
ARTIFACTS_DIR="$SCENARIO_DIR/test/artifacts"
mkdir -p "$ARTIFACTS_DIR"
echo "$TEST_OUTPUT" > "$ARTIFACTS_DIR/last-run-$(date +%Y%m%d-%H%M%S).log"
echo "$TEST_OUTPUT" > "$ARTIFACTS_DIR/last-run.log"

exit $TEST_EXIT
