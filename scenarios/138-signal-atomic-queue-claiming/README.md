# Scenario 138: Signal Atomic Queue Claiming

This scenario starts a real `workflow-server`, loads released
`workflow-plugin-signal v0.36.0` as an external plugin, and drives
participant-parametric HTTP routes through Signal atomic queue claiming
behavior.

The proof uses a scenario-owned SQLite envelope store, restarts the Workflow
server, and verifies outbox `claim-next` and `claim-batch` worker polling,
oldest-first selection, duplicate claim rejection, terminal-state rejection,
claim-batch behavior, status visibility, and restart persistence through the
running Workflow HTTP app.

The SQLite file is the only local dependency seam; the Workflow server,
external plugin loader, and Signal plugin steps run unchanged.
