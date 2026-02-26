#!/usr/bin/env bash
set -euo pipefail

# Test script for Scenario 33: API Gateway Autoscaling
# Runs go test on the relevant Go packages in the workflow repo.
# Outputs PASS:/FAIL: lines for scenario test tracking.

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

WORKFLOW_DIR="${WORKFLOW_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)/../workflow}"

echo ""
echo "=== Scenario 33: API Gateway Autoscaling ==="
echo ""

# Run go tests and emit PASS:/FAIL: per test case
while IFS= read -r line; do
    if [[ "$line" =~ ^"--- PASS: " ]]; then
        name="${line#--- PASS: }"
        name="${name%% (*}"
        pass "$name"
    elif [[ "$line" =~ ^"--- FAIL: " ]]; then
        name="${line#--- FAIL: }"
        name="${name%% (*}"
        fail "$name"
    fi
done < <(cd "$WORKFLOW_DIR" && go test ./module/ -run "^TestPlatformAPIGateway|^TestApigw|^TestPlatformAutoscaling|^TestScaling|^TestAWSAPIGateway" -v -count=1 2>&1)

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ] && [ "$PASS_COUNT" -gt 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED"
    exit 1
fi
