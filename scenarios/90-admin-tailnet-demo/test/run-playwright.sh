#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLAYWRIGHT_PREFIX="${PLAYWRIGHT_PREFIX:-/tmp/scenario90-playwright-cli}"

if [ ! -x "$PLAYWRIGHT_PREFIX/node_modules/.bin/playwright" ]; then
  npm --prefix "$PLAYWRIGHT_PREFIX" install --silent @playwright/test
fi

npx --prefix "$PLAYWRIGHT_PREFIX" playwright install chromium

export NODE_PATH
NODE_PATH="$(npm root --prefix "$PLAYWRIGHT_PREFIX")"

npx --prefix "$PLAYWRIGHT_PREFIX" playwright test --config="$SCRIPT_DIR/playwright.config.cjs" "$@"
