# Scenario 78: Infra Module Wiring

Config-validation scenario testing the `iac.provider` → `infra.*` → `step.iac_*` dependency chain.

## What it tests

- `iac.provider` named `aws-provider` as the root delegation target
- `iac.state` named `iac-state` as the shared state store
- `infra.vpc`, `infra.database`, `infra.container_service` all explicitly referencing `provider: aws-provider`
- `step.iac_plan`, `step.iac_apply`, `step.iac_status` all referencing `state_store: iac-state`
- Pipelines: plan-all, apply-all, status-check — all routing through the same provider/state chain

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live cloud credentials or k8s required.
