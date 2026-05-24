# Scenario 88: IaC DNS Replay Migration

Offline replay scenario for DNS/IaC import and migration safety.

The scenario does not call Cloudflare, DigitalOcean, Namecheap, Hover, or any registrar API. It validates sanitized snapshots that model imported provider state and a planned Cloudflare target zone.

## What It Tests

- Provider snapshot shape for Cloudflare, DigitalOcean, Namecheap, and Hover.
- NS authority metadata is present for source and target zones.
- MX, SPF, DMARC, CNAME, A, and AAAA records survive normalization.
- Cloudflare target state exposes Cloudflare nameservers.
- Destructive deletes are disabled unless explicitly opted in.
- Migration plans track manual nameserver switch and MX-delivery verification steps.

## What It Does Not Test

- Provider credentials or live API permissions.
- Registrar transfer execution.
- Real DNS propagation.
- Plugin process loading through `wfctl`.

Those belong in `workflow-scenarios-private` live scenarios with explicit credentials, budgets, cleanup, and disposable test resources.

## How To Run

```sh
bash scenarios/88-iac-dns-replay-migration/test/run.sh
```

Or through the scenario wrapper:

```sh
bash scripts/test.sh 88-iac-dns-replay-migration
```
