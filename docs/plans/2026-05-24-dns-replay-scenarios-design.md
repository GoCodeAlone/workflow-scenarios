# DNS Replay Scenarios Design

## Goal

Add a public, hermetic Workflow scenario for DNS/IaC import and migration validation that does not require real accounts at Cloudflare, DigitalOcean, Namecheap, Hover, or any registrar. Keep live provider validation as a separate private tier.

## Context

`workflow-compute-scenarios` is scoped to `workflow-compute` only. DNS/IaC scenarios belong in `workflow-scenarios` for public hermetic cases and `workflow-scenarios-private` for credentialed live cases.

Workflow already has a useful precedent in `workflow/iac/conformance`: scenarios run hermetically by default, and real APIs only run when `LiveCloud` is explicitly enabled. `workflow-scenarios` currently has DNS config-validation scenarios for Namecheap, Hover, and multi-provider dynamic DNS, but those only validate YAML and wiring. They do not validate DNS import shape, record preservation, provider normalization, or migration planning.

## Recommended Approach

Use a three-tier DNS scenario model:

1. **Hermetic public replay.** Store sanitized DNS import snapshots as JSON fixtures in `workflow-scenarios`. A test script validates provider-neutral invariants and migration-plan safety without credentials or network calls.
2. **Replay from real exports.** Future scenarios can add sanitized fixtures generated from real domains, but committed data must be non-secret and non-sensitive.
3. **Live private scenarios.** `workflow-scenarios-private` owns credentialed live tests with real provider APIs, budget/cleanup gates, and disposable resources where possible.

The first implementation adds only tier 1: a scenario named `88-iac-dns-replay-migration`.

## Scenario Behavior

The scenario contains provider snapshots for DigitalOcean authoritative DNS, Namecheap registrar/DNS, Hover registrar-origin DNS, and Cloudflare target state. It validates:

- DNS fixtures parse and declare provider, authority, domain, nameservers, and records.
- Required production-critical records are preserved: MX, TXT/SPF, TXT/DMARC, CNAME, A/AAAA.
- Provider-specific shapes normalize into a single canonical record model.
- Migration plans preserve MX records and detect target Cloudflare nameservers.
- Destructive delete behavior remains opt-in: undeclared live records are preserved unless an explicit `manage_unlisted`-style flag is present.
- Provider coverage status is tracked, including the known Hover/live-transfer gap.

The validation script is intentionally local and deterministic. It uses Python standard-library JSON parsing so CI does not need provider credentials or SDKs.

## Backlog Tracking

Add a lightweight Markdown backlog under `docs/backlog/workflow-dns-iac-and-compute.md`. It records remaining work from this thread:

- Workflow DNS replay scenario follow-ups.
- Live private DNS migration scenarios.
- Cloudflare registrar investigation.
- Safe DNS UI design.
- Hover importer/plugin gap.
- Workflow-compute short-lived reuse/residue scenario work.

This avoids losing earlier tasks while this PR focuses on public DNS replay validation.

## Alternatives Considered

1. **Only live provider scenarios.** Strongest end-to-end signal, but it blocks public CI on credentials, budgets, account setup, API quotas, and cleanup reliability.
2. **Only plugin unit tests.** Cheap and already partly available, but it does not validate cross-provider migration invariants at the Workflow scenario level.
3. **Mock provider plugin binaries.** Closer to plugin loading behavior, but heavier than needed for the first public scenario and would risk duplicating plugin SDK behavior.

The replay fixture approach gives the best next step: real DNS-like state, zero credentials, deterministic CI, and a clean path to private live validation later.

## Assumptions

- Public scenario fixtures can be sanitized enough to avoid exposing real domain inventory or mail-routing secrets.
- Record preservation invariants are useful even before an end-to-end `wfctl import` command exists for every provider.
- `workflow-scenarios` can accept local-only scenario tests that do not deploy Kubernetes resources.
- Live registrar transfer validation is too risky for public CI and belongs in `workflow-scenarios-private`.

## Failure Modes

- **Malformed fixture:** the script fails with a clear `FAIL:` line naming the fixture and validation.
- **Provider drift:** new provider outputs may add fields; the canonical validation ignores unknown fields but requires known safety fields.
- **False confidence:** replay cannot prove provider API auth, rate limits, or registrar transfer behavior. The scenario README will explicitly state this boundary.
- **Data leakage:** fixtures must use reserved example domains and TEST-NET IP ranges.

## Rollback

This change is documentation, fixtures, and local scenario validation. Rollback is to revert the scenario/backlog commits. No runtime service, plugin loading path, migration, or provider API behavior is changed.

## Self-Challenge

1. The laziest solution would be a README checklist. That would not give CI-enforced regression coverage, so the design adds executable replay validation.
2. The fragile assumption is that replay invariants are valuable before full `wfctl import` exists. This is acceptable because preserving records and migration safety is provider-neutral and catches data-loss bugs early.
3. This design does not implement a mock plugin binary. That is intentionally deferred until we need to validate plugin process loading, because current value is in DNS state preservation.
