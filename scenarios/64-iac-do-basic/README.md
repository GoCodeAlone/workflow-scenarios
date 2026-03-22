# Scenario 64: IaC DigitalOcean Basic

Config-validation scenario for a basic DigitalOcean infrastructure stack using the workflow IaC module types.

## What it tests

- `iac.provider` with `provider: digitalocean` and `credentials: env`
- `iac.state` with `backend: memory`
- `infra.vpc` — VPC with CIDR 10.0.0.0/16 in nyc3
- `infra.database` — managed PostgreSQL 16 (size: db-s-1vcpu-1gb)
- `infra.container_service` — nginx:latest, 2 replicas
- IaC lifecycle pipelines: plan, apply, status, destroy

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live cloud credentials or k8s required.
