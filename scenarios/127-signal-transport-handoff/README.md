# Scenario 127 - Signal Transport Handoff

Local-only Workflow app proof that `workflow-plugin-signal` v0.31.0 can claim
an encrypted outbox envelope, package it for provider-neutral transport, admit
the received transport payload into the recipient inbox, ack the original
outbox item, and decrypt through a running Workflow API.

The scenario builds `workflow-plugin-signal` as a released external plugin,
loads it through the Workflow server plugin directory, starts `workflow-server`,
starts a scenario-owned HTTP transport mock, and drives separate
participant-parametric HTTP routes:

- sender and recipient publish local pre-key bundles
- sender encrypts and enqueues an outbox envelope
- worker calls `step.signal_outbox_handoff` and receives a signed JSON
  transport payload
- the transport mock stores and returns the ciphertext-only payload
- recipient calls `step.signal_transport_admit` through its route-bound API
- worker acks the outbox envelope after admit
- recipient decrypts the admitted inbox envelope
- duplicate outbox ack is rejected

The app config contains a small local identity pool, but participant IDs,
space IDs, worker IDs, message refs, transport refs, leases, and plaintext are
supplied by the test harness through HTTP path params and request bodies rather
than baked into the Workflow pipelines.

The scenario does not contact the official Signal service, register accounts,
link devices, send Signal messages, or interact with an official Signal app.

## Running

```bash
bash scenarios/127-signal-transport-handoff/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, `SIGNAL_PLUGIN_REPO`, or
`SIGNAL_PLUGIN_REF` when running outside the standard workspace layout.
