# Scenario 71: IaC Deployment Canary

Config-validation scenario for canary deployments with metric-gated staged rollout (5% → 25% → 100%).

## What it tests

- `iac.provider` with `provider: gcp`
- `iac.state` with `backend: memory`
- `infra.container_service` — stable (app-stable) and canary (app-canary) services on Cloud Run
- `step.deploy_canary` with multi-stage rollout and metric gates (error_rate, p99_latency_ms)
- `step.deploy_verify` for canary health check
- Pipelines: deploy-canary (staged rollout), canary-promote (full cutover), canary-abort (roll back)

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live cloud credentials or k8s required.
