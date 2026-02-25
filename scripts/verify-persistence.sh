#!/usr/bin/env bash
# Usage: ./scripts/verify-persistence.sh <scenario-id>
# Example: ./scripts/verify-persistence.sh 02-event-driven
#
# Verifies data persists across a pod restart by:
#   1. Running the scenario's tests (capturing "before" results)
#   2. Restarting the pod via rollout restart
#   3. Waiting for pod ready
#   4. Running the tests again (capturing "after" results)
#   5. Reporting any test that passed before but fails after
set -euo pipefail

SCENARIO="${1:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "$SCENARIO" ]; then
    echo "Usage: ./scripts/verify-persistence.sh <scenario-id>"
    echo "Example: ./scripts/verify-persistence.sh 02-event-driven"
    exit 1
fi

cd "$REPO_ROOT"

TEST_SCRIPT="scenarios/${SCENARIO}/test/run.sh"
if [ ! -f "$TEST_SCRIPT" ]; then
    echo "ERROR: Test script not found: $TEST_SCRIPT"
    exit 1
fi

NAMESPACE=$(python3 -c "
import json
with open('scenarios.json') as f:
    d = json.load(f)
s = d['scenarios'].get('$SCENARIO')
if not s:
    raise SystemExit('ERROR: Scenario $SCENARIO not found in scenarios.json')
print(s['namespace'])
")

DEPLOYED=$(python3 -c "
import json
with open('scenarios.json') as f:
    d = json.load(f)
print(d['scenarios'].get('$SCENARIO', {}).get('deployed', False))
")

if [ "$DEPLOYED" != "True" ]; then
    echo "ERROR: Scenario $SCENARIO is not currently deployed."
    echo "Deploy it first with: make deploy SCENARIO=$SCENARIO"
    exit 1
fi

HAS_SEED="false"
if [ -f "scenarios/${SCENARIO}/seed/seed.sh" ]; then
    HAS_SEED="true"
fi

echo "============================================"
echo "Persistence verification: $SCENARIO"
echo "Namespace: $NAMESPACE"
echo "Has seed data: $HAS_SEED"
echo "============================================"

ARTIFACTS_DIR="scenarios/${SCENARIO}/test/artifacts"
mkdir -p "$ARTIFACTS_DIR"

# --- Step 1: Run tests before restart (before state) ---
echo ""
echo "[1/4] Running tests BEFORE restart..."
export NAMESPACE
export SCENARIO

set +e
BEFORE_OUTPUT=$(bash "$TEST_SCRIPT" 2>&1)
BEFORE_EXIT=$?
set -e

echo "$BEFORE_OUTPUT"
echo "$BEFORE_OUTPUT" > "$ARTIFACTS_DIR/persistence-before-$(date +%Y%m%d-%H%M%S).log"

BEFORE_PASS=$(echo "$BEFORE_OUTPUT" | grep -c "^PASS:" || true)
BEFORE_FAIL=$(echo "$BEFORE_OUTPUT" | grep -c "^FAIL:" || true)

echo ""
echo "Before restart: $BEFORE_PASS passed, $BEFORE_FAIL failed"

if [ "$BEFORE_FAIL" -gt 0 ]; then
    echo ""
    echo "WARNING: $BEFORE_FAIL tests already failing before restart."
    echo "Continuing to check persistence, but pre-restart failures are noted."
fi

# Collect the individual passing test names before restart
BEFORE_PASSING=$(echo "$BEFORE_OUTPUT" | grep "^PASS:" | sed 's/^PASS: //')

# --- Step 2: Restart the pod ---
echo ""
echo "[2/4] Restarting pod (kubectl rollout restart)..."
kubectl rollout restart deployment/workflow-server -n "$NAMESPACE"

echo "Waiting for rollout to complete..."
kubectl rollout status deployment/workflow-server -n "$NAMESPACE" --timeout=120s

# Extra settle time for the application to initialize (DB migrations, etc.)
echo "Waiting 5s for application to settle..."
sleep 5

# --- Step 3: Wait for pod ready ---
echo ""
echo "[3/4] Confirming pod readiness..."
kubectl wait --for=condition=ready pod -l app=workflow-server -n "$NAMESPACE" --timeout=120s

echo "Pod is ready."

# --- Step 4: Run tests after restart (after state) ---
echo ""
echo "[4/4] Running tests AFTER restart..."

set +e
AFTER_OUTPUT=$(bash "$TEST_SCRIPT" 2>&1)
AFTER_EXIT=$?
set -e

echo "$AFTER_OUTPUT"
echo "$AFTER_OUTPUT" > "$ARTIFACTS_DIR/persistence-after-$(date +%Y%m%d-%H%M%S).log"

AFTER_PASS=$(echo "$AFTER_OUTPUT" | grep -c "^PASS:" || true)
AFTER_FAIL=$(echo "$AFTER_OUTPUT" | grep -c "^FAIL:" || true)

echo ""
echo "After restart: $AFTER_PASS passed, $AFTER_FAIL failed"

# --- Compare before vs after ---
echo ""
echo "============================================"
echo "Persistence Results: $SCENARIO"
echo "============================================"

# Find tests that passed before but fail after (regressions)
REGRESSIONS=()
while IFS= read -r test_name; do
    [ -z "$test_name" ] && continue
    # Check if this test now fails
    if echo "$AFTER_OUTPUT" | grep -q "^FAIL: ${test_name}$"; then
        REGRESSIONS+=("$test_name")
    fi
done <<< "$BEFORE_PASSING"

# Also check seed data survival specifically
SEED_NOTES=""
if [ "$HAS_SEED" = "true" ]; then
    # Check if any test about "seed" data failed after restart
    SEED_FAILURES=$(echo "$AFTER_OUTPUT" | grep "^FAIL:" | grep -i "seed" || true)
    if [ -n "$SEED_FAILURES" ]; then
        SEED_NOTES="Seed data failures detected after restart!"
    fi
fi

if [ "${#REGRESSIONS[@]}" -eq 0 ]; then
    echo "PASS: No persistence regressions detected."
    echo "  Before: $BEFORE_PASS passed, $BEFORE_FAIL failed"
    echo "  After:  $AFTER_PASS passed, $AFTER_FAIL failed"
    if [ -n "$SEED_NOTES" ]; then
        echo ""
        echo "WARNING: $SEED_NOTES"
        echo "$SEED_FAILURES"
    fi
    EXIT_CODE=0
else
    echo "FAIL: ${#REGRESSIONS[@]} test(s) regressed after restart:"
    for r in "${REGRESSIONS[@]}"; do
        echo "  - PASS -> FAIL: $r"
    done
    echo ""
    echo "  Before: $BEFORE_PASS passed, $BEFORE_FAIL failed"
    echo "  After:  $AFTER_PASS passed, $AFTER_FAIL failed"
    if [ -n "$SEED_NOTES" ]; then
        echo ""
        echo "WARNING: $SEED_NOTES"
    fi
    echo ""
    echo "Review artifacts in: $ARTIFACTS_DIR/"
    EXIT_CODE=1
fi

exit $EXIT_CODE
