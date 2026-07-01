# Scenario 104 — Signal E2E Encryption

Local-only proof that the released Signal Workflow plugin can perform an
end-to-end encrypted message exchange using its real typed step code.

The scenario creates a temporary Go module, pins
`github.com/GoCodeAlone/workflow-plugin-signal@v0.9.0`, then runs the released
plugin's focused step tests:

- `TestSignalSessionPrepareEncryptDecryptRoundTrip`
- `TestSignalDecryptDeniesUnauthorizedPrincipalWithoutPlaintext`

Those tests execute the actual Workflow plugin step implementations for
identity setup, pre-key bundle preparation, encryption, decrypt authorization,
and decryption. The test asserts ciphertext does not contain plaintext and that
an unauthorized principal cannot recover plaintext.

## Running

```bash
bash scenarios/104-signal-e2e-encryption/test/run.sh
```

No official Signal service endpoint, account, phone number, or production
transport is used.
