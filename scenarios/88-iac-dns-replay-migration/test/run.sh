#!/usr/bin/env bash
# Scenario 88 — DNS/IaC replay migration.
set -uo pipefail

SCENARIO="88-iac-dns-replay-migration"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURE="$SCENARIO_DIR/fixtures/dns-portfolio.json"

echo ""
echo "=== Scenario $SCENARIO ==="
echo ""

python3 "$SCRIPT_DIR/validate_dns_replay.py" "$FIXTURE"
