# Scenario 75: Deployment Pipeline

Config-validation scenario for a complete end-to-end CI/CD deployment pipeline in a single workflow config.

## What it tests

Pipeline sequence:
1. `step.iac_plan` — plan infra changes
2. `step.iac_apply` — apply infra provisioning
3. `step.container_build` — build + push Docker image to registry
4. `step.deploy_rolling` — rolling deploy to container service
5. `step.deploy_verify` — health check post-deploy

Also tests:
- `infra.registry` (DigitalOcean Container Registry) referenced by container_build
- `infra.container_service` with rolling update policy
- Rollback pipeline: `step.deploy_rolling` with stable image tag

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live cloud credentials or k8s required.
