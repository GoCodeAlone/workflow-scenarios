# Scenario 68: CI Generator

Config-validation scenario for the `ci.generator` plugin that produces GitHub Actions and GitLab CI workflow files from a workflow engine config.

## What it tests

- `ci.generator` with `provider: github` — emits `.github/workflows/ci.yml`
- `ci.generator` with `provider: gitlab` — emits `.gitlab-ci.yml`
- `step.ci_generate` steps for both providers with job/stage definitions
- `step.ci_validate` — validates a generated CI file's syntax
- `step.ci_diff` — compares generated output against a baseline file

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live CI execution or cloud credentials required.
