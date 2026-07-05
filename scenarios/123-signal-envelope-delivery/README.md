# Scenario 123 - Signal Envelope Delivery

Local-only Workflow app proof that `workflow-plugin-signal` v0.29.0 can drive a
reliable encrypted envelope lifecycle through a running Workflow API.

The scenario builds `workflow-plugin-signal` as a released external plugin,
loads it through the Workflow server plugin directory, starts `workflow-server`,
and drives separate participant-parametric HTTP routes:

- a sender and recipient publish local pre-key bundles
- the sender encrypts and enqueues an outbox envelope
- a worker claims the envelope and sees ciphertext plus routing refs only
- the worker releases the envelope with ref-only transient error metadata
- the worker reclaims the released envelope and delivers it to the recipient inbox
- the worker acks the outbox envelope after delivery
- the recipient decrypts the inbox envelope through a separate API call
- duplicate ack and reclaim-after-ack are rejected

The app config contains a small local identity pool, but participant IDs,
space IDs, worker IDs, message refs, plaintext, leases, and envelopes are
supplied by the test harness through HTTP path params and request bodies rather
than baked into the Workflow pipelines.

The scenario does not contact the official Signal service, register accounts,
link devices, send Signal messages, or interact with an official Signal app.

## Running

```bash
bash scenarios/123-signal-envelope-delivery/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, `SIGNAL_PLUGIN_REPO`, or
`SIGNAL_PLUGIN_REF` when running outside the standard workspace layout.
