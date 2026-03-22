# Scenario 66: IaC Multi-Cloud

Config-validation scenario demonstrating provider-agnostic IaC configuration. The same `app.yaml` targets either AWS or DigitalOcean by setting the `IAC_PROVIDER` environment variable.

## What it tests

- `iac.provider` with a config-templated `provider` field (reads `IAC_PROVIDER`)
- `iac.state` with `backend: memory`
- `infra.vpc`, `infra.database`, `infra.container_service` all referencing the same `cloud-provider` module
- `wfctl validate` passes with both `IAC_PROVIDER=aws` and `IAC_PROVIDER=digitalocean`
- IaC lifecycle pipelines: plan, apply, status, destroy

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live cloud credentials or k8s required.
