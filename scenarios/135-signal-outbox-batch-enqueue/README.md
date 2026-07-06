# Scenario 135: Signal Outbox Batch Enqueue

This scenario starts a real `workflow-server`, loads released
`workflow-plugin-signal v0.35.1` as an external plugin, and drives
participant-parametric HTTP routes through atomic Signal outbox batch enqueue.

The proof uses a scenario-owned SQLite envelope store, prepares a recipient
bundle through the Workflow API, encrypts two caller-supplied messages inside
the running app, and enqueues them with `step.signal_outbox_enqueue_batch`.
It verifies an invalid duplicate-idempotency batch rolls back without
persisting either message, a valid two-item batch persists both queued outbox
records, duplicate retry does not create extra records, and restart status
shows both queued records survived.

The SQLite file is the only local dependency seam; the Workflow server,
external plugin loader, and Signal plugin steps run unchanged.
