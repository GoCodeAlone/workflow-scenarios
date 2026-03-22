# Scenario 70: IaC Deployment Blue-Green

Config-validation scenario for blue-green deployments using two `infra.container_service` modules and `step.deploy_blue_green`.

## What it tests

- `iac.provider` with `provider: aws`
- `iac.state` with `backend: memory`
- `infra.container_service` — blue (app-blue, myapp:stable) and green (app-green, myapp:latest) slots
- `infra.load_balancer` with health check configuration
- `step.deploy_blue_green` with blueService, greenService, loadBalancer, and cutover delay
- `step.deploy_verify` for health check validation
- Pipelines: deploy-blue-green (cutover to green), rollback (revert to blue)

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live cloud credentials or k8s required.
