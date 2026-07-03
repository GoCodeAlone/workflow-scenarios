# Signal Public Intake

Local-only Workflow app proof that a host can publish a Signal public pre-key
bundle for a website-style intake route, public callers can resolve it without
an account, and submitted message/blob content stays encrypted until an
authorized operator decrypts it.

The scenario builds `workflow-plugin-signal` v0.15.0 as an external plugin,
starts `workflow-server`, and drives HTTP routes in `config/app.yaml`.
Operator routes publish bundles and decrypt submissions. Public routes resolve
the bundle and submit encrypted message/blob payloads. A local file-backed mock
queue/object-store boundary persists only ciphertext JSON; the harness rejects
plaintext, plaintext digests, content keys, custody refs, and credential-shaped
values at public/storage boundaries.

Participant IDs, intake refs, audience refs, message markers, and blob refs are
request/env inputs. The Workflow app config has a local identity pool for
conformance, but the tested interaction is not baked into the pipeline logic.
No official Signal service, official Signal app, sealed sender, browser SDK, or
production directory backend is used.

Run:

```sh
bash scenarios/110-signal-public-intake/test/run.sh
```

Useful overrides:

```sh
INTAKE_REF=contact-a CALLER_A=caller-a CALLER_B=caller-b \
AUDIENCE_REF=audience://site/contact \
bash scenarios/110-signal-public-intake/test/run.sh
```
