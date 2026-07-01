# Scenario 105 — Encrypted Spaces Proof Workflow

Local-only proof that the released Encrypted Spaces Workflow plugin can verify a
proof-gated append flow and emit redacted proof evidence.

The scenario creates a temporary Go module, pins
`github.com/GoCodeAlone/workflow-plugin-encrypted-spaces@v0.4.0`, then runs the
released plugin's focused proof workflow tests:

- `TestAppendVerifiedAcceptsVectorBackedProof`
- `TestAppendVerifiedRejectsTamperedProof`
- `TestProofEvidenceRedactsPlaintextAndKeyMaterial`
- `TestVectorReportStepFiltersRequiredDomains`

Those tests execute the actual Workflow plugin step implementations for
vector-backed append verification, tamper rejection, coverage filtering, and
proof-evidence redaction.

## Running

```bash
bash scenarios/105-encrypted-spaces-proof-workflow/test/run.sh
```

No live external service egress is used.
