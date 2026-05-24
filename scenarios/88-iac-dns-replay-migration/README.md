# Scenario 88: IaC DNS Replay Migration

Offline replay scenario for DNS/IaC import and migration safety.

The scenario does not call Cloudflare, DigitalOcean, Namecheap, Hover, or any registrar API. It validates sanitized `workflow.dns-portfolio.export.v1` snapshots that model imported provider state and a planned Cloudflare target zone.

## What It Tests

- Provider snapshot shape for Cloudflare, DigitalOcean, Namecheap, and Hover.
- Export metadata marking the portfolio as sanitized before it can be used as a replay fixture.
- NS authority metadata is present for source and target zones.
- MX, SPF, DMARC, CNAME, A, and AAAA records survive normalization.
- Documentation/example IP ranges are used instead of public or private production addresses.
- TXT verification tokens and DKIM material are redacted before fixture commit.
- Cloudflare target state exposes Cloudflare nameservers.
- Destructive deletes are disabled unless explicitly opted in, and migration defaults to `plan_only`.
- Migration plans track manual nameserver switch and MX-delivery verification steps.

## Export Format

Replay fixtures use `workflow.dns-portfolio.export.v1`:

- `metadata.sanitized: true` is required.
- `metadata.source_portfolio_id` must be a non-sensitive alias, not an account ID or real domain.
- `sanitization.rules` records the transformations applied before commit.
- `sanitization.forbidden_patterns` lists source-only strings that must not appear in the sanitized snapshots or migration plan.
- `snapshots[]` contains provider, domain, authority metadata, and normalized DNS records.
- `migration.apply_mode` must start as `plan_only`, with `delete_unlisted: false`.

Live/private exporters should preserve provider record semantics while replacing domains with `.example` aliases, public and private addresses with documentation ranges, email addresses with `example.invalid`, and TXT verification or DKIM material with explicit redaction markers.

## What It Does Not Test

- Provider credentials or live API permissions.
- Registrar transfer execution.
- Real DNS propagation.
- Plugin process loading through `wfctl`.
- Sanitizer execution against real account exports.

Those belong in `workflow-scenarios-private` live scenarios with explicit credentials, budgets, cleanup, and disposable test resources.

## How To Run

```sh
bash scenarios/88-iac-dns-replay-migration/test/run.sh
```

Or through the scenario wrapper:

```sh
bash scripts/test.sh 88-iac-dns-replay-migration
```
