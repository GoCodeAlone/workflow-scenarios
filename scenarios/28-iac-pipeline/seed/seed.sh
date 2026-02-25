#!/usr/bin/env bash
# Seed script for Scenario 28: IaC Pipeline
# State is managed by the iac.state module — no external seeding needed.
set -euo pipefail

echo "Scenario 28 seed: iac.state uses filesystem backend (PVC-backed)."
echo "Infrastructure state for 'production-cluster' starts empty."
echo "Use the IaC pipeline endpoints to plan/apply/destroy."
echo "Done."
