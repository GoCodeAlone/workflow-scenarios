# Workflow Release Bump Automation

## Goal

Keep `workflow-scenarios` close to the latest `GoCodeAlone/workflow` release so
scenario coverage exercises current Workflow and wfctl behavior.

## Design

Add a release-bump workflow with three entry points:

- `repository_dispatch` type `workflow-release`, for a future direct dispatch
  from the `workflow` release pipeline;
- `workflow_dispatch`, for manual bump or retry with an explicit tag;
- a six-hour scheduled fallback, so a missed dispatch still opens a bump PR.

The workflow runs `scripts/bump-workflow-release.sh`, which resolves the target
release, compares it to the root module pin using `GOWORK=off`, runs
`go get github.com/GoCodeAlone/workflow@<tag>`, runs `go mod tidy`, verifies
`GOWORK=off go test ./...`, and opens a PR only when the pin changed.

## Assumptions

- `workflow-scenarios` should test released Workflow versions rather than
  arbitrary `main` commits.
- `GOWORK=off` is required because this workspace may have a parent `go.work`
  that masks the repo's actual module pin.
- `RELEASES_TOKEN` or `GITHUB_TOKEN` can fetch private `GoCodeAlone` modules in
  GitHub Actions.

## Rollback

Disable `.github/workflows/bump-workflow-release.yml` or revert the bump PR. No
external state is written outside the repository branch and PR.

## Verification

- `WORKFLOW_VERSION=v0.20.1 ./scripts/bump-workflow-release.sh` exits 0 with no
  diff when the module already matches the requested tag.
- `WORKFLOW_VERSION=v0.63.1 ./scripts/bump-workflow-release.sh` updates the
  module and runs `GOWORK=off go test ./...`.
- `GOWORK=off go test ./...`
- YAML parse check for `.github/workflows/bump-workflow-release.yml`.
