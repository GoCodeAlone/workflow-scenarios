# Scenario 137 - Signal Transport Receipts

Local-only Workflow app proof that `workflow-plugin-signal` v0.35.1 can hand
off an encrypted outbox envelope to `workflow-plugin-eventbus` v0.3.8, move the
provider-neutral transport payload through NATS/JetStream, admit it into the
recipient inbox, issue and verify a transport receipt before acking the Signal
outbox item and eventbus message, reject receipt replay, and decrypt through a
running Workflow API.

The scenario builds both plugins as released external plugins, loads them
through the Workflow server plugin directory, starts `workflow-server`, starts a
scenario-owned embedded NATS/JetStream fixture, and drives separate
participant-parametric HTTP calls:

- sender and recipient publish local pre-key bundles
- sender encrypts and enqueues an outbox envelope
- worker calls `step.signal_outbox_handoff`
- Workflow publishes the signed transport payload with `step.eventbus.publish`
- worker consumes the message with `step.eventbus.consume`
- Workflow admits the Signal transport payload with `step.signal_transport_admit`
- Workflow issues and verifies a transport receipt with
  `step.signal_transport_receipt_issue` and
  `step.signal_transport_receipt_verify`
- Workflow acks the Signal outbox item and eventbus delivery
- duplicate receipt verification is rejected by the replay cache
- recipient decrypts the admitted inbox envelope
- duplicate outbox ack and second eventbus receive are rejected

The app config contains a small local identity pool, but participant IDs,
space IDs, worker IDs, message refs, transport refs, leases, and plaintext are
supplied by the test harness through HTTP path params and request bodies rather
than baked into the Workflow pipelines.

The scenario does not contact the official Signal service, register accounts,
link devices, send Signal messages, or interact with an official Signal app.

## Running

```bash
bash scenarios/137-signal-transport-receipts/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, `SIGNAL_PLUGIN_REPO`, or
`EVENTBUS_PLUGIN_REPO` when running outside the standard workspace layout.
