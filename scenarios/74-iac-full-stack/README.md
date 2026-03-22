# Scenario 74: IaC Full Stack

Config-validation scenario exercising all 13 `infra.*` module types in a single config.

## What it tests

All infra module types:
- `infra.vpc` — VPC with subnets across two AZs
- `infra.database` — PostgreSQL 16, multi-AZ, 7-day backup
- `infra.cache` — Redis 7.2 with replica
- `infra.container_service` — Fargate, 4 replicas
- `infra.load_balancer` — Application load balancer with health check
- `infra.dns` — Route53 zone with A record
- `infra.registry` — ECR with scan-on-push
- `infra.firewall` — Inbound 443/80 + outbound all rules
- `infra.iam_role` — Role with S3 + CloudWatch policies
- `infra.storage` — S3 bucket with versioning and lifecycle rules
- `infra.certificate` — ACM cert with DNS validation for wildcard domain
- `infra.cdn` — CloudFront distribution with custom domain
- `infra.secret` — Secrets Manager with 3 keys
- Pipelines: stack-plan, stack-apply

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live cloud credentials or k8s required.
