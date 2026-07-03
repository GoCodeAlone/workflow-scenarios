# Scenario 107 - Signal Encrypted Blob Handoff

Local-only Workflow app proof that a private blob can be encrypted by one
participant, stored in a mock object-store boundary without plaintext or content
keys, and decrypted by another participant through Workflow and
`workflow-plugin-signal`.

The scenario builds `workflow-plugin-signal`, loads it as an external Workflow
plugin under a temporary `data/plugins` directory, launches the real Workflow
server, and drives participant-parametric HTTP routes:

- recipient publishes a pre-key bundle via `POST /participants/{id}/session`
- sender encrypts blob bytes via `POST /participants/{sender}/blobs/{recipient}`
- the harness stores the returned encrypted blob JSON as a local object-store
  mock and verifies it does not contain plaintext, plaintext digest, or content
  key material
- recipient decrypts the stored encrypted blob via
  `POST /participants/{id}/blobs/decrypt`

The app config contains a small local identity pool, but the workflows take
participant IDs and blob content from HTTP route params and request bodies. They
do not hard-code an Alice/Bob conversation.

## Running

```bash
bash scenarios/107-signal-encrypted-blob/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, or `SIGNAL_PLUGIN_REPO` when running
outside the standard workspace layout. If nearby checkouts do not advertise the
required blob primitives, the harness clones the pinned `SIGNAL_PLUGIN_REF` tag
(default `v0.13.0`).

No official Signal service endpoint, account, phone number, media upload, or
production transport is used.
