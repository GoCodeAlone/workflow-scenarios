# Scenario 69: IaC Deployment Rolling

Config-validation scenario for rolling deployments using `infra.container_service` and `step.deploy_rolling`.

## What it tests

- `iac.provider` with `provider: digitalocean`
- `iac.state` with `backend: memory`
- `infra.container_service` with `rollingUpdate` config (maxSurge, maxUnavailable, healthCheckPath)
- `step.deploy_rolling` referencing the container service by name
- `step.deploy_verify` for post-deploy health check
- Pipelines: deploy-rolling, deploy-status

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live cloud credentials or k8s required.
