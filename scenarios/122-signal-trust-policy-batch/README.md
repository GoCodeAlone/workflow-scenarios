# Scenario 122 - Signal Trust Policy Batch

Local-only Workflow app proof that `workflow-plugin-signal` can enforce
multi-recipient stored trust with `step.signal_trust_policy_check_batch` before
encrypted send/enqueue.

The scenario builds `workflow-plugin-signal` v0.28.0 as an external plugin,
loads it through the Workflow server plugin directory, starts `workflow-server`,
and drives participant-parametric HTTP routes:

- participants publish local Signal bundles through `POST /participants/{id}/session`
- two independent participant pairs use the same trusted-send, policy, and
  history routes
- a sender uses `POST /spaces/{space}/participants/{sender}/group-send` with
  two recipient IDs and bundles supplied in the request body
- `signal.trust_store` loads and persists checksum-protected snapshots under a
  hash-derived local object key
- the group-send route observes both recipient keys, runs
  `step.signal_trust_policy_check_batch`, and only then encrypts/enqueues one
  recipient-specific envelope per recipient
- changed identity keys, stale required record refs, missing trust, invalid
  resets, and old-key reuse are denied
- report-only batch policy returns per-recipient denial metadata, while
  enforcing batch policy fails closed
- duplicate and oversized recipient lists fail closed through Workflow routes
- reset, history, and policy metadata remain redacted
- restart reloads the object snapshot and preserves trusted send policy
- tampered object snapshots fail closed during app startup
- same-store snapshots moved under a wrong object key fail closed during app
  startup

The local identity pool is a conformance fixture. Participant IDs, space IDs,
message refs, reason refs, previous record refs, plaintext, local bundles, and
remote bundles are supplied by the test harness through HTTP path params and
request bodies rather than hard-coded in the Workflow pipelines.

The object store is a local filesystem emulator. It does not contact the
official Signal service, register accounts, link devices, send Signal messages,
or interact with an official Signal app.

## Running

```bash
bash scenarios/122-signal-trust-policy-batch/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, `SIGNAL_PLUGIN_REPO`, or
`SIGNAL_PLUGIN_REF` when running outside the standard workspace layout.
