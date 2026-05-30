# Scenario 72: IaC Dynamic DNS Multi-Provider

Config-validation scenario for the `infra.dyndns` module backed by
three DNS providers in one app — DigitalOcean, Namecheap, Hover.

## What it tests

- `infra.dyndns` module wiring per provider.
- Multi-source IP detection (icanhazip + ifconfig.me + ipify) with
  quorum requirement.
- Per-record `poll_interval`, `quorum`, and `detect_via` config.

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live network calls; secrets can be stubbed.
