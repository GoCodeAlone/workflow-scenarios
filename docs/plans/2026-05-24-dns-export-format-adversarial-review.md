# DNS Export Format Adversarial Review

### Adversarial Review Report

**Phase:** plan
**Artifact:** docs/plans/2026-05-24-dns-export-format.md
**Status:** PASS

**Findings (Critical):**
- None.

**Findings (Important):**
- [Security / privacy] Private RFC1918 addresses can reveal internal topology and should not be accepted just because they are non-public. Recommendation: require documentation/example ranges only. Status: addressed by explicit TEST-NET and `2001:db8::/32` validation.
- [User-intent drift] A public replay format could be mistaken for live import coverage. Recommendation: keep README and backlog explicit that live account import/export remains private scenario work. Status: addressed.
- [Missing failure modes] TXT records can contain verification tokens and DKIM keys, while DMARC legitimately contains `p=` policy text. Recommendation: validate known verification markers and DKIM redaction without blocking DMARC policy records. Status: addressed.

**Findings (Minor):**
- [Simpler alternative] A README-only format would be simpler but non-enforceable. Recommendation: keep executable fixture checks.

**Bug-class scan transcript:**

| Class | Result | Note |
|---|---|---|
| Unstated assumptions | Clean | Assumptions are listed and scoped to public replay. |
| Repo-precedent conflicts | Clean | Scenario-local Python validation matches existing local-only scenario style. |
| YAGNI violations | Clean | No live exporter or provider mock process was added. |
| Missing failure modes | Finding | TXT/DKIM and replay-vs-live boundaries were tightened. |
| Security / privacy | Finding | Private IP acceptance was replaced with documentation/example-only validation. |
| Rollback story | Clean | Revert-only rollback is enough for docs, fixture, and tests. |
| Simpler alternative not considered | Finding | README-only alternative rejected because it lacks CI enforcement. |
| User-intent drift | Finding | README/backlog now preserve live private scenario boundary. |
| Over-decomposition / under-decomposition | Clean | Single scenario slice is appropriately small. |
| Verification-class mismatch | Clean | Both direct and wrapper scenario tests are required. |
| Hidden serial dependencies | Clean | Scenario already exists in `scenarios.json`; wrapper remains valid. |
| Missing rollback wiring | Clean | No runtime rollback task is required. |

**Options the author may not have considered:**

1. Add a real sanitizer CLI now: useful later, but premature without a second fixture or private provider export source.
2. Use JSON Schema: stronger formal validation, but would introduce dependency/tooling questions. The current Python validator is enough for this scenario.

**Verdict reasoning:** PASS. The plan improves the replay scenario's safety boundary without claiming live provider coverage or adding an unproven exporter.

