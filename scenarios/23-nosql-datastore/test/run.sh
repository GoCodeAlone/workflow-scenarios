#!/usr/bin/env bash
# Scenario 23: NoSQL Data Store.
#
# Demonstration-fidelity: this starts the real Workflow server from the
# scenario config and drives the in-memory NoSQL module through HTTP API calls.
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18123}"
ITEM_ID="${ITEM_ID:-item-23-a}"
ITEM_NAME="${ITEM_NAME:-Workflow scenario item}"
ITEM_KIND="${ITEM_KIND:-scenario-proof}"

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
echo "=== Scenario 23: NoSQL Data Store ==="
echo ""

[ -f "$CONFIG" ] && pass "Workflow app config exists" || fail "Workflow app config missing"
if sed '/^[[:space:]]*#/d' "$SCRIPT_DIR/run.sh" | grep -Eq '(^|[;&|[:space:]])go[[:space:]]+test'; then
  fail "scenario test should not delegate proof to Go package tests"
else
  pass "scenario test exercises the Workflow app boundary"
fi
if grep -Eq 'item-23-a|Workflow scenario item' "$CONFIG"; then
  fail "Workflow config should not hard-code the test item"
else
  pass "Workflow API accepts item data from client requests"
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

CREATE_BODY="$(jq -cn --arg id "$ITEM_ID" --arg name "$ITEM_NAME" --arg kind "$ITEM_KIND" \
  '{id:$id,name:$name,kind:$kind,active:true,revision:1}')" || CREATE_BODY=""
CREATED="$(curl -fsS -X POST "$BASE_URL/api/items" -H 'Content-Type: application/json' -d "$CREATE_BODY")" \
  && pass "client created an item through Workflow API" \
  || fail "create item API failed"

if printf '%s' "$CREATED" | jq -e --arg key "item:$ITEM_ID" '.stored == true and .key == $key and .item.id == ($key | sub("^item:"; ""))' >/dev/null 2>&1; then
  pass "create response contained stored item key and body"
else
  fail "create response did not contain expected item: $CREATED"
fi

LISTED="$(curl -fsS "$BASE_URL/api/items")" \
  && pass "client listed items through Workflow API" \
  || fail "list items API failed"
if printf '%s' "$LISTED" | jq -e --arg id "$ITEM_ID" '.count == 1 and (.items[] | select(.id == $id))' >/dev/null 2>&1; then
  pass "list response contained the created item"
else
  fail "list response missing created item: $LISTED"
fi

FETCHED="$(curl -fsS "$BASE_URL/api/items/$ITEM_ID")" \
  && pass "client fetched item by ID through Workflow API" \
  || fail "get item API failed"
if printf '%s' "$FETCHED" | jq -e --arg id "$ITEM_ID" --arg name "$ITEM_NAME" '.found == true and .item.id == $id and .item.name == $name' >/dev/null 2>&1; then
  pass "get response returned the stored item"
else
  fail "get response mismatch: $FETCHED"
fi

DELETED="$(curl -fsS -X DELETE "$BASE_URL/api/items/$ITEM_ID")" \
  && pass "client deleted item by ID through Workflow API" \
  || fail "delete item API failed"
if printf '%s' "$DELETED" | jq -e --arg key "item:$ITEM_ID" '.deleted == true and .key == $key' >/dev/null 2>&1; then
  pass "delete response contained deleted item key"
else
  fail "delete response mismatch: $DELETED"
fi

MISSING="$(curl -fsS "$BASE_URL/api/items/$ITEM_ID")" \
  && pass "client re-fetched deleted item through Workflow API" \
  || fail "get deleted item API failed"
if printf '%s' "$MISSING" | jq -e '.found == false and (.item | type == "object") and (.item | length == 0)' >/dev/null 2>&1; then
  pass "deleted item is no longer present"
else
  fail "deleted item still appears present: $MISSING"
fi

finish
