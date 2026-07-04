# Signal Object Directory

Local-only Workflow app proof that a host can publish a Signal public pre-key
bundle for a website-style intake route into `workflow-plugin-signal`'s
object-store public directory backend, public callers can resolve the persisted
bundle without an account after Workflow server restart, and submitted
message/blob content stays encrypted until an authorized operator decrypts it.

The scenario builds `workflow-plugin-signal` v0.18.0 as an external plugin,
starts `workflow-server`, and drives HTTP routes in `config/app.yaml`.
Operator routes publish bundles and decrypt submissions. Public routes resolve
the bundle and submit encrypted message/blob payloads. The
`signal.public_prekey_directory` module runs with `backend: object_store`,
`allow_object_store_backend: true`, and a per-run local object-store root. The
harness verifies that the plugin writes a checksum-protected object under a
hash-derived object key, resolves the same bundle after Workflow restart,
rejects a tampered object on restart, and checks that public/storage boundaries
do not expose plaintext, plaintext digests, content keys, custody refs, or
credential-shaped values.

The local object-store root is the disclosed dependency boundary. The scenario runs
the real Workflow server, real external `workflow-plugin-signal` binary, and
real HTTP routes; it does not replace the plugin or app under test with a fake.

Participant IDs, intake refs, audience refs, message markers, and blob refs are
request/env inputs. The Workflow app config has a local identity pool for
conformance, including default callers and the non-default `tenant-a`/`tenant-b`
fixture pair used by the parametric test, but the tested interaction is not
baked into the pipeline logic.
No official Signal service, official Signal app, sealed sender, browser SDK, or
persistent private identity custody is used. After restart, the test republish
step refreshes live in-memory identity custody before exercising message/blob
decrypt.

Run:

```sh
bash scenarios/113-signal-object-directory/test/run.sh
```

Useful overrides:

```sh
INTAKE_REF=contact-a CALLER_A=caller-a CALLER_B=caller-b \
AUDIENCE_REF=audience://site/contact \
bash scenarios/113-signal-object-directory/test/run.sh
```
