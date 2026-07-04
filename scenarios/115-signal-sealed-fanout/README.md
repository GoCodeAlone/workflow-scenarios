# Signal Sealed Fanout

Local-only Workflow app proof that `workflow-plugin-signal` can encrypt a room
message for two caller-selected recipients, wrap both recipient-specific Signal
session envelopes with sealed-sender wire bytes, move only sealed transport
messages through a mock delivery boundary, and let each intended recipient
recover the sender and plaintext through Workflow HTTP routes.

The scenario builds `workflow-plugin-signal` v0.20.0 as an external plugin,
starts `workflow-server`, and drives the routes in `config/app.yaml`.
Participant IDs, room IDs, and recipient bundles are supplied by HTTP requests
and environment variables. The app config declares a local identity pool for
conformance, but the tested room conversation is not baked into the pipeline.

The fanout primitive is per-recipient sealed sender. It does not implement
Signal group sender-key crypto, official Signal service delivery, linked-device
automation, official Signal app interop, or persistent private identity custody.
The local identity pool and per-run mock transport directory are disclosed
dependency boundaries; the Workflow server, external plugin process, and HTTP
app routes are real.

Run:

```sh
bash scenarios/115-signal-sealed-fanout/test/run.sh
```

Useful overrides:

```sh
SENDER=tenant-a RECIPIENT_ONE=tenant-b RECIPIENT_TWO=user-c ROOM=private-room-b \
bash scenarios/115-signal-sealed-fanout/test/run.sh
```
