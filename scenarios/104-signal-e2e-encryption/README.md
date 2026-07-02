# Scenario 104 - Signal E2E Encryption

Local-only Workflow app proof that the Signal Workflow plugin can perform a
two-way end-to-end encrypted message exchange through a running Workflow API.

The scenario builds `workflow-plugin-signal`, loads it as an external Workflow
plugin under a temporary `data/plugins` directory, launches the real Workflow
server, and drives participant-parametric HTTP routes:

- client A and client B publish pre-key bundles via `POST /participants/{id}/session`
- client A encrypts a message via `POST /participants/{id}/messages`
- client B decrypts the envelope via `POST /participants/{id}/messages/decrypt`
- client B encrypts a reply via the same route
- client A decrypts the reply via the same route
- client A prepares a custody-attested service send envelope via
  `POST /participants/{id}/service/send-prepare`

The app config contains a small local identity pool, but the workflows take
participant IDs and message content from HTTP route params and request bodies.
They do not hard-code an Alice/Bob conversation.

## Running

```bash
bash scenarios/104-signal-e2e-encryption/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, or `SIGNAL_PLUGIN_REPO` when running
outside the standard workspace layout. If the nearby `workflow-plugin-signal`
checkout does not advertise the service-readiness primitives required by this
scenario, the harness clones the pinned `SIGNAL_PLUGIN_REF` tag, defaulting to
`v0.11.0`.

No official Signal service endpoint, account, phone number, or production
transport is used.
