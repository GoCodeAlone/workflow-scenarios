#!/usr/bin/env bash
# Seed script for Scenario 25: Cloud Account
# No database seeding required — cloud accounts are configured via app.yaml.
set -euo pipefail

NS="${NAMESPACE:-wf-scenario-25}"
PORT=18025
BASE="http://localhost:$PORT"

echo "Scenario 25 seed: cloud.account has no database to seed."
echo "Accounts configured in app.yaml: aws-production, aws-staging, local-k8s"
echo "Done."
