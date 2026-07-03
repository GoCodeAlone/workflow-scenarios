# Signal Ratchet Secure Channel Design

## Context

P3 from the Signal scenario-derived capability matrix calls for a Ratchet or
`ratchet-cli` secure-channel proof using released Signal primitives. The goal
is not to add new cryptography first. The goal is to prove whether existing
Workflow Signal primitives can protect a realistic Ratchet artifact crossing an
untrusted application boundary.

Fresh verification:

- `workflow-scenarios` work starts from `origin/main` at scenario 104/105
  release-pinned proofs.
- `ratchet-cli` uses `master` as its default branch; the scenario pins the
  public `v0.25.0` tag because it contains flow-run bundle replay support.
- `workflow-plugin-signal` latest release is `v0.12.0`.

## Decision

Add scenario `106-signal-ratchet-secure-channel` in `workflow-scenarios`.

The scenario will:

- build or resolve the real `ratchet` CLI;
- execute `ratchet acp client flow run` with a credential-free action flow to
  produce an actual `acpx.flow-run-bundle.v1` run directory;
- launch a real Workflow server with `workflow-plugin-signal v0.12.0` loaded as
  an external plugin;
- choose sender/recipient IDs from environment-defaulted inputs;
- publish recipient/sender pre-key bundles through HTTP routes;
- enqueue a Signal encrypted outbox envelope whose plaintext is a base64
  encoded Ratchet secure-channel descriptor derived from the real flow bundle;
- verify the queue response/envelope do not contain the descriptor marker or
  plaintext;
- have the recipient claim, receive, and decrypt the envelope through a
  separate HTTP API call;
- verify the decrypted descriptor points back to the real Ratchet run bundle
  manifest and run ID.

This is a Workflow application scenario, not a package test. It executes the
real `ratchet` CLI and the real Workflow server/plugin boundary. The only
fixtures are local participant IDs, local payload text, and local external
plugin/service binaries.

## Non-Goals

- No official Signal service contact, registration, live send/receive, phone
  number, or official app interaction.
- No new Ratchet daemon team-message feature unless the scenario exposes a
  missing CLI/API surface.
- No live object store, S3, database, or external queue.
- No hard-coded Alice/Bob pipeline.

## Validation

Run:

- `bash scenarios/106-signal-ratchet-secure-channel/test/run.sh`
- `make test SCENARIO=106-signal-ratchet-secure-channel` if the harness state
  update is safe to run sequentially

The test output must include PASS lines proving:

- real `ratchet` CLI execution;
- real `acpx.flow-run-bundle.v1` manifest;
- Workflow Signal plugin loaded externally;
- sender/recipient IDs supplied through route params/test inputs;
- queued ciphertext does not expose plaintext or marker;
- recipient decrypts the original Ratchet bundle descriptor.
