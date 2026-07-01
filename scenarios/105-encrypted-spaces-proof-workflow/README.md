# Scenario 105 - Encrypted Spaces Proof Workflow

Local-only Workflow app proof that the Encrypted Spaces Workflow plugin can
verify a proof-gated append flow and emit redacted proof evidence.

The scenario builds `workflow-plugin-encrypted-spaces`, loads it as an external
Workflow plugin, and runs `config/app.yaml` with the Workflow engine. The app
uses an in-memory encrypted-space store, appends an encrypted operation, verifies
the expected commitment with membership and key-transparency vector evidence,
and emits proof-evidence output.

## Running

```bash
bash scenarios/105-encrypted-spaces-proof-workflow/test/run.sh
```

Set `WFCTL`, `WORKFLOW_REPO`, or `ENCRYPTED_SPACES_PLUGIN_REPO` when running
outside the standard workspace layout.

No S3 bucket or live external service egress is used.
