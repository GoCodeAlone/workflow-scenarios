#!/usr/bin/env bash
# Seed script for Scenario 33: API Gateway and Autoscaling
# No database seeding required; the scenario proves app-boundary behavior by
# starting workflow-server with workflow-plugin-aws and sending runtime specs.
set -euo pipefail

echo "Scenario 33 seed: no static AWS resources are preloaded."
echo "test/run.sh supplies gateway and autoscaling specs through the Workflow HTTP API."
echo "The workflow-plugin-aws provider runs in local mock mode and stores state in the app data dir."
echo "Done."
