# Retro: DNS Provider Output Contracts

**PR:** #14 - test: declare DNS provider output contracts
**Merged:** 2026-05-24
**Branch:** feat/dns-authority-contract
**Design:** docs/plans/2026-05-24-dns-replay-scenarios-design.md
**Plan:** docs/plans/2026-05-24-dns-replay-scenarios.md
**Related ADRs:** none

## Adversarial-review findings, scored

| Phase | Finding | Severity | Outcome |
|---|---|---|---|
| design | Replay fixtures can create false confidence because they do not exercise plugin process loading or provider API behavior. | Important | Resolved upfront: PR #14 keeps validation offline and records provider output contracts instead of claiming live-provider coverage. |
| design | Keep the first replay implementation scenario-local rather than introduce a global framework prematurely. | Important | Resolved upfront: PR #14 extends scenario 88 in place and does not add a shared replay harness. |
| design | DNS fixtures can leak real mail providers or private hostnames if copied from production. | Important | Resolved upfront: fixture validation still enforces sanitized/example data. |
| design | A generalized mock provider plugin is heavier than this task needs. | Minor | False positive for this PR: output contracts were enough to align providers without a mock plugin binary. |
| plan | Include `bash scripts/test.sh 88-iac-dns-replay-migration` plus direct script invocation. | Important | Resolved upfront: both commands passed before merge. |
| plan | Register metadata before running the scenario wrapper. | Important | Resolved upfront: `scenarios.json` test counts were updated by the wrapper. |
| plan | Four tasks are enough; splitting fixture and test is useful for review. | Minor | False positive for this PR: the follow-up was a narrower one-commit contract extension. |

## Gate misses

No gate misses this PR. CI passed on the PR and on the merge commit, and there were no code-review comments or changes-requested reviews.

| Issue | Gate that missed | Why it slipped | Fix idea |
|---|---|---|---|
| None | n/a | n/a | n/a |

## Missed skill activations

The repo does not contain `tests/skill-activation-audit.sh` or `.claude/superpowers-state/in-progress.jsonl`, so activation evidence came from the committed design, adversarial-review, alignment, and scope-lock artifacts plus the PR/test history.

| Gate | Fired? | Notes |
|---|---|---|
| brainstorming | yes | Captured in the DNS replay design doc. |
| adversarial-design-review (design) | yes | `docs/plans/2026-05-24-dns-replay-scenarios-adversarial-design-review.md`. |
| writing-plans | yes | `docs/plans/2026-05-24-dns-replay-scenarios.md`. |
| adversarial-design-review (plan) | yes | `docs/plans/2026-05-24-dns-replay-scenarios-adversarial-plan-review.md`. |
| alignment-check | yes | `docs/plans/2026-05-24-dns-replay-scenarios-alignment.md`. |
| subagent-driven-development | no | Not used in this Codex host run because subagent dispatch requires explicit user authorization. |
| finishing-a-development-branch | yes | Used for PR creation, green-check monitoring, and admin merge. |
| pr-monitoring | yes | Run inline with `gh pr checks`, review-thread checks, and merge-commit CI checks. |
| post-merge-retrospective | yes | This file. |

## What worked

- The replay scenario was a useful place to declare provider output contracts without needing live accounts.
- TDD caught missing `authority` output fields before provider plugin changes were accepted.
- PR and merge-commit CI both stayed green with no review threads to resolve.

## What didn't

- `gh pr merge --delete-branch` merged the PRs but failed locally in auxiliary worktrees when it tried to switch to `main`; cleanup had to be completed manually.
- The original plan artifact covered the broader scenario 88 work, while PR #14 was a narrower follow-up for output contracts. The retro still had enough artifacts to score the relevant gates, but the scope mapping is less direct than a dedicated plan would be.

## Plugin-level follow-ups

No plugin-level changes are warranted from this single PR. If future Codex-hosted runs repeatedly skip subagent-driven-development because of host policy, the superpowers guidance should record the inline-review fallback explicitly.
