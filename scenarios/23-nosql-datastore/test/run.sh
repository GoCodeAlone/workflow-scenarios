#!/usr/bin/env bash
# Scenario 23: NoSQL Data Store
# Tests the NoSQL module pipeline steps (get, put, delete, query) using the
# in-memory backend. Runs go unit tests from the workflow repo.
set -euo pipefail

WORKFLOW_REPO="${WORKFLOW_REPO:-/Users/jon/workspace/workflow}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== Scenario 23: NoSQL Data Store (unit tests) ==="
echo ""

if [ ! -d "$WORKFLOW_REPO" ]; then
    fail "workflow repo not found at $WORKFLOW_REPO"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Run go tests and parse output
while IFS= read -r line; do
    if [[ "$line" =~ ^"--- PASS: "(.*)" " ]] || [[ "$line" =~ ^"--- PASS: "(.*)$ ]]; then
        name="${line#--- PASS: }"
        name="${name%% (*}"
        pass "$name"
    elif [[ "$line" =~ ^"--- FAIL: " ]]; then
        name="${line#--- FAIL: }"
        name="${name%% (*}"
        fail "$name"
    fi
done < <(cd "$WORKFLOW_REPO" && go test ./module/ -v -count=1 -run "TestNoSQL" 2>&1)

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
