# Scenario 119 - Signal HTTP Trust History

Local-only Workflow app proof that `workflow-plugin-signal` can use a
host-managed HTTP trust-store backend and expose redacted trust history through
a Workflow application route.

The scenario builds `workflow-plugin-signal` v0.25.0 as an external plugin,
loads it through the Workflow server plugin directory, starts a committed fake
HTTP trust backend, starts `workflow-server`, and drives participant-parametric
HTTP routes:

- participants publish local Signal bundles through `POST /participants/{id}/session`
- two independent participant pairs use the same trusted-send and history routes
- `signal.trust_store` loads and persists snapshots through `GET/PUT /snapshot`
  on the fake HTTP backend with an `Authorization` header
- a sender records initial trust and sends encrypted content through
  `POST /spaces/{space}/participants/{sender}/trusted-send/{recipient}`
- a changed recipient identity key is rejected before reset
- reset requests without `reason_ref` fail
- reset requests with stale `previous_record_ref` fail
- a reset with the correct previous record ref and approval reason succeeds
- redacted trust history is queried through
  `POST /spaces/{space}/participants/{sender}/trust-history/{recipient}`
- the new key is accepted and the old key is rejected
- the Workflow server restarts and reloads the same HTTP trust snapshot/history
- forced HTTP generation conflicts leave durable backend state unchanged
- invalid backend auth and corrupt backend snapshots fail closed during startup

The local identity pool is a conformance fixture. Participant IDs, space IDs,
message refs, reason refs, previous record refs, plaintext, local bundles, and
remote bundles are supplied by the test harness through HTTP path params and
request bodies rather than hard-coded in the Workflow pipelines.

The fake backend is a local test double for host-managed storage. It does not
contact the official Signal service, register accounts, link devices, send
Signal messages, or interact with an official Signal app.

## Running

```bash
bash scenarios/119-signal-trust-http-history/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, `SIGNAL_PLUGIN_REPO`, or
`SIGNAL_PLUGIN_REF` when running outside the standard workspace layout.
