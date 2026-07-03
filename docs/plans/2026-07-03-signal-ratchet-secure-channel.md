# Signal Ratchet Secure Channel Plan

## Scope Manifest

- P1: Add scenario 106 docs and manifest metadata.
- P2: Add a Workflow app config based on the released Signal primitive surface.
- P3: Add a test harness that builds/resolves `ratchet`, generates a real
  Ratchet flow-run bundle, launches Workflow, and drives Signal routes.
- P4: Verify locally with the scenario test and update `scenarios.json`.
- P5: Open PR, monitor CI/review, merge when green.
- P6: Record workspace state and follow-ups if the scenario exposes a missing
  Signal/Ratchet primitive.

## Acceptance

- The scenario executes a real `ratchet` binary and a real Workflow server.
- Signal encryption/decryption happens through `workflow-plugin-signal`, loaded
  as an external plugin.
- The proof is actor-parametric: sender/recipient IDs are route/input values,
  not baked into the pipeline.
- The test fails if plaintext or the Ratchet descriptor marker appears in the
  encrypted queue response.
- Any missing primitive becomes a follow-up or implementation task before
  claiming broader Ratchet secure-channel support.

