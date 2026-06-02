# Retro: Auth Provider Admin Apply

**PR:** #66 - feat: prove auth admin config apply
**Merged:** 2026-06-02
**Branch:** feat/scenario90-auth-admin-apply
**Design:** docs/plans/2026-06-02-auth-provider-admin-apply-design.md
**Plan:** docs/plans/2026-06-02-auth-provider-admin-apply.md
**Related ADRs:** none

## Adversarial-review findings, scored

| Phase | Finding | Severity | Outcome |
|---|---|---|---|
| design | File-backed runtime secrets would fake the proof because Workflow exposes Vault/AWS/keychain runtime secret modules, not `secrets.file`. | Important | Resolved upfront |
| implementation | No-secret apply erased existing secret refs. | Important | Prescient |
| implementation | Invalid-apply tests did not prove persisted state was unchanged. | Important | Prescient |
| implementation | Playwright did not exercise provider secret submission. | Important | Prescient |
| implementation | First-time no-secret apply branch could fall through into existing-ref persistence. | Important | Prescient |
| implementation | Admin apply could leak bearer tokens to unsafe metadata URLs and later allowed credentialed same-origin URLs. | Important | Prescient |

## Gate misses

| Issue | Gate that missed | Why it slipped | Fix idea |
|---|---|---|---|
| Copilot caught credentialed same-origin admin endpoints. | requesting-code-review | The adversarial review checked origin and route prefix but not URL userinfo/hash components. | Add userinfo/hash checks to same-origin endpoint review prompts. |
| Copilot caught whitespace-sensitive Playwright JSON text assertions. | requesting-code-review | Browser QA focused on behavior and redaction, not assertion robustness across pretty/minified output. | Prefer regex or parsed JSON assertions for rendered JSON snippets. |

## Missed skill activations

| Gate | Fired? | Notes |
|---|---|---|
| brainstorming | yes | Used to separate hot reload, secrets, provider CRUD, and infra ownership. |
| adversarial-design-review (design) | yes | Caught the invalid file-secret assumption before implementation. |
| writing-plans | yes | Produced the scoped two-PR plan. |
| adversarial-design-review (plan/implementation) | yes | Multiple review loops caught secret-ref, state immutability, branch-order, and UI validation issues. |
| alignment-check | partial | Requirements were checked manually against the plan; no separate committed alignment report. |
| subagent-driven-development | yes | Review agents covered admin and scenario diffs independently. |
| pr-monitoring | yes | Monitored #39 and #66, handled Copilot comments, and merged when green. |
| post-merge-retrospective | yes | This retro. |

## What worked

- Scenario 90 stayed honest by using a real Vault sidecar and `step.secret_set`, not an invented local secret store.
- Adversarial implementation review found meaningful branch and state bugs before PR merge.
- Playwright exploratory QA produced a real failure when auth routes were not enabled before Auth0 apply.
- Copilot review was useful once restored; both comments were small but concrete hardening fixes.

## What didn't

- The first pass over the Workflow YAML missed linear step fallthrough between sibling response branches.
- The initial admin shell patch under-tested JavaScript behavior with embedded string checks.
- The scenario proof remains Auth0-secret-specific; descriptor-driven multi-secret apply is still future work.

## Plugin-level follow-ups

- Add URL userinfo/hash handling to same-origin endpoint checks in future admin UI review prompts.
- Add a branch-fallthrough check for declarative Workflow pipelines with multiple persistence/response sibling steps.

## Project guidance updates

| Guidance file | Change | Reason |
|---|---|---|
| docs/design-guidance.md | no change | No existing guidance file; lessons are process-specific rather than a durable project design constraint. |
