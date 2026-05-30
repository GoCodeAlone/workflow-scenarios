# Scenario 97 — Secrets Wizard Non-interactive Mode

Category **C** (config-validation / CLI-driven). No live cloud credentials required.

## What it tests

- `wfctl secrets list --json` returns valid JSON with accurate `exists` flags
- `wfctl secrets setup --non-interactive --from-env --only` writes to a file-backed store
- After setup, `list --json` shows the target secret as `exists: true`
- `--skip-existing` is a true no-op (reports 0 set)
- The audit JSONL at `$XDG_STATE_HOME/wfctl/plugins/wfctl/secrets-audit.jsonl` records
  the write event but never exposes the secret value (value-never-leaked)

## Running

```bash
WFCTL_BIN=/path/to/wfctl bash scenarios/97-secrets-wizard-noninteractive/test/run.sh
```

The script creates a fresh `mktemp` directory per run and exports `SC97_STORE_DIR`
so the file-store path in `config/app.yaml` (`${SC97_STORE_DIR}`) resolves correctly.
