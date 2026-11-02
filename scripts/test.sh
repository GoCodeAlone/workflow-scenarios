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

printf '%s\n' "$TEST_OUTPUT"

# Keep assertion counts separate from skipped checks.
PASS=$(printf '%s\n' "$TEST_OUTPUT" | grep -c "^PASS:" || true)
FAIL=$(printf '%s\n' "$TEST_OUTPUT" | grep -c "^FAIL:" || true)
SKIP=$(printf '%s\n' "$TEST_OUTPUT" | grep -c "^SKIP:" || true)
TOTAL=$((PASS + FAIL))

if [ "$TEST_EXIT" -ne 0 ] || [ "$FAIL" -ne 0 ]; then
    RESULT="fail"
    RESULT_EXIT=1
    SUMMARY="RESULT: TESTS FAILED ($FAIL failed, $PASS passed, $SKIP skipped; child exit $TEST_EXIT)"
elif [ "$SKIP" -ne 0 ] || [ "$TOTAL" -eq 0 ]; then
    RESULT="skip"
    RESULT_EXIT=77
    SUMMARY="RESULT: TESTS INCOMPLETE ($PASS passed, $SKIP skipped, $TOTAL assertions)"
else
    RESULT="pass"
    RESULT_EXIT=0
    SUMMARY="RESULT: ALL TESTS PASSED ($PASS/$TOTAL)"
fi

# Persist artifacts before publishing the result or announcing completion.
ARTIFACTS_DIR="$SCENARIO_DIR/test/artifacts"
if ! mkdir -p "$ARTIFACTS_DIR" ||
    ! printf '%s\n' "$TEST_OUTPUT" > "$ARTIFACTS_DIR/last-run-$(date +%Y%m%d-%H%M%S).log" ||
    ! printf '%s\n' "$TEST_OUTPUT" > "$ARTIFACTS_DIR/last-run.log"; then
    echo "ERROR: Could not save scenario test artifacts" >&2
    exit 1
fi

if ! ./scripts/update-status.sh "$SCENARIO" test "$RESULT" "$TOTAL" "$PASS" "$FAIL" "$SKIP"; then
    echo "ERROR: Could not record scenario test result" >&2
    exit 1
fi

printf '\n%s\n' "$SUMMARY"
exit "$RESULT_EXIT"
