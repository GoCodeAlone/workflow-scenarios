# Scenario 125 - Signal Envelope Object Store

Local-only Workflow app proof that `workflow-plugin-signal` v0.30.0 can persist
encrypted envelope lifecycle state through the `object_store`
`signal.envelope_store` backend.

The scenario builds `workflow-plugin-signal` as a released external plugin,
loads it through the Workflow server plugin directory, starts `workflow-server`
with `signal.envelope_store backend: object_store`, and drives separate
participant-parametric HTTP routes:

- a queued envelope is sent before restart and claimed, delivered, and acked
  after restart
- a claimed envelope is released before restart and reclaimed after restart with
  retry metadata intact
- an acked envelope decrypts before restart, then remains terminal after restart
  and cannot be reclaimed
- the persisted object snapshot exists, carries a checksum, and contains
  ciphertext envelope state, but not the plaintext markers used by the test

The app config contains a small local identity pool, but participant IDs,
space IDs, worker IDs, message refs, plaintext, leases, and envelopes are
supplied by the test harness through HTTP path params and request bodies rather
than baked into the Workflow pipelines.

The object-store root is a scenario-local directory under the test temp
directory. This is a dependency seam for the plugin's object storage contract,
not a replacement for the Workflow app or Signal plugin code under test. The
scenario does not contact the official Signal service, register accounts, link
devices, send Signal messages, or interact with an official Signal app.

## Running

```bash
bash scenarios/125-signal-envelope-object-store/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, `SIGNAL_PLUGIN_REPO`, or
`SIGNAL_PLUGIN_REF` when running outside the standard workspace layout.
