# Scenario 120 - Signal Trust Policy Gate

Local-only Workflow app proof that `workflow-plugin-signal` can use a
host-managed HTTP trust-store backend and enforce stored trust policy through a
Workflow application route before encrypted send/enqueue.

The scenario builds `workflow-plugin-signal` v0.26.0 as an external plugin,
loads it through the Workflow server plugin directory, starts a committed fake
HTTP trust backend, starts `workflow-server`, and drives participant-parametric
HTTP routes:

- participants publish local Signal bundles through `POST /participants/{id}/session`
- two independent participant pairs use the same trusted-send, policy, and
  history routes
- `signal.trust_store` loads and persists snapshots through `GET/PUT /snapshot`
  on the fake HTTP backend with an `Authorization` header
- a sender records initial trust and sends encrypted content through
  `POST /spaces/{space}/participants/{sender}/trusted-send/{recipient}`
- the trusted-send route runs `step.signal_trust_policy_check` after trust
  observation and before encryption/outbox enqueue
- `POST /spaces/{space}/participants/{sender}/trust-policy/{recipient}`
  enforces policy for caller-supplied `required_record_ref`
- `POST /spaces/{space}/participants/{sender}/trust-policy-report/{recipient}`
  returns report-only denial metadata for changed, stale, and missing trust
- a changed recipient identity key is rejected before reset
- enforcing policy denies the changed last trust status before another send
- report-only policy returns `last_status_denied`, `record_mismatch`, and
  `missing` without key material, plaintext, auth, or raw fingerprint evidence
- reset requests without `reason_ref` fail
- reset requests with stale `previous_record_ref` fail
- a reset with the correct previous record ref and approval reason succeeds
- policy allows the reset record, then allows the later trusted rotated record
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
bash scenarios/120-signal-trust-policy-gate/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, `SIGNAL_PLUGIN_REPO`, or
`SIGNAL_PLUGIN_REF` when running outside the standard workspace layout.
