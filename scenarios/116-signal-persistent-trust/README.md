# Scenario 116 - Signal Persistent Trust

Local-only Workflow app proof that `workflow-plugin-signal` can persist a
Signal safety-number trust decision, reload it after a Workflow server restart,
and reject a changed remote identity key before encryption or queue emission.

The scenario builds `workflow-plugin-signal` v0.22.0 as an external plugin,
loads it through the Workflow server plugin directory, starts `workflow-server`,
and drives participant-parametric HTTP routes:

- participants publish local Signal bundles through `POST /participants/{id}/session`
- a sender records trust and sends encrypted content through
  `POST /spaces/{space}/participants/{sender}/trusted-send/{recipient}`
- the Workflow server restarts with the same file-backed trust store
- the same caller-supplied trust vector is accepted as `trusted`
- a changed recipient identity key for the same participant pair is rejected
- the rejected changed-key request emits no ciphertext response and consumes no
  envelope idempotency slot

The local identity pool is a conformance fixture. Participant IDs, space IDs,
message refs, plaintext, local bundles, and remote bundles are supplied by the
test harness through HTTP path params and request bodies rather than hard-coded
in the Workflow pipelines. No official Signal service endpoint, account, phone
number, or production transport is used.

## Running

```bash
bash scenarios/116-signal-persistent-trust/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, `SIGNAL_PLUGIN_REPO`, or
`SIGNAL_PLUGIN_REF` when running outside the standard workspace layout.
