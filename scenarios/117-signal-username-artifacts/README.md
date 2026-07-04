# Scenario 117 - Signal Username Artifacts

Local-only Workflow app proof that `workflow-plugin-signal` can prepare Signal
username reservation hash artifacts and submit hash-only username reserve
requests through the fake service boundary.

The scenario builds `workflow-plugin-signal` v0.23.0 as an external plugin,
loads it through the Workflow server plugin directory, starts
`workflow-server`, and drives account-parametric HTTP routes:

- callers prepare exact username artifacts through
  `POST /accounts/{account}/username-artifacts`
- callers prepare nickname candidate artifacts through the same route
- callers reserve a username from a prepared artifact through
  `POST /accounts/{account}/username-reservations/from-username`
- callers submit direct hash candidates through
  `POST /accounts/{account}/username-reservations/hash`
- malformed or missing hash requests fail before consuming the fake service
  idempotency slot

The local account pool is a conformance fixture. Account IDs, request refs,
usernames, nicknames, and hash candidates are supplied by the test harness
through HTTP path params and request bodies rather than hard-coded in the
Workflow pipelines. No official Signal service endpoint, account, phone number,
or production transport is used.

## Running

```bash
bash scenarios/117-signal-username-artifacts/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, `SIGNAL_PLUGIN_REPO`, or
`SIGNAL_PLUGIN_REF` when running outside the standard workspace layout.
