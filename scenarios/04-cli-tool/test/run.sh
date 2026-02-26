#!/usr/bin/env bash
# Scenario 04: CLI Tool - wfctl pipeline commands
# Each test outputs PASS: or FAIL: prefix

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
WORKFLOW_REPO="${WORKFLOW_REPO:-$(cd "$SCENARIO_DIR/../../.." && pwd)/workflow}"
WFCTL="${WFCTL:-$WORKFLOW_REPO/bin/wfctl}"
CONFIG="$SCENARIO_DIR/config/app.yaml"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Test 1: wfctl pipeline list shows all 4 pipelines
output=$("$WFCTL" pipeline list -c "$CONFIG" 2>&1) || true
if echo "$output" | grep -q "Pipelines (4):" && \
   echo "$output" | grep -q "log-demo" && \
   echo "$output" | grep -q "conditional-demo" && \
   echo "$output" | grep -q "foreach-demo" && \
   echo "$output" | grep -q "template-demo"; then
    pass "pipeline list shows all 4 pipelines"
else
    fail "pipeline list shows all 4 pipelines"
    echo "  Output: $output"
fi

# Test 2: pipeline list shows step counts
output=$("$WFCTL" pipeline list -c "$CONFIG" 2>&1) || true
if echo "$output" | grep -q "log-demo.*4 steps" && \
   echo "$output" | grep -q "conditional-demo.*5 steps" && \
   echo "$output" | grep -q "foreach-demo.*3 steps" && \
   echo "$output" | grep -q "template-demo.*4 steps"; then
    pass "pipeline list shows step counts per pipeline"
else
    fail "pipeline list shows step counts per pipeline"
    echo "  Output: $output"
fi

# Test 3: pipeline list requires -c flag
output=$("$WFCTL" pipeline list 2>&1) || true
if echo "$output" | grep -q "\-c (config file) is required"; then
    pass "pipeline list fails without -c flag"
else
    fail "pipeline list fails without -c flag"
    echo "  Output: $output"
fi

# Test 4: run log-demo pipeline with --var flags
output=$("$WFCTL" pipeline run -c "$CONFIG" -p log-demo --var name=World --var environment=dev 2>&1) || true
if echo "$output" | grep -q "Pipeline completed successfully" && \
   echo "$output" | grep -qv "FAILED"; then
    pass "pipeline run log-demo with --var flags succeeds"
else
    fail "pipeline run log-demo with --var flags succeeds"
    echo "  Output: $output"
fi

# Test 5: run conditional-demo with status=active branches correctly
output=$("$WFCTL" pipeline run -c "$CONFIG" -p conditional-demo --var status=active 2>&1) || true
if echo "$output" | grep -q "Pipeline completed successfully" && \
   echo "$output" | grep -qv "FAILED"; then
    pass "pipeline run conditional-demo with status=active succeeds"
else
    fail "pipeline run conditional-demo with status=active succeeds"
    echo "  Output: $output"
fi

# Test 6: run conditional-demo with status=inactive branches correctly
output=$("$WFCTL" pipeline run -c "$CONFIG" -p conditional-demo --var status=inactive 2>&1) || true
if echo "$output" | grep -q "Pipeline completed successfully"; then
    pass "pipeline run conditional-demo with status=inactive succeeds"
else
    fail "pipeline run conditional-demo with status=inactive succeeds"
    echo "  Output: $output"
fi

# Test 7: run foreach-demo iterates over items
output=$("$WFCTL" pipeline run -c "$CONFIG" -p foreach-demo 2>&1) || true
if echo "$output" | grep -q "Pipeline completed successfully" && \
   echo "$output" | grep -q "ForEach complete"; then
    pass "pipeline run foreach-demo iterates successfully"
else
    fail "pipeline run foreach-demo iterates successfully"
    echo "  Output: $output"
fi

# Test 8: run template-demo with --var flags renders templates
output=$("$WFCTL" pipeline run -c "$CONFIG" -p template-demo --var username=alice --var version=1.2.3 2>&1) || true
if echo "$output" | grep -q "Pipeline completed successfully" && \
   echo "$output" | grep -q "workflow-cli v1.2.3 for user alice"; then
    pass "pipeline run template-demo renders Go templates correctly"
else
    fail "pipeline run template-demo renders Go templates correctly"
    echo "  Output: $output"
fi

# Test 9: run with --input JSON passes data to pipeline
output=$("$WFCTL" pipeline run -c "$CONFIG" -p log-demo --input '{"name":"JSONUser","environment":"test"}' 2>&1) || true
if echo "$output" | grep -q "Pipeline completed successfully" && \
   echo "$output" | grep -q '"name":"JSONUser"'; then
    pass "pipeline run with --input JSON passes data correctly"
else
    fail "pipeline run with --input JSON passes data correctly"
    echo "  Output: $output"
fi

# Test 10: run with --var and --input combined (--var overrides --input for same key)
output=$("$WFCTL" pipeline run -c "$CONFIG" -p log-demo --input '{"name":"InputUser","environment":"staging"}' --var name=VarUser 2>&1) || true
if echo "$output" | grep -q "Pipeline completed successfully"; then
    pass "pipeline run with --input and --var combined succeeds"
else
    fail "pipeline run with --input and --var combined succeeds"
    echo "  Output: $output"
fi

# Test 11: run with invalid pipeline name returns error
output=$("$WFCTL" pipeline run -c "$CONFIG" -p does-not-exist 2>&1) || true
if echo "$output" | grep -q '"does-not-exist" not found'; then
    pass "pipeline run with invalid pipeline name returns error"
else
    fail "pipeline run with invalid pipeline name returns error"
    echo "  Output: $output"
fi

# Test 12: run with invalid pipeline name shows available pipelines
output=$("$WFCTL" pipeline run -c "$CONFIG" -p does-not-exist 2>&1) || true
if echo "$output" | grep -q "available:" && echo "$output" | grep -q "log-demo"; then
    pass "pipeline run with invalid name shows available pipelines"
else
    fail "pipeline run with invalid name shows available pipelines"
    echo "  Output: $output"
fi

# Test 13: run with --verbose shows step output details
output=$("$WFCTL" pipeline run -c "$CONFIG" -p log-demo --var name=Verbose --var environment=prod --verbose 2>&1) || true
if echo "$output" | grep -q "Final context:" && \
   echo "$output" | grep -q "greeting = Hello, Verbose"; then
    pass "pipeline run with --verbose shows final context"
else
    fail "pipeline run with --verbose shows final context"
    echo "  Output: $output"
fi

# Test 14: run with --verbose shows debug engine output
output=$("$WFCTL" pipeline run -c "$CONFIG" -p log-demo --var name=Test --var environment=ci --verbose 2>&1) || true
if echo "$output" | grep -q "Configured pipeline"; then
    pass "pipeline run with --verbose shows engine debug output"
else
    fail "pipeline run with --verbose shows engine debug output"
    echo "  Output: $output"
fi

# Test 15: run without -p flag returns error
output=$("$WFCTL" pipeline run -c "$CONFIG" 2>&1) || true
if echo "$output" | grep -q "\-p (pipeline name) is required"; then
    pass "pipeline run without -p flag returns error"
else
    fail "pipeline run without -p flag returns error"
    echo "  Output: $output"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $((PASS_COUNT + FAIL_COUNT)) total"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
