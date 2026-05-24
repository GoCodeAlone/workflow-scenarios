# Workflow DNS/IaC and Compute Backlog

This backlog preserves open work from the DNS/IaC and workflow-compute threads so scenario work does not lose adjacent tasks.

## DNS/IaC Scenarios

- Public hermetic replay coverage for DNS import and migration invariants shipped in scenario 88.
- Add private live scenarios for Cloudflare, DigitalOcean, Namecheap, and Hover where credentials and disposable resources are available.
- Sanitized `workflow.dns-portfolio.export.v1` fixture envelope shipped in scenario 88; future live exporters should emit this shape before fixtures are committed.
- Scenario 88 covers NS delegation, MX records, SPF/DMARC TXT records, CNAMEs, documentation/example IP enforcement, and provider-specific TTL/priority normalization.

## Provider Plugins

- Cloudflare plugin now supports import-first `infra.domain` for registrar metadata and explicit auto-renew updates; transfer/purchase flows remain out of public replay scope.
- DigitalOcean DNS import outputs now include nested authoritative DNS metadata aligned with the canonical DNS replay shape.
- Hover now supports and documents read-only `infra.dns` and `infra.dns_delegation` import. Hover has no official API, so live automation remains best-effort and should stay private-gated.
- Namecheap plugin now supports explicit `infra.domain_transfer` creation/status using the provider API; destructive or cancellation-style operations remain separate work.

## DNS Management UI

- Design a UI that reads IaC state and live drift but writes only through reviewed plans.
- Require state snapshots, diff previews, destructive-change warnings, and explicit approval before apply.
- Prefer import/replay preview first; defer direct live edits until the plan/apply safety model is proven.

## workflow-compute

- Short-lived task residue policy support shipped in `workflow-compute`, including isolated, provider-bound, session-bound, and guarded worker-bound modes.
- `workflow-compute-scenarios` now covers residue policy, provider/product network-mode rejection, reuse/isolation expectations, no-workspace WASM rejection, and long-lived service residue rejection.
- Re-evaluate long-lived process/service behavior beyond residue rejection for network-policy concerns and durable session cleanup.
- Keep plugin-based execution the primary path; CLI behavior should route through `wfctl` plugin-aware surfaces where possible.

## Ownership Boundaries

- `workflow-scenarios`: public, hermetic Workflow app/provider scenarios.
- `workflow-scenarios-private`: live account/provider scenarios with secrets, budgets, and cleanup.
- `workflow-compute-scenarios`: workflow-compute-specific execution/isolation scenarios only.
- Provider repos: provider-specific drivers, import/apply behavior, SDK integration, and unit tests.
