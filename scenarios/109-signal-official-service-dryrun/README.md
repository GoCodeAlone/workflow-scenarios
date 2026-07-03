# Scenario 109 - Signal Official Service Dry-Run Boundary

Local-only Workflow app proof for `workflow-plugin-signal` official-service
readiness and no-egress live-submit behavior.

The scenario builds `workflow-plugin-signal` v0.14.0, loads it as an external
Workflow plugin under a temporary `data/plugins` directory, launches the real
Workflow server, and drives HTTP routes with caller-supplied request bodies:

- `POST /service/approval/validate` validates approval packages for requested
  service actions.
- `POST /service/submit` submits fake/sandbox service operations, denies live
  operations without complete approval, denies complete live approval without
  `egress_dry_run`, and accepts complete live dry-runs without egress.

The app registers a local pool of deterministic account/custody refs so clients
can choose an account from the request body. Recipient refs, payload refs,
operation names, idempotency keys, approval packages, and sandbox endpoints are
all request inputs.

## Running

```bash
bash scenarios/109-signal-official-service-dryrun/test/run.sh
```

Set `WORKFLOW_SERVER` or `WORKFLOW_REPO` when running outside the standard
workspace layout. The test uses a local `SIGNAL_PLUGIN_REPO` only if it
advertises the v0.14 dry-run output contract; otherwise it clones
`GoCodeAlone/workflow-plugin-signal` at `SIGNAL_PLUGIN_REF` (default `v0.14.0`).

The runtime is local-only. It does not register accounts, link devices, send
messages, receive messages, upload backups, reserve usernames, or contact the
official Signal service.
