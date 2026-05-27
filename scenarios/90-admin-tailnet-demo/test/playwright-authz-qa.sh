#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:18080}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/workflow-admin-authz-qa}"
ADMIN_JAR="$(mktemp)"
USER_JAR="$(mktemp)"
ADMIN_STATE="$(mktemp)"
USER_STATE="$(mktemp)"
trap 'rm -f "$ADMIN_JAR" "$USER_JAR" "$ADMIN_STATE" "$USER_STATE"' EXIT

mkdir -p "$ARTIFACT_DIR"

login() {
  local jar="$1"
  local email="$2"
  local password="$3"
  curl -fsS -c "$jar" -d "email=$email&password=$password" "$BASE/login" >/dev/null
}

storage_state() {
  local jar="$1"
  local output="$2"
  local token
  token="$(awk '$6 == "wf_demo_session" { print $7 }' "$jar" | tail -n 1)"
  if [ -z "$token" ]; then
    echo "missing wf_demo_session cookie" >&2
    exit 1
  fi
  cat >"$output" <<JSON
{"cookies":[{"name":"wf_demo_session","value":"$token","domain":"127.0.0.1","path":"/","httpOnly":true,"secure":false,"sameSite":"Lax"}],"origins":[]}
JSON
}

login "$ADMIN_JAR" "admin@tailnet" "admin"
storage_state "$ADMIN_JAR" "$ADMIN_STATE"

playwright screenshot \
  --load-storage "$ADMIN_STATE" \
  --wait-for-selector 'text=ABAC Policies' \
  --full-page \
  "$BASE/admin/authz" \
  "$ARTIFACT_DIR/admin-authz-desktop.png" >/dev/null

playwright screenshot \
  --load-storage "$ADMIN_STATE" \
  --viewport-size "390,844" \
  --wait-for-selector '.scope-picker' \
  "$BASE/admin/authz" \
  "$ARTIFACT_DIR/admin-authz-mobile.png" >/dev/null

login "$USER_JAR" "app-user@tailnet" "user"
storage_state "$USER_JAR" "$USER_STATE"

playwright screenshot \
  --load-storage "$USER_STATE" \
  --wait-for-selector 'text=Forbidden' \
  "$BASE/admin" \
  "$ARTIFACT_DIR/frontend-user-forbidden.png" >/dev/null

echo "Playwright authz QA screenshots written to $ARTIFACT_DIR"
