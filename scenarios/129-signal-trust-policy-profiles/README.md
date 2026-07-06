# Scenario 129 - Signal Trust Policy Profiles

Local-only Workflow app proof that `workflow-plugin-signal` trust policy
profiles can gate Signal encryption inside a real Workflow HTTP application.

The scenario builds `workflow-plugin-signal` v0.32.0 as an external plugin,
loads it through the Workflow server plugin directory, starts `workflow-server`,
and drives participant-parametric HTTP routes:

- participants publish local Signal bundles through `POST /participants/{id}/session`
- a sender records first-use trust through
  `POST /spaces/{space}/participants/{sender}/trust-observe/{recipient}`
- `established_only` fails closed for the first `new_trust` record
- `fresh_30d` appears in report-only output for a fresh first-use record
- an unsupported profile fails closed
- repeated observation promotes the record to `trusted`, then `established_only`
  gates an encrypted send through
  `POST /spaces/{space}/participants/{sender}/trusted-send/{recipient}`
- a changed recipient identity key is rejected before reset
- reset requests without `reason_ref` or with stale `previous_record_ref` fail
- a reset with the correct previous record ref and approval reason succeeds
- `reset_only` admits the approved reset record
- the Workflow server restarts with the same file-backed trust store and keeps
  the reset trust record for an encrypted send with the new key
- responses and local trust state do not expose plaintext markers, custody refs,
  or private key material

The local identity pool is a conformance fixture. Participant IDs, space IDs,
message refs, reason refs, previous record refs, plaintext, local bundles, and
remote bundles are supplied by the test harness through HTTP path params and
request bodies rather than hard-coded in the Workflow pipelines. No official
Signal service endpoint, account, phone number, or production transport is used.

## Running

```bash
bash scenarios/129-signal-trust-policy-profiles/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, `SIGNAL_PLUGIN_REPO`, or
`SIGNAL_PLUGIN_REF` when running outside the standard workspace layout.
