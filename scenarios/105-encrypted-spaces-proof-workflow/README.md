# Scenario 105 - Encrypted Spaces Proof Workflow

Local-only Workflow app proof that the Encrypted Spaces Workflow plugin can
verify a state-gated, proof-gated append flow and emit redacted proof evidence
through a running Workflow API.

The scenario builds `workflow-plugin-encrypted-spaces`, loads it as an external
Workflow plugin under a temporary `data/plugins` directory, launches the real
Workflow server, and drives fixture-backed HTTP routes with two independent
members:

- clients initialize a space with two member IDs via `POST /spaces/{space}/members`
- member A appends an encrypted operation via `POST /spaces/{space}/members/{member}/operations`
- member B appends a separate encrypted operation via the same route
- a proof client verifies each returned commitment via `POST /spaces/{space}/proof`
- the test asserts the two member operations produce distinct commitments
- an unknown member is rejected before append
- a client removes member B and proves member B can no longer append
- the Workflow server is restarted and the same local file state snapshot is
  reloaded before member checks are repeated

The app uses an in-memory encrypted-space operation store and a named
file-backed `encrypted_space.state_store` for membership snapshots. The test
generates a per-run runtime config with a temporary local state path, verifies
the snapshot has schema/checksum metadata, restarts Workflow, and confirms the
removed member remains rejected after reload. The route path, member IDs,
operation ID, encrypted payload, expected commitment, membership proof vector,
and checkpoint proof vector are request inputs, not baked into the workflow
pipeline. The
default proof digest fixtures are intentionally bound to the
`space-1`/`member-1` and `space-1`/`member-2` membership tuples; callers may
override the `SPACE_ID`, `MEMBER_ID`, `MEMBER_B_ID`, `MEMBERSHIP_DIGEST`,
`MEMBERSHIP_B_DIGEST`, and `CHECKPOINT_DIGEST` environment variables consumed
by `test/run.sh` together when testing another vector tuple.

## Running

```bash
bash scenarios/105-encrypted-spaces-proof-workflow/test/run.sh
```

Set `WORKFLOW_SERVER` or `WORKFLOW_REPO` when running outside the standard
workspace layout. The test uses a local `ENCRYPTED_SPACES_PLUGIN_REPO` only if
it advertises file-backed `encrypted_space.state_store`; otherwise it clones
`GoCodeAlone/workflow-plugin-encrypted-spaces` at
`ENCRYPTED_SPACES_PLUGIN_REF` (default `v0.6.0`). `PLUGIN_VERSION` defaults to
the tag/ref value with a leading `v` stripped for version tags.

The Workflow app runtime is local-only and uses no S3 bucket or live external
service egress. The test harness may fetch the plugin source from GitHub when a
compatible local plugin checkout with file state-store support is not
available.
