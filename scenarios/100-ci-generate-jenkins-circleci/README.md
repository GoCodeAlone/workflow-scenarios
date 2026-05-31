# Scenario 100 — CI Generate Jenkins + CircleCI (config-derived)

Behavior proof for [workflow#804](https://github.com/GoCodeAlone/workflow/issues/804):
`wfctl ci generate --platform jenkins` and `--platform circleci` now produce
**config-derived** CI output through the cigen `analyze → CIPlan → render`
pipeline — the same path GitHub Actions and GitLab CI use — replacing the legacy
non-config-derived template generators.

## What it proves

The harness runs the **real** `wfctl ci generate` against `config/deploy.yaml` (a
config that exercises every cigen derivation) and asserts the emitted artifacts
are config-derived, not static templates:

| Derivation | Jenkinsfile | .circleci/config.yml |
|---|---|---|
| Secret wiring | `credentials('APP_DB_URL')` (per-stage `environment{}`) | project env vars (auto-injected; referenced) |
| Migrations | `wfctl migrations up` (never `wfctl ci run --phase migrate`) | same |
| Smoke | `curl --fail … https://myapp.example.com/healthz` | same |
| Plan-guard | grep replace/destroy → `exit 1` (no `\|\| true`) | same |
| Apply | `wfctl infra apply` | same |

It also asserts the **retired** legacy stages are ABSENT (`go test ./...`,
`wfctl deploy --image`, `docker build`) per
[ADR 0044](https://github.com/GoCodeAlone/workflow/blob/main/decisions/0044-cigen-renderers-omit-legacy-build-deploy-stages.md),
and that a `step.ci_generate` config targeting jenkins/circleci validates
(config-shape half of acceptance #2; the behavior half is the ci-generator
plugin's `integration_test.go`).

## Running

```bash
# Build wfctl from a workflow checkout that has the cigen jenkins/circleci
# renderers (workflow >= v0.68.0), then:
WFCTL_BIN=/path/to/wfctl bash scenarios/100-ci-generate-jenkins-circleci/test/run.sh
```

The harness `skip`s cleanly if no suitable wfctl is found. No live
Jenkins/CircleCI server is required (generate-and-assert posture).

Latest local run: `test/artifacts/last-run.log` — **22 passed, 0 failed**.
