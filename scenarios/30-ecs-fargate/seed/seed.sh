#!/usr/bin/env bash
# Seed script for Scenario 30: ECS Fargate
# No database seeding required — ECS service state is tracked in-memory.
set -euo pipefail

echo "Scenario 30 seed: infra.container_service uses IaC state, no seeding needed."
echo "ECS service 'staging-ecs' starts in 'pending' status."
echo "Done."
