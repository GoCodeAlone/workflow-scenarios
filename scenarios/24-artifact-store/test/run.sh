#!/usr/bin/env bash
# Scenario 24: Artifact Store.
#
# Demonstration-fidelity: this starts the real Workflow server from the
# scenario config and drives storage.artifact through HTTP API calls.
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18124}"
ARTIFACT_OWNER="${ARTIFACT_OWNER:-client-a}"
ARTIFACT_VERSION="${ARTIFACT_VERSION:-v1}"
ARTIFACT_PREFIX="${ARTIFACT_PREFIX:-builds/scenario-24}"
ARTIFACT_ID="${ARTIFACT_ID:-artifact-$(date +%s)}"
ARTIFACT_KEY="${ARTIFACT_KEY:-$ARTIFACT_PREFIX/$ARTIFACT_ID/app.bin}"
ARTIFACT_TEXT="${ARTIFACT_TEXT:-Workflow artifact scenario payload from $ARTIFACT_OWNER}"
ARTIFACT_TYPE="${ARTIFACT_TYPE:-application/octet-stream}"

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

echo ""
echo "=== Scenario 24: Artifact Store ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if sed '/^[[:space:]]*#/d' "$SCRIPT_DIR/run.sh" | grep -Eq '(^|[;&|[:space:]])go[[:space:]]+test'; then
  fail "scenario test should not delegate proof to Go package tests"
else
  pass "scenario test exercises the Workflow app boundary"
fi
if grep -Eq 'artifact-[0-9]+|Workflow artifact scenario payload|client-a' "$CONFIG"; then
  fail "Workflow config should not hard-code the test artifact"
else
  pass "Workflow API accepts artifact identity and content from client requests"
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
(cd "$DATA_DIR" && "$SERVER_BIN" -config "$CONFIG" -data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1) &
SERVER_PID=$!

if wait_for_server "$BASE_URL"; then
  pass "workflow server started and served /healthz"
else
  fail "workflow server did not become ready; see $SERVER_LOG"
  finish
  exit 1
fi

CONTENT_B64="$(printf '%s' "$ARTIFACT_TEXT" | base64 | tr -d '\n')"
UPLOAD_BODY="$(jq -cn \
  --arg key "$ARTIFACT_KEY" \
  --arg content_b64 "$CONTENT_B64" \
  --arg owner "$ARTIFACT_OWNER" \
  --arg version "$ARTIFACT_VERSION" \
  --arg content_type "$ARTIFACT_TYPE" \
  '{key:$key,content_b64:$content_b64,owner:$owner,version:$version,content_type:$content_type}')" || UPLOAD_BODY=""

UPLOADED="$(curl -fsS -X POST "$BASE_URL/api/artifacts" -H 'Content-Type: application/json' -d "$UPLOAD_BODY")" \
  && pass "client uploaded artifact content through Workflow API" \
  || fail "upload artifact API failed"
if printf '%s' "$UPLOADED" | jq -e --arg key "$ARTIFACT_KEY" --argjson size "${#ARTIFACT_TEXT}" \
  '.uploaded == true and .key == $key and .size == $size' >/dev/null 2>&1; then
  pass "upload response contained artifact key and byte size"
else
  fail "upload response mismatch: $UPLOADED"
fi

LIST_BODY="$(jq -cn --arg prefix "$ARTIFACT_PREFIX" '{prefix:$prefix}')"
LISTED="$(curl -fsS -X POST "$BASE_URL/api/artifacts/list" -H 'Content-Type: application/json' -d "$LIST_BODY")" \
  && pass "client listed artifacts by prefix through Workflow API" \
  || fail "list artifacts API failed"
if printf '%s' "$LISTED" | jq -e --arg key "$ARTIFACT_KEY" --arg owner "$ARTIFACT_OWNER" \
  '.count == 1 and (.artifacts[] | select(.key == $key and .metadata.owner == $owner))' >/dev/null 2>&1; then
  pass "list response contained uploaded artifact metadata"
else
  fail "list response missing uploaded artifact: $LISTED"
fi

KEY_BODY="$(jq -cn --arg key "$ARTIFACT_KEY" '{key:$key}')"
DOWNLOADED="$(curl -fsS -X POST "$BASE_URL/api/artifacts/download" -H 'Content-Type: application/json' -d "$KEY_BODY")" \
  && pass "client downloaded artifact content through Workflow API" \
  || fail "download artifact API failed"
if printf '%s' "$DOWNLOADED" | jq -e \
  --arg key "$ARTIFACT_KEY" \
  --arg content_b64 "$CONTENT_B64" \
  --arg owner "$ARTIFACT_OWNER" \
  '.key == $key and .content_b64 == $content_b64 and .metadata.owner == $owner' >/dev/null 2>&1; then
  pass "download response returned original content and metadata"
else
  fail "download response mismatch: $DOWNLOADED"
fi

DELETED="$(curl -fsS -X POST "$BASE_URL/api/artifacts/delete" -H 'Content-Type: application/json' -d "$KEY_BODY")" \
  && pass "client deleted artifact through Workflow API" \
  || fail "delete artifact API failed"
if printf '%s' "$DELETED" | jq -e --arg key "$ARTIFACT_KEY" '.deleted == true and .key == $key' >/dev/null 2>&1; then
  pass "delete response contained deleted artifact key"
else
  fail "delete response mismatch: $DELETED"
fi

LISTED_AFTER_DELETE="$(curl -fsS -X POST "$BASE_URL/api/artifacts/list" -H 'Content-Type: application/json' -d "$LIST_BODY")" \
  && pass "client listed artifacts after delete through Workflow API" \
  || fail "list after delete API failed"
if printf '%s' "$LISTED_AFTER_DELETE" | jq -e '.count == 0 and (.artifacts | length == 0)' >/dev/null 2>&1; then
  pass "deleted artifact is no longer listed"
else
  fail "deleted artifact still appears present: $LISTED_AFTER_DELETE"
fi

finish
