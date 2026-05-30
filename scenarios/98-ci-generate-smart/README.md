# Scenario 98 — CI Generate Smart (Plan then Generate)

Category **C** (config-validation / CLI-driven). No live cloud credentials required.

## What it tests

- `wfctl ci plan --out plan.json` emits a platform-neutral CIPlan JSON with a
  `secrets` array (APP_DB_URL, APP_JWT) and a non-empty `warnings` array
- `wfctl ci generate --from-plan plan.json --platform github_actions --write` writes
  a `.github/workflows/*.yml` from the pre-computed plan
- The generated YAML: parses as valid YAML, wires `${{ secrets.APP_JWT }}`,
  includes a `wfctl plugin install` step, includes a functional migration step
  (`wfctl migrations up --config '...'`), and includes a smoke-test job hitting
  `app.example.com/healthz`

## Running

```bash
WFCTL_BIN=/path/to/wfctl bash scenarios/98-ci-generate-smart/test/run.sh
```

The script creates a fresh `mktemp` directory per run and exports `SC98_STORE_DIR`
and `SC98_STATE_DIR` so the env-expandable paths in `config/app.yaml` resolve correctly.
