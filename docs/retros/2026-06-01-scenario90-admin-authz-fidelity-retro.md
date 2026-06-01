# Retro: Scenario 90 Admin Authz Fidelity

**PRs:**
- GoCodeAlone/workflow-plugin-admin#37 — Fix admin contribution grant bridge
- GoCodeAlone/workflow-plugin-authz-ui#19 — Protect authz UI admin bridge
- GoCodeAlone/workflow-scenarios#49 — Prove Scenario 90 admin authz fidelity

**Merged:** 2026-06-01
**Branches:** `fix/admin-scenario90-contribution-bridge`, `fix/authz-ui-admin-bridge-protection`, `fix/scenario90-authz-fidelity`
**Design:** `docs/plans/2026-05-30-admin-app-access-design.md`
**Plan:** `docs/plans/2026-05-30-admin-app-access.md`
**Related ADRs:** none

## Adversarial-Review Findings, Scored

| Phase | Finding | Severity | Outcome |
|---|---|---:|---|
| design | Demo must execute real Workflow runtime, not a static or alternate harness | Critical | Prescient: Scenario 90 now builds Workflow server and external plugins, and shell tests reject Python harness artifacts. |
| design | Embedded authz tools can lose auth context | Important | Prescient: admin iframe auth bridge and Playwright admin/authz navigation proof were required. |
| design | UI visibility alone is insufficient for authz | Important | Prescient: server routes now enforce admin/app scopes and tests cover denied roles. |
| plan | Scenario must prove primary app and admin app together | Important | Resolved upfront: shell and Playwright tests cover `/`, `/admin/`, auth config, authz roles, and app access. |
| plan | Unsupported authz modes must not be fake-functional | Important | Resolved upfront: ABAC/ReBAC are disclosed as unavailable and hidden from actionable tabs. |

## Gate Misses

| Issue | Gate that missed | Why it slipped | Fix idea |
|---|---|---|---|
| Admin registry cloned all contributions under lock and cloned selected entries again. | requesting-code-review | The implementation review looked at correctness and missed lock-duration/perf on a shared registry helper. | Add a concurrency/performance pass when PRs alter shared registries or caches. |
| Iframe granted scopes accepted non-string values before `postMessage`. | requesting-code-review | The bridge was reviewed for origin/path and permission semantics, but not payload type normalization. | Treat `postMessage` payloads as boundary contracts and normalize at the sender. |
| Scenario seed token fallback assumed `uuidgen` existed when `openssl` did not. | runtime-launch-validation | Local launch environment had `openssl`, so portability of fallback tools was not exercised. | For shell fallback chains, check every fallback command or use POSIX/base utilities. |
| Playwright runner assumed `PLAYWRIGHT_PREFIX` existed. | runtime-launch-validation | Local prefix had already been created by prior runs. | Run browser bootstrap once with a fresh temp directory during final validation. |
| Playwright test hard-coded the admin token storage key. | requesting-code-review | The test asserted behavior but did not reuse the shell-advertised contract. | Browser tests should read runtime `data-*` contracts instead of duplicating defaults. |
| Compose required `SCENARIO90_SEED_TOKEN` even though the generated config already embedded it. | runtime-launch-validation | Fresh `seed.sh` worked, but restart/stop-start compose ergonomics were not checked. | For generated config substitutions, avoid retaining unused env requirements in compose. |

## Missed Skill Activations

| Gate | Fired? | Notes |
|---|---|---|
| brainstorming | yes | Initial admin/auth/authz scope was gathered across existing plans. |
| adversarial-design-review (design) | yes | Prior review caught fake-demo and missing auth context risks. |
| writing-plans | yes | Existing admin app access plan guided the multi-repo split. |
| adversarial-design-review (plan) | yes | Sidecar review before PR found seed route, ABAC/ReBAC, authz endpoint, and strict-contract issues. |
| alignment-check | partial | Scope was checked manually against the plan and user asks rather than by a fresh lock audit. |
| requesting-code-review | yes | Copilot and adversarial review produced actionable comments. |
| runtime-launch-validation | yes | Docker Scenario 90 and Playwright ran before merge and again after releases. |
| pr-monitoring | yes | CI and Copilot comments were monitored through merge. |
| post-merge-retrospective | yes | This document. |

## What Worked

- The adversarial review was prescient: every high-risk finding from the pre-PR pass became an implemented scenario guard or test.
- Copilot review added useful portability and boundary-shape catches after it came back online.
- Post-release validation caught the full product path: `workflow-scenarios@main` with `workflow-plugin-admin@v1.1.9` and `workflow-plugin-authz-ui@v1.0.6`.
- `wfctl validate` caught the final Scenario 90 YAML after the boolean route-key validator fix landed upstream.

## What Didn't

- The review gates underweighted portability of helper shell scripts after local state had already been warmed.
- The initial browser test duplicated an admin shell storage-key default instead of consuming the shell contract.
- Local worktree state was messy enough that release validation needed temporary detached worktrees instead of existing `main` checkouts.

## Plugin-Level Follow-Ups

- No autodev plugin change yet. These were mostly one-off misses, but future repeated `postMessage` or generated-config issues should become explicit requesting-code-review bug classes.

## Project Guidance Updates

| Guidance file | Change | Reason |
|---|---|---|
| `docs/design-guidance.md` | no change | No repo-level guidance file exists, and the lessons are currently scenario/review hygiene rather than durable product direction. |
