# Scenario 124 - Signal Envelope SQLite

Local-only Workflow app proof that `workflow-plugin-signal` v0.29.0 can persist
encrypted envelope lifecycle state through the SQLite `signal.envelope_store`
backend.

The scenario builds `workflow-plugin-signal` as a released external plugin,
loads it through the Workflow server plugin directory, starts `workflow-server`
with `signal.envelope_store backend: sqlite`, and drives separate
participant-parametric HTTP routes:

- a queued envelope is sent before restart and claimed, delivered, and acked
  after restart
- a claimed envelope is released before restart and reclaimed after restart with
  retry metadata intact
- an acked envelope decrypts before restart, then remains terminal after restart
  and cannot be reclaimed
- the SQLite snapshot row exists and contains ciphertext envelope state, but not
  the plaintext markers used by the test

The app config contains a small local identity pool, but participant IDs,
space IDs, worker IDs, message refs, plaintext, leases, and envelopes are
supplied by the test harness through HTTP path params and request bodies rather
than baked into the Workflow pipelines.

The SQLite database is a scenario-local file under the test temp directory. The
scenario does not contact the official Signal service, register accounts, link
devices, send Signal messages, or interact with an official Signal app.

## Running

```bash
bash scenarios/124-signal-envelope-sqlite/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, `SIGNAL_PLUGIN_REPO`, or
`SIGNAL_PLUGIN_REF` when running outside the standard workspace layout.
