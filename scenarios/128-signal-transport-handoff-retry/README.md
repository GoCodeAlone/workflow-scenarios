# Scenario 128 - Signal Transport Handoff Retry

Local-only Workflow app proof that `workflow-plugin-signal` v0.31.0 rejects
invalid transport admits without mutating the inbox, then supports release,
retry handoff, admit, ack, and decrypt through a running Workflow API.

The scenario builds `workflow-plugin-signal` as a released external plugin,
loads it through the Workflow server plugin directory, starts `workflow-server`,
starts a scenario-owned HTTP transport mock, and drives separate
participant-parametric HTTP routes:

- sender and recipient publish local pre-key bundles
- sender encrypts and enqueues an outbox envelope
- worker calls `step.signal_outbox_handoff` and publishes the payload to the
  transport mock
- recipient rejects wrong-route, bad-HMAC, tampered-ciphertext, and expired
  transport payloads
- recipient cannot decrypt before a valid admit
- worker releases the claimed outbox item with ref-only error metadata
- worker retries handoff and recipient admits the retry payload
- worker acks the outbox envelope after successful admit
- recipient decrypts the retry-admitted inbox envelope
- release and handoff after terminal ack are rejected

The app config contains a small local identity pool, but participant IDs,
space IDs, worker IDs, message refs, transport refs, leases, and plaintext are
supplied by the test harness through HTTP path params and request bodies rather
than baked into the Workflow pipelines.

The scenario does not contact the official Signal service, register accounts,
link devices, send Signal messages, or interact with an official Signal app.

## Running

```bash
bash scenarios/128-signal-transport-handoff-retry/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, `SIGNAL_PLUGIN_REPO`, or
`SIGNAL_PLUGIN_REF` when running outside the standard workspace layout.
