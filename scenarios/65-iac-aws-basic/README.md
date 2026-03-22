# Scenario 65: IaC AWS Basic

Config-validation scenario for a basic AWS infrastructure stack using the workflow IaC module types.

## What it tests

- `iac.provider` with `provider: aws` and `credentials: env`
- `iac.state` with `backend: memory`
- `infra.vpc` — VPC with CIDR 10.1.0.0/16 in us-east-1
- `infra.database` — RDS PostgreSQL 16 (db.t3.micro)
- `infra.container_service` — ECS Fargate, nginx:latest, 2 replicas
- IaC lifecycle pipelines: plan, apply, status, destroy

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live cloud credentials or k8s required.
