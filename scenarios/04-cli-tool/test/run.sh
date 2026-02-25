#!/bin/bash
# Scenario 04: CLI Tool - wfctl pipeline commands
# Each test outputs PASS: or FAIL: prefix

set -euo pipefail

WFCTL=/Users/jon/workspace/workflow/bin/wfctl
CONFIG=/Users/jon/workspace/workflow-scenarios/scenarios/04-cli-tool/config/app.yaml

PASS=0
FAIL=0

run_test() {
    local desc="$1"
    local result="$2"  # "pass" or "fail"
    if [ "$result" = "pass" ]; then
        echo "PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# Test 1: wfctl pipeline list shows all 4 pipelines
output=$("$WFCTL" pipeline list -c "$CONFIG" 2>&1)
if echo "$output" | grep -q "Pipelines (4):" && \
   echo "$output" | grep -q "log-demo" && \
   echo "$output" | grep -q "conditional-demo" && \
   echo "$output" | grep -q "foreach-demo" && \
   echo "$output" | grep -q "template-demo"; then
    run_test "pipeline list shows all 4 pipelines" pass
else
    run_test "pipeline list shows all 4 pipelines" fail
    echo "  Output: $output"
fi

# Test 2: pipeline list shows step counts
output=$("$WFCTL" pipeline list -c "$CONFIG" 2>&1)
if echo "$output" | grep -q "log-demo.*4 steps" && \
   echo "$output" | grep -q "conditional-demo.*5 steps" && \
   echo "$output" | grep -q "foreach-demo.*3 steps" && \
   echo "$output" | grep -q "template-demo.*4 steps"; then
    run_test "pipeline list shows step counts per pipeline" pass
else
    run_test "pipeline list shows step counts per pipeline" fail
    echo "  Output: $output"
fi

# Test 3: pipeline list requires -c flag
output=$("$WFCTL" pipeline list 2>&1) || true
if echo "$output" | grep -q "\-c (config file) is required"; then
    run_test "pipeline list fails without -c flag" pass
else
    run_test "pipeline list fails without -c flag" fail
    echo "  Output: $output"
fi

# Test 4: run log-demo pipeline with --var flags
output=$("$WFCTL" pipeline run -c "$CONFIG" -p log-demo --var name=World --var environment=dev 2>&1)
if echo "$output" | grep -q "Pipeline completed successfully" && \
   echo "$output" | grep -qv "FAILED"; then
    run_test "pipeline run log-demo with --var flags succeeds" pass
else
    run_test "pipeline run log-demo with --var flags succeeds" fail
    echo "  Output: $output"
fi

# Test 5: run conditional-demo with status=active branches correctly
output=$("$WFCTL" pipeline run -c "$CONFIG" -p conditional-demo --var status=active 2>&1)
if echo "$output" | grep -q "Pipeline completed successfully" && \
   echo "$output" | grep -qv "FAILED"; then
    run_test "pipeline run conditional-demo with status=active succeeds" pass
else
    run_test "pipeline run conditional-demo with status=active succeeds" fail
    echo "  Output: $output"
fi

# Test 6: run conditional-demo with status=inactive branches correctly
output=$("$WFCTL" pipeline run -c "$CONFIG" -p conditional-demo --var status=inactive 2>&1)
if echo "$output" | grep -q "Pipeline completed successfully"; then
    run_test "pipeline run conditional-demo with status=inactive succeeds" pass
else
    run_test "pipeline run conditional-demo with status=inactive succeeds" fail
    echo "  Output: $output"
fi

# Test 7: run foreach-demo iterates over items
output=$("$WFCTL" pipeline run -c "$CONFIG" -p foreach-demo 2>&1)
if echo "$output" | grep -q "Pipeline completed successfully" && \
   echo "$output" | grep -q "ForEach complete"; then
    run_test "pipeline run foreach-demo iterates successfully" pass
else
    run_test "pipeline run foreach-demo iterates successfully" fail
    echo "  Output: $output"
fi

# Test 8: run template-demo with --var flags renders templates
output=$("$WFCTL" pipeline run -c "$CONFIG" -p template-demo --var username=alice --var version=1.2.3 2>&1)
if echo "$output" | grep -q "Pipeline completed successfully" && \
   echo "$output" | grep -q "workflow-cli v1.2.3 for user alice"; then
    run_test "pipeline run template-demo renders Go templates correctly" pass
else
    run_test "pipeline run template-demo renders Go templates correctly" fail
    echo "  Output: $output"
fi

# Test 9: run with --input JSON passes data to pipeline
output=$("$WFCTL" pipeline run -c "$CONFIG" -p log-demo --input '{"name":"JSONUser","environment":"test"}' 2>&1)
if echo "$output" | grep -q "Pipeline completed successfully" && \
   echo "$output" | grep -q '"name":"JSONUser"'; then
    run_test "pipeline run with --input JSON passes data correctly" pass
else
    run_test "pipeline run with --input JSON passes data correctly" fail
    echo "  Output: $output"
fi

# Test 10: run with --var and --input combined (--var overrides --input for same key)
output=$("$WFCTL" pipeline run -c "$CONFIG" -p log-demo --input '{"name":"InputUser","environment":"staging"}' --var name=VarUser 2>&1)
if echo "$output" | grep -q "Pipeline completed successfully"; then
    run_test "pipeline run with --input and --var combined succeeds" pass
else
    run_test "pipeline run with --input and --var combined succeeds" fail
    echo "  Output: $output"
fi

# Test 11: run with invalid pipeline name returns error
output=$("$WFCTL" pipeline run -c "$CONFIG" -p does-not-exist 2>&1) || true
if echo "$output" | grep -q '"does-not-exist" not found'; then
    run_test "pipeline run with invalid pipeline name returns error" pass
else
    run_test "pipeline run with invalid pipeline name returns error" fail
    echo "  Output: $output"
fi

# Test 12: run with invalid pipeline name shows available pipelines
output=$("$WFCTL" pipeline run -c "$CONFIG" -p does-not-exist 2>&1) || true
if echo "$output" | grep -q "available:" && echo "$output" | grep -q "log-demo"; then
    run_test "pipeline run with invalid name shows available pipelines" pass
else
    run_test "pipeline run with invalid name shows available pipelines" fail
    echo "  Output: $output"
fi

# Test 13: run with --verbose shows step output details
output=$("$WFCTL" pipeline run -c "$CONFIG" -p log-demo --var name=Verbose --var environment=prod --verbose 2>&1)
if echo "$output" | grep -q "Final context:" && \
   echo "$output" | grep -q "greeting = Hello, Verbose"; then
    run_test "pipeline run with --verbose shows final context" pass
else
    run_test "pipeline run with --verbose shows final context" fail
    echo "  Output: $output"
fi

# Test 14: run with --verbose shows debug engine output
output=$("$WFCTL" pipeline run -c "$CONFIG" -p log-demo --var name=Test --var environment=ci --verbose 2>&1)
if echo "$output" | grep -q "Configured pipeline"; then
    run_test "pipeline run with --verbose shows engine debug output" pass
else
    run_test "pipeline run with --verbose shows engine debug output" fail
    echo "  Output: $output"
fi

# Test 15: run without -p flag returns error
output=$("$WFCTL" pipeline run -c "$CONFIG" 2>&1) || true
if echo "$output" | grep -q "\-p (pipeline name) is required"; then
    run_test "pipeline run without -p flag returns error" pass
else
    run_test "pipeline run without -p flag returns error" fail
    echo "  Output: $output"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
