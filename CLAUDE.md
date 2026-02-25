# CLAUDE.md — Workflow Scenarios

Persistent regression and resiliency test harness for the workflow ecosystem.

## Quick Start

```bash
make list                          # Show all scenarios and their status
make deploy SCENARIO=01-idp        # Deploy a scenario
make test SCENARIO=01-idp          # Run tests for a scenario
make status                        # Show all scenario status
make status SCENARIO=01-idp        # Show specific scenario status
make teardown SCENARIO=01-idp      # Teardown (preserves data)
make upgrade COMPONENT=workflow VERSION=v0.3.0  # Upgrade + re-test
make test-all                      # Run all available tests
```

## Architecture

Each scenario deploys to its own namespace (`wf-scenario-<id>`).
PVCs persist across upgrades/teardowns for data durability.
`scenarios.json` tracks deployed state, versions, and test results.

## Prerequisites

- minikube running with workflow-server:local image loaded
- kubectl configured to point at minikube
- python3 available (used by status scripts)
- Scenarios 01-02 require `workflow-server:local` image in minikube

## Adding a New Scenario

1. Create `scenarios/<id>-<name>/scenario.yaml`
2. Add k8s manifests in `scenarios/<id>-<name>/k8s/`
3. Add workflow engine config in `scenarios/<id>-<name>/config/app.yaml`
4. Add seed data in `scenarios/<id>-<name>/seed/seed.sh`
5. Write tests in `scenarios/<id>-<name>/test/run.sh` using `PASS:` / `FAIL:` prefixes
6. Add entry to `scenarios.json`
