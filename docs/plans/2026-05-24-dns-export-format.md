# DNS Export Format Plan

## Goal

Make scenario 88 define and enforce a sanitized DNS portfolio export envelope before real provider exports are committed as replay fixtures.

## Approach

Extend the existing `88-iac-dns-replay-migration` fixture from a generic replay document to `workflow.dns-portfolio.export.v1`. The envelope records sanitization status, non-sensitive source metadata, redaction rules, and forbidden source patterns. Keep the format provider-neutral so Cloudflare, DigitalOcean, Namecheap, Hover, and future private exporters can emit the same shape.

Add validation for:

- `metadata.sanitized: true` and `sanitization.status: sanitized`.
- Required redaction rules for domain aliases, documentation/example IP addresses, TXT secret redaction, and email redaction.
- Documentation/example-only A and AAAA values, not arbitrary private or public addresses.
- Forbidden raw source strings absent from snapshots and migration plans.
- `migration.apply_mode: plan_only` and `delete_unlisted: false`.

Update scenario docs, metadata, and backlog to reflect shipped public coverage and remaining private/live work.

## Assumptions

- A fixture envelope is the right public next step before building live private exporters.
- Replay fixtures must be safe to commit even if generated from real domain portfolios.
- Provider plugins remain responsible for live import/apply behavior; this scenario validates the portable shape and safety invariants.

## Rollback

Rollback is to revert this docs/fixture/test change. No provider API, runtime service, deployment, or plugin loading path changes.

## Verification

- Watch the scenario fail before adding the missing envelope fields.
- Run `bash scenarios/88-iac-dns-replay-migration/test/run.sh`.
- Run `bash scripts/test.sh 88-iac-dns-replay-migration`.
- Run `GOWORK=off go test ./...`.
- Run `git diff --check`.
