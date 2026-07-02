#!/usr/bin/env bash
# Seed script for Scenario 35: Multi-Cloud Accounts (AWS, GCP, Azure)
# No database seeding required; cloud accounts are configured via app.yaml and
# selected by test clients at runtime through the Workflow HTTP API.
set -euo pipefail

NS="${NAMESPACE:-wf-scenario-35}"
PORT=18035
BASE="http://localhost:$PORT"

echo "Scenario 35 seed: cloud.account has no database to seed."
echo "Accounts configured in app.yaml: aws-prod (mock), gcp-prod (gcp), azure-prod (azure)"
echo "test/run.sh discovers accounts from the Workflow API and validates the selected providers."
echo "Done."
