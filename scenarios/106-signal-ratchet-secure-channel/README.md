# Scenario 106 - Signal Ratchet Secure Channel

Local-only Workflow app proof that a real `ratchet-cli` flow-run bundle
descriptor can move through a Signal-encrypted Workflow channel without the
Workflow app or queue response exposing plaintext.

The scenario builds `workflow-plugin-signal`, loads it as an external Workflow
plugin under a temporary `data/plugins` directory, builds or resolves the real
`ratchet` CLI, launches the real Workflow server, and drives
participant-parametric HTTP routes:

- the harness executes `ratchet acp client flow run` to create an
  `acpx.flow-run-bundle.v1` run directory
- sender and recipient publish pre-key bundles via `POST /participants/{id}/session`
- sender enqueues an encrypted outbox envelope via
  `POST /participants/{sender}/outbox/{recipient}`
- recipient claims, receives, and decrypts that queued envelope via
  `POST /participants/{id}/messages/receive`

The app config contains a small local identity pool, but the workflows take
participant IDs and message content from HTTP route params and request bodies.
They do not hard-code an Alice/Bob conversation.
The local envelope store keeps ciphertext and routing refs only; the scenario
asserts the queue response does not expose the Ratchet descriptor marker or
plaintext before the recipient receives and decrypts it.

## Running

```bash
bash scenarios/106-signal-ratchet-secure-channel/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, `SIGNAL_PLUGIN_REPO`, or
`RATCHET_CLI_REPO` when running outside the standard workspace layout. If the
nearby checkouts do not advertise the required primitives, the harness clones
the pinned `SIGNAL_PLUGIN_REF` tag (default `v0.12.0`) or
`RATCHET_CLI_REF` tag (default `v0.25.0`).

No official Signal service endpoint, account, phone number, or production
transport is used.
