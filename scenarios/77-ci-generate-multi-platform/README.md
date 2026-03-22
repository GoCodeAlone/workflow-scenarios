# Scenario 77: CI Generate Multi-Platform

Config-validation scenario for generating CI/CD configs for GitHub Actions and GitLab CI in the same workflow config.

## What it tests

- `ci.generator` with `provider: github` — outputs `.github/workflows/ci.yml`, runner: ubuntu-24.04
- `ci.generator` with `provider: gitlab` — outputs `.gitlab-ci.yml`, image: golang:1.22-alpine
- `step.ci_generate` for both platforms: test, lint, build, deploy-staging, deploy-production jobs/stages
- `step.ci_validate` to check generated files
- `step.ci_diff` against baselines
- Pipelines: generate-github, generate-gitlab, generate-all (both at once), diff-ci

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live CI execution required.
