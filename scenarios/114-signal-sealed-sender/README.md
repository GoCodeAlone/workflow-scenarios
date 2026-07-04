# Signal Sealed Sender

Local-only Workflow app proof that `workflow-plugin-signal` can issue a
locally managed sealed-sender certificate, wrap an encrypted Signal session
envelope in sealed-sender wire bytes, and let only the intended recipient
recover the sender and plaintext through Workflow HTTP routes.

The scenario builds `workflow-plugin-signal` v0.19.0 as an external plugin,
starts `workflow-server`, and drives the routes in `config/app.yaml`.
Participant IDs are supplied by request paths and environment variables. The
app config declares a local identity pool for conformance, but the tested
conversation is not baked into the pipeline.

The harness persists only `sealed_message` JSON to a per-run mock transport
file and verifies that the transport does not expose plaintext or sender
identity. It also verifies wrong-principal denial, wrong-recipient rejection,
visible recipient-routing tamper rejection, sealed-byte tamper rejection, wrong
trust-root rejection, and a second participant pair through the same routes.

No official Signal service, official Signal app, linked-device automation,
group fanout, or persistent private identity custody is used. The local
identity pool and mock transport file are disclosed dependency boundaries; the
Workflow server, external plugin process, and HTTP app routes are real.

Run:

```sh
bash scenarios/114-signal-sealed-sender/test/run.sh
```

Useful overrides:

```sh
SENDER=tenant-a RECIPIENT=tenant-b THIRD_PARTY=user-c \
bash scenarios/114-signal-sealed-sender/test/run.sh
```
