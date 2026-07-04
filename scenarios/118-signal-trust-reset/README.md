# Scenario 118 - Signal Trust Reset

Local-only Workflow app proof that `workflow-plugin-signal` can rotate a stored
Signal safety-number trust decision only after app-supplied approval metadata.

The scenario builds `workflow-plugin-signal` v0.24.0 as an external plugin,
loads it through the Workflow server plugin directory, starts `workflow-server`,
and drives participant-parametric HTTP routes:

- participants publish local Signal bundles through `POST /participants/{id}/session`
- a sender records initial trust and sends encrypted content through
  `POST /spaces/{space}/participants/{sender}/trusted-send/{recipient}`
- a changed recipient identity key is rejected before reset
- reset requests without `reason_ref` fail
- reset requests with stale `previous_record_ref` fail
- a reset with the correct previous record ref and approval reason succeeds
- the new key is accepted through
  `POST /spaces/{space}/participants/{sender}/trust-check/{recipient}` and the
  old key is rejected
- the Workflow server restarts with the same file-backed trust store and keeps
  the rotated trust record for an encrypted send with the new key
- the audit JSONL includes the reset reason and previous/new refs without
  private key material

The local identity pool is a conformance fixture. Participant IDs, space IDs,
message refs, reason refs, previous record refs, plaintext, local bundles, and
remote bundles are supplied by the test harness through HTTP path params and
request bodies rather than hard-coded in the Workflow pipelines. No official
Signal service endpoint, account, phone number, or production transport is used.

## Running

```bash
bash scenarios/118-signal-trust-reset/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, `SIGNAL_PLUGIN_REPO`, or
`SIGNAL_PLUGIN_REF` when running outside the standard workspace layout.
