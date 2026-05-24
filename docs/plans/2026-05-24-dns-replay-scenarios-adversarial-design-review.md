# DNS Replay Scenarios Adversarial Design Review

### Adversarial Review Report

**Phase:** design
**Artifact:** docs/plans/2026-05-24-dns-replay-scenarios-design.md
**Status:** PASS

**Findings (Critical):**
- None.

**Findings (Important):**
- [Missing failure modes] Replay fixtures can create false confidence because they do not exercise plugin process loading or provider API behavior. Recommendation: state this boundary in the README and backlog live/private scenarios. Status: addressed in design and planned docs.
- [Repo-precedent conflicts] `workflow-scenarios` currently has many config-validation scenarios and no generic replay harness. Recommendation: keep the first implementation scenario-local rather than introduce a global framework prematurely. Status: accepted.
- [Security / privacy] DNS fixtures can leak real mail providers or private hostnames if copied from production. Recommendation: use reserved example domains and TEST-NET IPs only. Status: addressed.

**Findings (Minor):**
- [YAGNI] A generalized mock provider plugin would be heavier than this task needs. Recommendation: defer until a scenario needs plugin process loading. Status: addressed.

**Bug-class scan transcript:**

| Class | Result | Note |
|---|---|---|
| Unstated assumptions | Clean | Load-bearing assumptions are listed explicitly. |
| Repo-precedent conflicts | Finding | Existing scenarios are mostly shell/YAML validation; scenario-local replay best fits precedent. |
| YAGNI violations | Finding | Mock plugin binaries are intentionally deferred. |
| Missing failure modes | Finding | Replay false confidence is documented as a boundary. |
| Security / privacy | Finding | Sanitized fixtures are required. |
| Rollback story | Clean | Reverting docs/fixtures/scripts is sufficient. |
| Simpler alternative not considered | Clean | README-only checklist was considered and rejected. |
| User-intent drift | Clean | Design keeps DNS/IaC in `workflow-scenarios`, not compute scenarios. |

**Options the author may not have considered:**

1. Add the scenario directly to `workflow/iac/conformance`: stronger provider-contract locality, but wrong repo for cross-provider scenario assets and user-facing migration workflows.
2. Implement a fake DNS provider plugin now: better plugin-host coverage, but too much infrastructure before we have replay invariants established.

**Verdict reasoning:** PASS. The design is intentionally scoped and corrects the repo boundary mistake. Important findings are addressed by keeping this first pass scenario-local, explicitly documenting replay limitations, and using sanitized fixtures.
