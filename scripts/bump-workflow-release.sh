#!/usr/bin/env bash
set -euo pipefail

module="github.com/GoCodeAlone/workflow"
target="${WORKFLOW_VERSION:-${1:-}}"

if [ -z "$target" ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh is required when WORKFLOW_VERSION is not set" >&2
    exit 2
  fi
  target="$(gh release view --repo GoCodeAlone/workflow --json tagName --jq .tagName)"
fi

if [ -z "$target" ]; then
  echo "workflow release tag is empty" >&2
  exit 2
fi

current="$(GOWORK=off go list -m -f '{{.Version}}' "$module")"
echo "workflow current=$current target=$target"

if [ "$current" = "$target" ]; then
  echo "workflow is already pinned to $target"
  exit 0
fi

GOWORK=off go get "$module@$target"
GOWORK=off go mod tidy
GOWORK=off go test ./...
