#!/usr/bin/env bash
# Scenario 26: Config-to-Binary.
#
# Demonstration-fidelity: this starts the real Workflow server from the
# scenario config and drives step.build_binary through HTTP with caller-supplied
# Workflow YAML.
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18126}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG="$SCENARIO_DIR/config/app.yaml"

PASS=0
FAIL=0
SERVER_PID=""
DATA_DIR=""
REQUEST_A=""
REQUEST_B=""
RESPONSE_A=""
RESPONSE_B=""
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
finish() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  [ -n "$DATA_DIR" ] && rm -rf "$DATA_DIR"
  [ -n "$REQUEST_A" ] && rm -f "$REQUEST_A"
  [ -n "$REQUEST_B" ] && rm -f "$REQUEST_B"
  [ -n "$RESPONSE_A" ] && rm -f "$RESPONSE_A"
  [ -n "$RESPONSE_B" ] && rm -f "$RESPONSE_B"
}
trap cleanup EXIT

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

resolve_server() {
  if [ -n "${WORKFLOW_SERVER:-}" ]; then
    [ -x "$WORKFLOW_SERVER" ] && printf '%s\n' "$WORKFLOW_SERVER" && return 0
    return 1
  fi

  local workflow_repo
  workflow_repo="$(find_repo "${WORKFLOW_REPO:-${WORKFLOW_DIR:-}}" "$REPO_ROOT/../workflow" "$REPO_ROOT/../../../workflow")" || return 1
  mkdir -p "$workflow_repo/bin" || return 1
  (cd "$workflow_repo" && GOWORK=off go build -o bin/workflow-server ./cmd/server) >/dev/null 2>&1 || return 1
  printf '%s\n' "$workflow_repo/bin/workflow-server"
}

wait_for_server() {
  local url="$1"
  local i
  for i in $(seq 1 80); do
    curl -fs "$url/healthz" >/dev/null 2>&1 && return 0
    if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      return 1
    fi
    sleep 0.25
  done
  return 1
}

write_request_config() {
  local path="$1"
  local marker="$2"
  cat >"$path" <<EOF
modules:
  - name: server
    type: http.server
    config:
      address: ":0"
  - name: router
    type: http.router
    dependsOn: [server]
workflows:
  http:
    router: router
    server: server
pipelines:
  health:
    trigger:
      type: http
      config:
        path: /healthz
        method: GET
    steps:
      - name: respond
        type: step.json_response
        config:
          status: 200
          body:
            status: ok
            marker: "$marker"
EOF
}

post_config() {
  local request_file="$1"
  local response_file="$2"
  curl -fsS -X POST "$BASE_URL/api/build/binary" \
    -H 'Content-Type: application/yaml' \
    --data-binary "@$request_file" \
    -o "$response_file"
}

assert_generated_response() {
  local label="$1"
  local request_file="$2"
  local response_file="$3"

  if jq -e '.dry_run == true and .module_path == "generated-scenario-app" and .go_version == "1.26" and .target_os == "linux" and .target_arch == "amd64"' "$response_file" >/dev/null; then
    pass "$label response returned build metadata from step.build_binary"
  else
    fail "$label response missing expected build metadata: $(cat "$response_file")"
  fi

  if jq -e '.files | index("go.mod") and index("main.go") and index("app.yaml")' "$response_file" >/dev/null; then
    pass "$label response listed generated project files"
  else
    fail "$label response missing generated file list: $(cat "$response_file")"
  fi

  if jq -e '.file_contents["go.mod"] | contains("module generated-scenario-app") and contains("go 1.26") and contains("github.com/GoCodeAlone/workflow")' "$response_file" >/dev/null; then
    pass "$label response included generated go.mod"
  else
    fail "$label response go.mod content mismatch"
  fi

  if jq -e '.file_contents["main.go"] | contains("//go:embed app.yaml") and contains("workflow.NewStdEngine")' "$response_file" >/dev/null; then
    pass "$label response included generated embedded-config main.go"
  else
    fail "$label response main.go content mismatch"
  fi

  if jq -e --rawfile expected "$request_file" '.file_contents["app.yaml"] == $expected' "$response_file" >/dev/null; then
    pass "$label response embedded the caller-supplied app.yaml"
  else
    fail "$label response app.yaml did not match caller input"
  fi
}

echo ""
echo "=== Scenario 26: Config-to-Binary ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if sed '/^[[:space:]]*#/d' "$SCRIPT_DIR/run.sh" | grep -Eq '(^|[;&|[:space:]])go[[:space:]]+test'; then
  fail "scenario test should not delegate proof to Go package tests"
else
  pass "scenario test exercises the Workflow app boundary"
fi
if grep -A12 'name: build' "$CONFIG" | grep -q 'config_from: request_body'; then
  pass "build pipeline consumes caller-provided request body"
else
  fail "build pipeline should use config_from request_body"
fi

SERVER_BIN="$(resolve_server)"
if [ "$?" -eq 0 ]; then
  pass "workflow server binary is available"
else
  fail "workflow server unavailable; set WORKFLOW_SERVER or WORKFLOW_REPO"
  finish
  exit 1
fi

if ! DATA_DIR="$(mktemp -d)"; then
  fail "could not create temporary data directory"
  finish
  exit 1
fi

SERVER_LOG="$SCRIPT_DIR/artifacts/last-server.log"
mkdir -p "$(dirname "$SERVER_LOG")"
"$SERVER_BIN" -config "$CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

if wait_for_server "$BASE_URL"; then
  pass "workflow server started and served /healthz"
else
  fail "workflow server did not become ready; see $SERVER_LOG"
  finish
  exit 1
fi

REQUEST_A="$(mktemp)"
REQUEST_B="$(mktemp)"
RESPONSE_A="$(mktemp)"
RESPONSE_B="$(mktemp)"
write_request_config "$REQUEST_A" "caller-alpha"
write_request_config "$REQUEST_B" "caller-beta"

post_config "$REQUEST_A" "$RESPONSE_A" \
  && pass "client A generated project through Workflow API" \
  || fail "client A build API failed"
assert_generated_response "client A" "$REQUEST_A" "$RESPONSE_A"

post_config "$REQUEST_B" "$RESPONSE_B" \
  && pass "client B generated project through Workflow API" \
  || fail "client B build API failed"
assert_generated_response "client B" "$REQUEST_B" "$RESPONSE_B"

if jq -e --rawfile a "$REQUEST_A" --rawfile b "$REQUEST_B" '.file_contents["app.yaml"] == $b and .file_contents["app.yaml"] != $a' "$RESPONSE_B" >/dev/null; then
  pass "same pipeline generated different app.yaml for a different caller"
else
  fail "pipeline output appears hard-coded instead of caller-driven"
fi

finish
