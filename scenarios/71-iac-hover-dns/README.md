# Scenario 71: IaC Hover DNS

Config-validation scenario for a Hover-managed DNS zone via the
workflow IaC interface, using
[workflow-plugin-hover](https://github.com/GoCodeAlone/workflow-plugin-hover).

Hover has no official API. The plugin mimics the browser-side
auth flow (`signin` → CSRF → password → TOTP) used by
[pjslauta/hover-dyn-dns](https://github.com/pjslauta/hover-dyn-dns).

## What it tests

- `iac.provider.hover` module wiring with username/password/TOTP-seed.
- `infra.dns` resource declaring A, AAAA, MX records.
- IaC lifecycle pipeline: `step.iac_plan` + `step.iac_apply`.

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live Hover login required. TOTP secret can be a stub for the
config-validation pass.
