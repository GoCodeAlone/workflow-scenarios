#!/usr/bin/env bash
# Runs verify-persistence.sh for all deployed scenarios that have test scripts.
# Scenarios without k8s deployments (e.g. 04-cli-tool, 03-ai-agent) are skipped.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "============================================"
echo "Persistence verification: all scenarios"
echo "============================================"

# Identify deployed scenarios with both a pod-based deployment and a test script
DEPLOYED_SCENARIOS=$(python3 -c "
import json
with open('scenarios.json') as f:
    d = json.load(f)
# Skip scenarios that don't use k8s deployments
skip = {'03-ai-agent', '04-cli-tool', '05-saas-webapp', '06-multitenant-api'}
for name, s in d['scenarios'].items():
    if s.get('deployed') and name not in skip:
        print(name)
")

if [ -z "$DEPLOYED_SCENARIOS" ]; then
    echo "No eligible deployed scenarios found."
    echo "Persistence tests require k8s-deployed scenarios with PVCs."
    exit 0
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_SCENARIOS=()

for SCENARIO in $DEPLOYED_SCENARIOS; do
    if [ ! -f "scenarios/${SCENARIO}/test/run.sh" ]; then
        echo ""
        echo "--- SKIP: $SCENARIO (no test/run.sh) ---"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    echo ""
    echo "--- Verifying persistence: $SCENARIO ---"

    set +e
    ./scripts/verify-persistence.sh "$SCENARIO"
    EXIT_CODE=$?
    set -e

    if [ $EXIT_CODE -eq 0 ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "--- PASSED: $SCENARIO ---"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_SCENARIOS+=("$SCENARIO")
        echo "--- FAILED: $SCENARIO ---"
    fi
done

TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))

echo ""
echo "============================================"
echo "Persistence Verification Summary"
echo "============================================"
echo "  Passed:  $PASS_COUNT"
echo "  Failed:  $FAIL_COUNT"
echo "  Skipped: $SKIP_COUNT"
echo "  Total:   $TOTAL"

if [ "${#FAILED_SCENARIOS[@]}" -gt 0 ]; then
    echo ""
    echo "Scenarios with persistence regressions:"
    for s in "${FAILED_SCENARIOS[@]}"; do
        echo "  - $s"
    done
    echo ""
    echo "Review artifacts in scenarios/<name>/test/artifacts/"
    exit 1
else
    echo ""
    echo "All scenarios passed persistence verification."
    exit 0
fi
