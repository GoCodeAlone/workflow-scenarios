# Retro: Auth Provider Admin Scenario

**PR:** #30 - feat: add dynamic admin provider scenario  
**Merged:** 2026-05-27  
**Branch:** feat/dynamic-admin-provider-scenario  
**Design:** /Users/jon/workspace/workflow-plugin-auth/.worktrees/auth-provider-architecture/docs/plans/2026-05-27-auth-provider-architecture-design.md  
**Plan:** /Users/jon/workspace/workflow-plugin-auth/.worktrees/auth-provider-architecture/docs/plans/2026-05-27-auth-provider-architecture.md  
**Related ADRs:** none

## Adversarial-review findings, scored

| Phase | Finding | Severity | Outcome |
|---|---|---|---|
| plan | Nine PRs is heavy. | Minor | False positive: provider repos stayed independently releasable and revertible. |
| plan | New repo creation has GitHub side effects. | Minor | Resolved upfront: repos were created only where absent and release CI verified each tag. |
| plan | Polis Go SDK may not exist. | Minor | Prescient: no stable official Go SDK was found, so Polis used a typed API client and documented that constraint. |

## Gate misses

No gate misses this PR. The one CI delay was CodeQL Go analysis time; it completed successfully without code changes. The only implementation defect found before merge was descriptor-secret redaction for `secret: true` fields without secret-like names, and it was caught by local scenario tests before PR creation.

| Issue | Gate that missed | Why it slipped | Fix idea |
|---|---|---|---|
| None | none | No review comment or CI failure required a follow-up fix after PR creation. | None. |

## Missed skill activations

| Gate | Fired? | Notes |
|---|---|---|
| brainstorming | yes | Auth provider architecture design was created before implementation. |
| adversarial-design-review (design) | yes | User-facing auth/admin/security assumptions were challenged before planning. |
| writing-plans | yes | Locked plan covered provider plugins, admin rendering, scenario proof, and release cascade. |
| adversarial-design-review (plan) | yes | Minor findings were accepted or converted into explicit plan constraints. |
| alignment-check | yes | Plan/design trace passed before scope lock. |
| executing-plans | yes | Tasks were executed against the locked manifest. |
| finishing-a-development-branch | partial | PRs were created and merged under autonomous/admin-merge flow; manual option menu was intentionally skipped. |
| pr-monitoring | yes | CI was watched for PR #30 before admin merge. |
| post-merge-retrospective | yes | This document. |

## What worked

- Dynamic provider descriptors let the scenario render local auth, SSO, Okta, Auth0, Entra, Ory, and Scalekit providers without hard-coded UI arrays.
- Scenario tests caught a real secret-redaction edge case before the PR was opened.
- Docker Compose plus host Tailscale serve gave a reachable review environment without requiring live provider credentials.
- Provider-release pins kept the scenario tied to published plugin artifacts instead of local-only code.

## What didn't

- The local Kubernetes path was unavailable in this workspace, so Docker Compose carried runtime validation.
- The Tailscale sidecar could start `tailscaled` but could not authenticate without `TS_AUTHKEY` or reusable state; host Tailscale serve provided the reachable tailnet route.
- CodeQL Go analysis added merge latency despite the scenario being Python and shell heavy.

## Plugin-level follow-ups

No plugin-level gate changes are warranted from this PR alone. The secret-redaction case is already covered by scenario tests and should remain a reusable invariant for descriptor-driven admin forms.

## Project guidance updates

| Guidance file | Change | Reason |
|---|---|---|
| `docs/design-guidance.md` | no change | This repo has no scenario-local design guidance file, and the lesson is already captured by plugin contract tests plus this retro. |
