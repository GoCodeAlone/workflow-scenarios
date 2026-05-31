#!/usr/bin/env bash
# Scenario 97 — CI Generate Jenkins + CircleCI (config-derived)
#
# Behavior proof for workflow#804: runs the REAL `wfctl ci generate` for the
# jenkins and circleci platforms and asserts the emitted Jenkinsfile /
# .circleci/config.yml are config-derived (secret wiring, `wfctl migrations up`,
# smoke, plan-guard) and free of the retired legacy stages (`go test ./...`,
# `wfctl deploy --image`). Demonstration-fidelity: executes the real artifact,
# not a reimplementation.
set -uo pipefail

SCENARIO="100-ci-generate-jenkins-circleci"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
WORKFLOW_REPO="${WORKFLOW_REPO:-$(cd "$SCENARIO_DIR/../../.." && pwd)/workflow}"
CONFIG="$SCENARIO_DIR/config/deploy.yaml"

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

echo ""
echo "=== Scenario $SCENARIO ==="
echo ""

# Locate wfctl (prefer an explicit WFCTL_BIN for local/unreleased builds).
WFCTL=""
for candidate in \
    "${WFCTL_BIN:-}" \
    "$(command -v wfctl 2>/dev/null)" \
    "$WORKFLOW_REPO/bin/wfctl" \
    "/tmp/wfctl"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        WFCTL="$candidate"
        break
    fi
done

if [ -z "$WFCTL" ]; then
    skip "wfctl binary not found — set WFCTL_BIN to a built wfctl (needs cigen jenkins/circleci, workflow >= v0.68.0)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi
echo "Using wfctl: $WFCTL"

[ -f "$CONFIG" ] && pass "config/deploy.yaml exists" || { fail "config/deploy.yaml missing"; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1; }

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Shared config-derived assertions over a generated file.
assert_config_derived() {
    local label="$1" file="$2"
    [ -f "$file" ] || { fail "$label: expected output file $file"; return; }
    grep -q "APP_DB_URL" "$file" \
        && pass "$label: secret APP_DB_URL wired" \
        || fail "$label: missing secret APP_DB_URL"
    grep -q "wfctl migrations up" "$file" \
        && pass "$label: 'wfctl migrations up' migration step present" \
        || fail "$label: missing 'wfctl migrations up'"
    grep -q "https://myapp.example.com/healthz" "$file" \
        && pass "$label: smoke URL present" \
        || fail "$label: missing smoke URL"
    grep -q "exit 1" "$file" \
        && pass "$label: plan-guard (exit 1) present" \
        || fail "$label: missing plan-guard"
    grep -q "wfctl infra apply" "$file" \
        && pass "$label: 'wfctl infra apply' present" \
        || fail "$label: missing 'wfctl infra apply'"
    # Retired legacy (non-config-derived) stages must be ABSENT (ADR 0044).
    if grep -qE "go test \./\.\.\.|wfctl deploy --image|docker build|wfctl ci run --phase migrate" "$file"; then
        fail "$label: contains a retired legacy stage (go test / wfctl deploy --image / docker build / ci run --phase migrate)"
    else
        pass "$label: no retired legacy stages"
    fi
}

# --- Jenkins ---
if "$WFCTL" ci generate --platform jenkins --config "$CONFIG" --output "$OUT/jenkins" --write >/dev/null 2>&1; then
    pass "wfctl ci generate --platform jenkins succeeded"
    assert_config_derived "jenkins" "$OUT/jenkins/Jenkinsfile"
    grep -q "pipeline {" "$OUT/jenkins/Jenkinsfile" \
        && pass "jenkins: declarative pipeline { } block" \
        || fail "jenkins: missing pipeline { } block"
    grep -q "Requires a Jenkins Multibranch Pipeline" "$OUT/jenkins/Jenkinsfile" \
        && pass "jenkins: Multibranch requirement header present" \
        || fail "jenkins: missing Multibranch header"
    grep -q "credentials('APP_DB_URL')" "$OUT/jenkins/Jenkinsfile" \
        && pass "jenkins: credentials('APP_DB_URL') binding" \
        || fail "jenkins: missing credentials() binding"
else
    fail "wfctl ci generate --platform jenkins failed"
fi

# --- CircleCI ---
if "$WFCTL" ci generate --platform circleci --config "$CONFIG" --output "$OUT/circle" --write >/dev/null 2>&1; then
    pass "wfctl ci generate --platform circleci succeeded"
    assert_config_derived "circleci" "$OUT/circle/.circleci/config.yml"
    grep -q "version: 2.1" "$OUT/circle/.circleci/config.yml" \
        && pass "circleci: version 2.1" \
        || fail "circleci: missing version 2.1"
    grep -q "requires:" "$OUT/circle/.circleci/config.yml" \
        && pass "circleci: workflow requires: graph" \
        || fail "circleci: missing requires: graph"
    if grep -q "needs:" "$OUT/circle/.circleci/config.yml"; then
        fail "circleci: uses GHA needs: (should be requires:)"
    else
        pass "circleci: no GHA needs: keyword"
    fi
else
    fail "wfctl ci generate --platform circleci failed"
fi

# --- step.ci_generate config-shape check (best-effort) ---
# Proves a step.ci_generate config with platform jenkins/circleci parses. The
# plugin's step schema is only available when the ci-generator plugin is
# installed; with --skip-unknown-types this confirms the surrounding config is
# valid. The behavior half of acceptance #2 is the plugin's integration_test.go.
STEP_CFG="$SCENARIO_DIR/config/step-ci-generate.yaml"
if [ -f "$STEP_CFG" ]; then
    if "$WFCTL" validate --skip-unknown-types "$STEP_CFG" >/dev/null 2>&1; then
        pass "step.ci_generate config (jenkins+circleci) validates"
    else
        fail "step.ci_generate config failed validation"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
