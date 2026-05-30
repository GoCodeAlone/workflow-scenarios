# Scenario 70: IaC Namecheap DNS

Config-validation scenario for a Namecheap-managed DNS zone via the
workflow IaC interface, using
[workflow-plugin-namecheap](https://github.com/GoCodeAlone/workflow-plugin-namecheap).

## What it tests

- `iac.provider.namecheap` module wiring with API user/key/client_ip.
- `iac.state` with `backend: memory`.
- `infra.dns` resource declaring three records (A, CNAME, TXT) on
  the apex domain.
- IaC lifecycle pipeline: `step.iac_plan` + `step.iac_apply`.

## How to run

```sh
WFCTL_BIN=/path/to/wfctl bash test/run.sh
```

No live Namecheap API calls or client_ip allowlisting required.
