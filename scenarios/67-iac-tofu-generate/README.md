# Scenario 67: IaC OpenTofu HCL Generation

Config-validation scenario for the `tofu.generator` plugin that translates workflow infra module definitions into OpenTofu `.tf` HCL files.

## What it tests

- `tofu.generator` module with `outputDir`, `providerSource`, `backendType`
- `iac.provider` with `provider: aws`
- `iac.state` with `backend: memory`
- `infra.vpc`, `infra.database`, `infra.container_service` modules
- `step.tofu_generate` steps producing `vpc.tf`, `database.tf`, `ecs.tf`
- `step.tofu_validate` and `step.tofu_plan` pipeline steps

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live Tofu execution or cloud credentials required.
