# Scenario 132: Signal Outbox DLQ

This scenario starts a real `workflow-server`, loads released
`workflow-plugin-signal v0.33.0` as an external plugin, and drives
participant-parametric HTTP routes through Signal outbox dead-letter behavior.

The proof uses a scenario-owned SQLite envelope store, restarts the Workflow
server, and verifies that `dead_lettered` state survives restart. It also proves
that default max-attempt release remains compatible, while explicit
`dead_letter_on_max_attempts` transitions to terminal quarantine.
