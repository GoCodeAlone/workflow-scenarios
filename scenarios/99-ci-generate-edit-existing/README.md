# Scenario 99 — CI Generate: Edit Existing / Drift Detection

Category **C** (config-validation / CLI-driven). No live cloud credentials required.

## What it tests

- `wfctl ci generate --write` produces a deterministic `.github/workflows/*.yml`
- Appending a stray line to the file simulates a manual edit
- `wfctl ci generate --diff --exit-code` exits **non-zero** and prints a diff when
  the on-disk file diverges from what would be generated
- After `--write` regenerates the clean file, `--diff --exit-code` exits **0**
  (idempotent re-generation — no drift)

This is the contract for using `wfctl ci generate --diff --exit-code` as a CI lint
gate that blocks PRs containing hand-edited workflow files.

## Running

```bash
WFCTL_BIN=/path/to/wfctl bash scenarios/99-ci-generate-edit-existing/test/run.sh
```

The script creates a fresh `mktemp` directory per run and exports `SC99_STORE_DIR`
and `SC99_STATE_DIR` so the env-expandable paths in `config/app.yaml` resolve correctly.
