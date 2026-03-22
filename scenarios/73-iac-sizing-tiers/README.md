# Scenario 73: IaC Sizing Tiers

Config-validation scenario testing all 5 sizing tiers for `infra.database` and `infra.container_service`.

## What it tests

- `infra.database` at sizes: `xs`, `s`, `m`, `l`, `xl` (PostgreSQL 16, AWS RDS)
- `infra.container_service` at sizes: `xs`, `s`, `m`, `l`, `xl` (Fargate, replicas scale with tier)
- Resource hint overrides on `xl` tier: `cpu`, `memory`, `storage` fields
- `iac.provider` with `provider: aws` and `iac.state` with `backend: memory`
- Pipelines: list-tiers (inventory), plan-all (spot-checks xs and xl)

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live cloud credentials or k8s required.
