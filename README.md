# Workflow Scenarios

Persistent regression and resiliency scenarios for the Workflow ecosystem.

## Scenario Proof Standard

A scenario must exercise a Workflow application path. Prefer a deployed
`workflow-server` or another path that builds a Workflow engine from scenario
configuration and then drives it through the same API, trigger, CLI, or event
boundary an application user would use. `wfctl pipeline run` and `wfctl test`
are acceptable when the scenario itself is a pipeline/tooling contract; they are
not sufficient for scenarios that claim multi-client communication,
collaboration, auth, storage, or other application behavior.

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

Application scenarios should be actor/resource-parametric. It is acceptable for
the app config to define a pool of known local identities, tenants, stores, or
fixtures required by the engine, but workflows should not bake a single demo
conversation such as "Alice sends exactly this message to Bob" into their step
graph. The test runner should choose participant/resource IDs and submit
requests as clients. Hard-coded values belong only to explicit fixtures, vector
data, mock endpoints, and other documented test inputs.

## Running

```bash
make list
make test SCENARIO=104-signal-e2e-encryption
make test SCENARIO=105-encrypted-spaces-proof-workflow
```
