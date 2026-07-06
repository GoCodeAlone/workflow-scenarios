# Scenario 136: Signal Inbox Worker Lifecycle

This scenario starts a real `workflow-server`, loads released
`workflow-plugin-signal v0.35.1` as an external plugin, and drives
participant-parametric HTTP routes through Signal inbox worker lifecycle
behavior.

The proof uses a scenario-owned SQLite envelope store, restarts the Workflow
server, and verifies inbox claim leases, lease-required decrypt for claimed
records, release, stale reclaim, dead-letter, operator requeue, ack, status
lineage, and restart persistence through the running Workflow HTTP app.

The SQLite file is the only local dependency seam; the Workflow server,
external plugin loader, and Signal plugin steps run unchanged.
