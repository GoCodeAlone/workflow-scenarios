# Scenario 133: Signal Outbox Requeue

This scenario starts a real `workflow-server`, loads released
`workflow-plugin-signal v0.34.0` as an external plugin, and drives
participant-parametric HTTP routes through Signal outbox dead-letter recovery.

The proof uses a scenario-owned SQLite envelope store, restarts the Workflow
server, and verifies that a `dead_lettered` outbox envelope can only be
recovered by an operator-shaped requeue request. After requeue, a worker claims
and acks the same envelope through Workflow routes, and restart status proves
the `acked` state and `requeue_count=1` lineage persisted.

The SQLite file is the only local dependency seam; the Workflow server,
external plugin loader, and Signal plugin steps run unchanged.
