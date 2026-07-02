# workflow-scenarios

Persistent regression and resiliency scenarios for the Workflow ecosystem.

## Scenario Proof Standard

Scenarios must exercise one or more Workflow modules through a Workflow
application boundary. A valid application scenario launches or builds a Workflow
app from scenario configuration and drives it through real API, trigger, CLI, or
pipeline boundaries.

`wfctl pipeline run` and package tests are useful supporting checks, but they
are not enough for scenarios that claim application behavior, multi-client
communication, persistence, or plugin interoperability. Those scenarios should
accept actor/resource IDs as inputs and avoid baking a single demo conversation
or fixture result into the pipeline.

Plugin scenarios should load plugins through Workflow's plugin mechanism. Mocks,
emulators, fixture pools, and live-boundary approvals must be documented in the
scenario README and test output.

`make test SCENARIO=...` updates shared `scenarios.json`; run scenario tests
sequentially unless the harness explicitly provides isolated state or locking.
