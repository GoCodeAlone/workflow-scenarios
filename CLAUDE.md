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

`workflow-scenarios` should track released `GoCodeAlone/workflow` versions. The
`Bump Workflow Release` GitHub Action opens a PR when a newer Workflow release
is available; it can be triggered by `repository_dispatch` type
`workflow-release`, manually with `workflow_dispatch`, or by its scheduled
fallback.

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

## Proof Standard

Every scenario that claims application behavior must exercise one or more
Workflow modules through a real Workflow app boundary. Launch/build the app from
scenario config, drive it through API, trigger, CLI, or pipeline boundaries, and
use actor/resource IDs supplied by the client or test harness instead of baking
one hard-coded interaction into the pipeline.

`wfctl pipeline run` and package tests are valid supporting checks, but they are
not enough for multi-client communication, persistence, plugin interoperability,
or end-to-end application claims. Plugin scenarios should load plugins through
Workflow's plugin mechanism. Document mocks, emulators, fixture pools, and any
live-boundary approval in the scenario README and test output.

`make test SCENARIO=...` updates shared `scenarios.json`; run scenario tests
sequentially unless the harness explicitly provides isolated state or locking.

Scenario tests must exercise a Workflow application path. Prefer a deployed
`workflow-server` or another path that builds a Workflow engine from scenario
configuration and drives the app through its real API, trigger, CLI, or event
boundary. `wfctl pipeline run` and `wfctl test` are acceptable when the
scenario itself is a pipeline/tooling contract; they are not sufficient for
scenarios that claim multi-client communication, collaboration, auth, storage,
or other application behavior. Package tests, library unit tests, schema
validation, and generated fixture checks are supporting evidence only; they are
not sufficient by themselves for a `workflow-scenarios` entry.

When a scenario covers a Workflow plugin, load the plugin through Workflow's
plugin mechanism and execute it from `config/app.yaml`. For external services
or storage providers, use committed mocks, fakes, local emulators, or an
explicitly approved live environment, and document that boundary in the
scenario README and test script.

Application scenario workflows should be actor/resource-parametric. A config may
declare a pool of known local identities, tenants, stores, or fixtures, but
pipelines should take participant/resource IDs from route params, request
bodies, events, or CLI inputs instead of hard-coding a single demo interaction.
