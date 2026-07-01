# Scenario 104 - Signal E2E Encryption

Local-only Workflow app proof that the Signal Workflow plugin can perform an
end-to-end encrypted message exchange through `wfctl pipeline run`.

The scenario builds `workflow-plugin-signal`, loads it as an external Workflow
plugin, and runs `config/app.yaml` with the Workflow engine. The app prepares a
Bob pre-key bundle, encrypts a base64 message as Alice, decrypts as Bob, and
asserts that the decrypted plaintext appears in Workflow pipeline output.

## Running

```bash
bash scenarios/104-signal-e2e-encryption/test/run.sh
```

Set `WFCTL`, `WORKFLOW_REPO`, or `SIGNAL_PLUGIN_REPO` when running outside the
standard workspace layout.

No official Signal service endpoint, account, phone number, or production
transport is used.
