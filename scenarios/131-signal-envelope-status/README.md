# Scenario 131: Signal Envelope Status

This scenario starts a real `workflow-server`, loads released
`workflow-plugin-signal v0.33.0` as an external plugin, and drives
participant-parametric HTTP routes through Signal envelope lifecycle steps.

The proof is intentionally about application behavior, not package tests:
clients choose sender, recipient, worker, space, and message refs at runtime.
The status route executes `step.signal_envelope_status` and verifies that
ordinary operational responses omit plaintext, ciphertext, custody refs,
authorization refs, active lease refs, and unsafe raw failure text.

