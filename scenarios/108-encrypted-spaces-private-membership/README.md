# Scenario 108 - Encrypted Spaces Private Membership

Local-only Workflow app proof that `workflow-plugin-encrypted-spaces` exposes
private membership credentials as usable Workflow primitives.

The scenario builds `workflow-plugin-encrypted-spaces`, loads it as an external
Workflow plugin under a temporary `data/plugins` directory, launches the real
Workflow server, and drives HTTP routes for two independent clients:

- `POST /spaces/{space}/members/{member}/private-credential` issues an opaque
  credential for a caller-supplied member ID.
- `POST /spaces/{space}/private-memberships/present` presents that credential
  for a caller-supplied operation ID.
- `POST /spaces/{space}/private-memberships/verify` verifies the presentation.
- `POST /spaces/{space}/private-memberships/verify-revoked` rejects the same
  presentation when its opaque member commitment is in the request-derived
  revocation set.

The test asserts that both participants receive distinct opaque commitments,
accepted verification reports have `official_zk_equivalent != true`, revoked
commitments are rejected, operation mismatches are rejected, and credential,
presentation, verification, and rejection responses do not expose plaintext
member IDs or issuer secret material. Participant IDs and operation IDs are
request inputs; the Workflow app config does not hard-code them.

## Running

```bash
bash scenarios/108-encrypted-spaces-private-membership/test/run.sh
```

Set `WORKFLOW_SERVER` or `WORKFLOW_REPO` when running outside the standard
workspace layout. The test uses a local `ENCRYPTED_SPACES_PLUGIN_REPO` only if
it advertises `step.encrypted_space_private_membership_verify`; otherwise it
clones `GoCodeAlone/workflow-plugin-encrypted-spaces` at
`ENCRYPTED_SPACES_PLUGIN_REF` (default `v0.8.0`). `PLUGIN_VERSION` defaults to
the tag/ref value with a leading `v` stripped for version tags.

The runtime is local-only. It does not contact the official Signal service and
does not implement official Signal zero-knowledge groups; it proves the
Workflow-compatible local private-membership subset exported by
`encrypted-spaces-go`.
