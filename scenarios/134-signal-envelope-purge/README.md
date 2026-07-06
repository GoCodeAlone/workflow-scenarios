# Scenario 134: Signal Envelope Purge

This scenario starts a real `workflow-server`, loads released
`workflow-plugin-signal v0.34.0` as an external plugin, and drives
participant-parametric HTTP routes through Signal terminal envelope retention.

The proof uses a scenario-owned SQLite envelope store, restarts the Workflow
server, and creates active queued/claimed records plus terminal
`dead_lettered`, `acked`, and inbox `received` records. It proves purge preview
returns bounded redacted summaries without deletion, destructive purge rejects
active statuses, terminal purge removes only terminal records, and restart
status shows purged records remain absent while active records survive.

The SQLite file is the only local dependency seam; the Workflow server,
external plugin loader, and Signal plugin steps run unchanged.
