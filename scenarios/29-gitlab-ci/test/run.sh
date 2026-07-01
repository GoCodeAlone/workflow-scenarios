#!/usr/bin/env bash
# Scenario 29: GitLab CI external plugin.
#
# Demonstration-fidelity: this starts the real Workflow server from the
# scenario config, installs the real workflow-plugin-gitlab external plugin,
# and drives GitLab webhook, pipeline, MR, and comment flows through HTTP.
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18129}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
CONFIG="$SCENARIO_DIR/config/app.yaml"

PASS=0
FAIL=0
SERVER_PID=""
DATA_DIR=""
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

resolve_gitlab_plugin_repo() {
  find_repo "${WORKFLOW_PLUGIN_GITLAB_REPO:-${GITLAB_PLUGIN_REPO:-}}" \
    "$REPO_ROOT/../workflow-plugin-gitlab" \
    "$REPO_ROOT/../../../workflow-plugin-gitlab"
}

install_gitlab_plugin() {
  local data_dir="$1"
  local plugin_repo="$2"
  local plugin_dir="$data_dir/plugins/workflow-plugin-gitlab"
  mkdir -p "$plugin_dir" || return 1
  (cd "$plugin_repo" && GOWORK=off go build -o "$plugin_dir/workflow-plugin-gitlab" ./cmd/workflow-plugin-gitlab) >/dev/null 2>&1 || return 1
  cp "$plugin_repo/plugin.json" "$plugin_dir/plugin.json" || return 1
  cp "$plugin_repo/plugin.contracts.json" "$plugin_dir/plugin.contracts.json" || return 1
}

wait_for_server() {
  local url="$1"
  local i
  local health
  for i in $(seq 1 80); do
    if [ -n "$SERVER_PID" ] && ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      return 1
    fi
    health="$(curl -fs "$url/healthz" 2>/dev/null)" \
      && printf '%s' "$health" | jq -e '.status == "ok" and .scenario == "29-gitlab-ci"' >/dev/null 2>&1 \
      && return 0
    sleep 0.25
  done
  return 1
}

post_json() {
  local path="$1"
  local body="$2"
  curl -fsS -H 'Content-Type: application/json' -X POST "$BASE_URL$path" -d "$body"
}

echo ""
echo "=== Scenario 29: GitLab CI External Plugin ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
for cmd in curl jq go; do
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "required command $cmd is available"
  else
    fail "required command $cmd is missing"
  fi
done
if [ "$FAIL" -ne 0 ]; then
  finish
  exit 1
fi
if sed '/^[[:space:]]*#/d' "$SCRIPT_DIR/run.sh" | grep -Eq '(^|[;&|[:space:]])go[[:space:]]+test'; then
  fail "scenario test should not delegate proof to Go package tests"
else
  pass "scenario test exercises the Workflow app boundary"
fi
for item in "type: gitlab.client" "type: step.gitlab_parse_webhook" "type: step.gitlab_trigger_pipeline" "type: step.gitlab_pipeline_status" "type: step.gitlab_create_mr" "type: step.gitlab_mr_comment"; do
  if grep -Fq "$item" "$CONFIG"; then
    pass "Workflow config wires $item"
  else
    fail "Workflow config missing $item"
  fi
done
if grep -Fq "group/project" "$CONFIG" || grep -Fq "feature-demo" "$CONFIG"; then
  fail "Workflow config should not hard-code GitLab caller project or branch"
else
  pass "Workflow config takes GitLab caller data from requests"
fi

SERVER_BIN="$(resolve_server)"
if [ "$?" -eq 0 ]; then
  pass "workflow server binary is available"
else
  fail "workflow server unavailable; set WORKFLOW_SERVER or WORKFLOW_REPO"
  finish
  exit 1
fi

GITLAB_PLUGIN_REPO_PATH="$(resolve_gitlab_plugin_repo)"
if [ "$?" -eq 0 ]; then
  pass "workflow-plugin-gitlab source is available"
else
  fail "workflow-plugin-gitlab source unavailable; set WORKFLOW_PLUGIN_GITLAB_REPO"
  finish
  exit 1
fi

if ! DATA_DIR="$(mktemp -d)"; then
  fail "could not create temporary data directory"
  finish
  exit 1
fi
if install_gitlab_plugin "$DATA_DIR" "$GITLAB_PLUGIN_REPO_PATH"; then
  pass "installed workflow-plugin-gitlab as external plugin"
else
  fail "could not build/install workflow-plugin-gitlab"
  finish
  exit 1
fi

SERVER_LOG="$SCRIPT_DIR/artifacts/last-server.log"
if ! mkdir -p "$(dirname "$SERVER_LOG")"; then
  fail "could not create server log directory"
  finish
  exit 1
fi
"$SERVER_BIN" -config "$CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
sleep 0.1
if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
  fail "workflow server process exited immediately; see $SERVER_LOG"
  finish
  exit 1
fi

if wait_for_server "$BASE_URL"; then
  pass "workflow server started and served /healthz"
else
  fail "workflow server did not become ready; see $SERVER_LOG"
  finish
  exit 1
fi

PROJECT="scenario/29-service"
REF="feature/runtime-client"
TARGET="main"
TITLE="Scenario 29 runtime merge request"
COMMENT="Scenario 29 runtime comment"

WEBHOOK_BODY="$(jq -n --arg project "$PROJECT" --arg ref "$REF" '{object_kind:"push", event_name:"push", ref:$ref, project:{path_with_namespace:$project}, user_username:"caller-a"}')"
WEBHOOK="$(post_json "/webhooks/gitlab" "$WEBHOOK_BODY")" \
  && pass "client posted GitLab webhook through Workflow API" \
  || fail "GitLab webhook API failed"
if printf '%s' "$WEBHOOK" | jq -e --arg project "$PROJECT" --arg ref "$REF" '.parsed == true and .payload.object_kind == "push" and .payload.ref == $ref and .payload.project.path_with_namespace == $project' >/dev/null 2>&1; then
  pass "webhook response preserved caller-supplied project and ref"
else
  fail "webhook response mismatch: $WEBHOOK"
fi

TRIGGER_BODY="$(jq -n --arg project "$PROJECT" --arg ref "$REF" '{project:$project, ref:$ref, variables:{DEPLOY_ENV:"review", SOURCE:"scenario-29"}}')"
TRIGGERED="$(post_json "/api/v1/gitlab/trigger" "$TRIGGER_BODY")" \
  && pass "client triggered GitLab pipeline through Workflow API" \
  || fail "GitLab trigger API failed"
if printf '%s' "$TRIGGERED" | jq -e --arg ref "$REF" '.pipeline_id == 42 and .status == "created" and .ref == $ref and (.web_url | contains("scenario/29-service"))' >/dev/null 2>&1; then
  pass "pipeline trigger used dynamic request project/ref with module-backed mock client"
else
  fail "pipeline trigger response mismatch: $TRIGGERED"
fi

STATUS_BODY="$(jq -n --arg project "$PROJECT" '{project:$project, pipeline_id:42}')"
STATUS="$(post_json "/api/v1/gitlab/pipeline/status" "$STATUS_BODY")" \
  && pass "client fetched GitLab pipeline status through Workflow API" \
  || fail "GitLab status API failed"
if printf '%s' "$STATUS" | jq -e '.pipeline_id == 42 and .status == "success" and .ref == "main"' >/dev/null 2>&1; then
  pass "pipeline status used dynamic request pipeline id"
else
  fail "pipeline status response mismatch: $STATUS"
fi

MR_BODY="$(jq -n --arg project "$PROJECT" --arg source "$REF" --arg target "$TARGET" --arg title "$TITLE" '{project:$project, source_branch:$source, target_branch:$target, title:$title}')"
MR="$(post_json "/api/v1/gitlab/mr" "$MR_BODY")" \
  && pass "client created GitLab MR through Workflow API" \
  || fail "GitLab create MR API failed"
if printf '%s' "$MR" | jq -e --arg source "$REF" --arg target "$TARGET" --arg title "$TITLE" '.mr_iid == 1 and .state == "opened" and .source_branch == $source and .target_branch == $target and .title == $title' >/dev/null 2>&1; then
  pass "MR response reflected caller-supplied branches and title"
else
  fail "MR response mismatch: $MR"
fi

COMMENT_BODY="$(jq -n --arg project "$PROJECT" --arg body "$COMMENT" '{project:$project, mr_iid:1, body:$body}')"
COMMENTED="$(post_json "/api/v1/gitlab/mr/comment" "$COMMENT_BODY")" \
  && pass "client posted GitLab MR comment through Workflow API" \
  || fail "GitLab MR comment API failed"
if printf '%s' "$COMMENTED" | jq -e --arg project "$PROJECT" '.commented == true and .project == $project and .mr_iid == 1' >/dev/null 2>&1; then
  pass "MR comment response reflected caller-supplied project and MR id"
else
  fail "MR comment response mismatch: $COMMENTED"
fi

finish
