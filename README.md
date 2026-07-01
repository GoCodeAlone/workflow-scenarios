# Workflow Scenarios

Persistent regression and resiliency scenarios for the Workflow ecosystem.

## Scenario Proof Standard

A scenario must exercise a Workflow application path. Prefer `wfctl pipeline
run`, `wfctl test`, a deployed `workflow-server`, or another path that builds a
Workflow engine from scenario configuration and runs one or more modules,
triggers, or pipeline steps.

Package tests, library unit tests, schema validation, and generated fixture
checks are useful supporting evidence, but they are not sufficient by
themselves for a `workflow-scenarios` entry. If a scenario covers a Workflow
plugin, it should load the plugin through Workflow's plugin mechanism and
execute the plugin from a Workflow app config.

Scenarios that would normally require external services or object stores should
use committed mocks, fakes, local emulators, or explicitly approved live
environments. A scenario that claims to cover S3, Signal, SaaS APIs, or similar
dependencies must make the dependency boundary clear in its README and test
script.

## Running

```bash
make list
make test SCENARIO=104-signal-e2e-encryption
make test SCENARIO=105-encrypted-spaces-proof-workflow
```
