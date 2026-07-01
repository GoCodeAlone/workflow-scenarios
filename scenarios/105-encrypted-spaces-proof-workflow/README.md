# Scenario 105 - Encrypted Spaces Proof Workflow

Local-only Workflow app proof that the Encrypted Spaces Workflow plugin can
verify a proof-gated append flow and emit redacted proof evidence through a
running Workflow API.

The scenario builds `workflow-plugin-encrypted-spaces`, loads it as an external
Workflow plugin under a temporary `data/plugins` directory, launches the real
Workflow server, and drives fixture-backed HTTP routes:

- a client appends an encrypted operation via `POST /spaces/{space}/operations`
- a proof client verifies the returned commitment via `POST /spaces/{space}/proof`

The app uses an in-memory encrypted-space store. The route path, operation ID,
encrypted payload, expected commitment, membership proof vector, and checkpoint
proof vector are request inputs, not baked into the workflow pipeline. The
proof digest fixture is intentionally bound to the `space-1`/`member-1`
membership tuple.

## Running

```bash
bash scenarios/105-encrypted-spaces-proof-workflow/test/run.sh
```

Set `WORKFLOW_SERVER`, `WORKFLOW_REPO`, or `ENCRYPTED_SPACES_PLUGIN_REPO` when
running outside the standard workspace layout.

No S3 bucket or live external service egress is used.
