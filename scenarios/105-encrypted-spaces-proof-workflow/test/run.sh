#!/usr/bin/env bash
# Scenario 105 - Encrypted Spaces Proof Workflow.
#
# Demonstration-fidelity: this executes a Workflow app pipeline with the real
# workflow-plugin-encrypted-spaces subprocess loaded through wfctl's external
# plugin path. Storage is an in-memory plugin module, not S3.
set -uo pipefail

PLUGIN_NAME="workflow-plugin-encrypted-spaces"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG="$SCENARIO_DIR/config/app.yaml"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}

find_repo() {
  local env_value="$1"
  shift
  if [ -n "$env_value" ]; then
    [ -d "$env_value" ] && printf '%s\n' "$env_value" && return 0
    return 1
  fi
  local candidate
  for candidate in "$@"; do
    if [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_wfctl() {
  if [ -n "${WFCTL:-}" ]; then
    [ -x "$WFCTL" ] && printf '%s\n' "$WFCTL" && return 0
    return 1
  fi

  local workflow_repo
  workflow_repo="$(find_repo "${WORKFLOW_REPO:-}" "$REPO_ROOT/../workflow" "$REPO_ROOT/../../../workflow")" || return 1
  mkdir -p "$workflow_repo/bin" || return 1
  (cd "$workflow_repo" && GOWORK=off go build -o bin/wfctl ./cmd/wfctl) >/dev/null || return 1
  printf '%s\n' "$workflow_repo/bin/wfctl"
}

build_plugin() {
  local plugin_dir="$1"
  local plugin_repo
  plugin_repo="$(find_repo "${ENCRYPTED_SPACES_PLUGIN_REPO:-}" "$REPO_ROOT/../workflow-plugin-encrypted-spaces" "$REPO_ROOT/../../../workflow-plugin-encrypted-spaces")" || return 1

  mkdir -p "$plugin_dir/$PLUGIN_NAME" || return 1
  cp "$plugin_repo/plugin.json" "$plugin_dir/$PLUGIN_NAME/plugin.json" || return 1
  (cd "$plugin_repo" && GOWORK=off go build \
    -ldflags "-X github.com/GoCodeAlone/workflow-plugin-encrypted-spaces/internal.Version=${PLUGIN_VERSION:-0.0.0}" \
    -o "$plugin_dir/$PLUGIN_NAME/$PLUGIN_NAME" ./cmd/workflow-plugin-encrypted-spaces) >/dev/null || return 1
}

echo ""
echo "=== Scenario 105 - Encrypted Spaces Proof Workflow ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"

WFCTL_BIN="$(resolve_wfctl)"
if [ "$?" -eq 0 ]; then
  pass "wfctl binary is available"
else
  fail "wfctl binary unavailable; set WFCTL or WORKFLOW_REPO"
  finish
  exit 1
fi

PLUGIN_DIR="$(mktemp -d)"
trap 'rm -rf "$PLUGIN_DIR"' EXIT

if build_plugin "$PLUGIN_DIR"; then
  pass "built workflow-plugin-encrypted-spaces external plugin"
else
  fail "could not build workflow-plugin-encrypted-spaces; set ENCRYPTED_SPACES_PLUGIN_REPO"
  finish
  exit 1
fi

OUTPUT="$("$WFCTL_BIN" pipeline run -c "$CONFIG" -p encrypted-space-proof --plugin-dir "$PLUGIN_DIR" --verbose 2>&1)"
STATUS=$?
echo "$OUTPUT"

if [ "$STATUS" -eq 0 ]; then
  pass "wfctl pipeline run completed"
else
  fail "wfctl pipeline run failed"
fi

echo "$OUTPUT" | grep -q 'Pipeline completed successfully' \
  && pass "Workflow engine reported successful pipeline completion" \
  || fail "Workflow engine did not report successful completion"

echo "$OUTPUT" | grep -q 'append_verified' \
  && pass "verified append step executed through plugin" \
  || fail "verified append step was not observed"

echo "$OUTPUT" | grep -q 'proof_evidence' \
  && pass "proof evidence step executed through plugin" \
  || fail "proof evidence step was not observed"

echo "$OUTPUT" | grep -q 'operationlog.commitment' \
  && pass "proof report domains flowed through Workflow output" \
  || fail "proof report domains were not observed"

finish
