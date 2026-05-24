# DNS Replay Scenarios Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a public hermetic DNS/IaC replay scenario and backlog tracker for remaining DNS/IaC and workflow-compute work.

**Architecture:** Add a scenario-local replay fixture and validation script under `scenarios/88-iac-dns-replay-migration`. The script validates provider-neutral DNS preservation and migration safety without credentials or network calls. Add a Markdown backlog under `docs/backlog`.

**Tech Stack:** Bash, Python standard library JSON, Workflow scenario metadata.

**Base branch:** main

---

## Scope Manifest

**PR Count:** 1
**Tasks:** 4
**Estimated Lines of Change:** ~450

**Out of scope:**
- Live Cloudflare, DigitalOcean, Namecheap, Hover, or registrar API calls.
- Mock external plugin process harness.
- DNS management UI implementation.
- workflow-compute residue/reuse implementation.

**PR Grouping:**

| PR # | Title | Tasks | Branch |
|------|-------|-------|--------|
| 1 | Add DNS replay migration scenario | Task 1, Task 2, Task 3, Task 4 | feat/dns-replay-scenarios |

**Status:** Draft

## Task 1: Add Backlog Tracker

**Files:**
- Create: `docs/backlog/workflow-dns-iac-and-compute.md`

**Step 1: Write the tracker**

Create a concise Markdown backlog with sections for DNS/IaC scenarios, provider plugins, UI safety, and workflow-compute residue/reuse.

**Step 2: Verify it is readable**

Run: `sed -n '1,220p' docs/backlog/workflow-dns-iac-and-compute.md`
Expected: shows all backlog sections and no placeholder text.

**Step 3: Commit**

Run: `git add docs/backlog/workflow-dns-iac-and-compute.md && git commit -m "docs: track dns and compute follow-ups"`

## Task 2: Add DNS Replay Scenario Fixture

**Files:**
- Create: `scenarios/88-iac-dns-replay-migration/scenario.yaml`
- Create: `scenarios/88-iac-dns-replay-migration/README.md`
- Create: `scenarios/88-iac-dns-replay-migration/fixtures/dns-portfolio.json`
- Modify: `scenarios.json`

**Step 1: Write fixture**

Create sanitized snapshots with reserved domains/IPs:

- `hover-source.example`
- `do-authoritative.example`
- `namecheap-managed.example`
- `cloudflare-target.example`

Include NS, MX, TXT/SPF, TXT/DMARC, A, AAAA, CNAME, and provider authority metadata.

**Step 2: Register scenario metadata**

Add `88-iac-dns-replay-migration` to `scenarios.json` as `testable`, `localOnly: true`, `deployed: false`, and zeroed test counters.

**Step 3: Verify JSON and YAML parse**

Run: `python3 -m json.tool scenarios/88-iac-dns-replay-migration/fixtures/dns-portfolio.json >/tmp/dns-portfolio.pretty.json`
Expected: exit 0.

Run: `python3 -c "import yaml; yaml.safe_load(open('scenarios/88-iac-dns-replay-migration/scenario.yaml'))"`
Expected: exit 0.

**Step 4: Commit**

Run: `git add scenarios/88-iac-dns-replay-migration scenarios.json && git commit -m "feat: add dns replay scenario fixture"`

## Task 3: Add Offline Replay Validation

**Files:**
- Create: `scenarios/88-iac-dns-replay-migration/test/run.sh`
- Create: `scenarios/88-iac-dns-replay-migration/test/validate_dns_replay.py`

**Step 1: Write failing validation behavior**

Add Python validation that emits `PASS:` / `FAIL:` lines and exits non-zero on failed invariants. Required invariants:

- Every snapshot has provider, domain, authority, records.
- Every record has type, name, value, ttl.
- Canonical record keys preserve MX and TXT records.
- Migration target includes Cloudflare nameservers.
- Destructive deletes require explicit `manage_unlisted: true`.
- Provider coverage includes Cloudflare, DigitalOcean, Namecheap, Hover.

**Step 2: Add shell wrapper**

`test/run.sh` should call the Python script with the fixture path and preserve its exit code.

**Step 3: Verify scenario test**

Run: `bash scenarios/88-iac-dns-replay-migration/test/run.sh`
Expected: output includes `PASS: destructive deletes require explicit opt-in` and exits 0.

**Step 4: Commit**

Run: `git add scenarios/88-iac-dns-replay-migration/test && git commit -m "test: validate dns replay invariants"`

## Task 4: Verify and Open PR

**Files:**
- Modify only if verification exposes defects.

**Step 1: Run focused scenario**

Run: `bash scripts/test.sh 88-iac-dns-replay-migration`
Expected: `RESULT: ALL TESTS PASSED`.

**Step 2: Run repository validation**

Run: `GOWORK=off go test ./...`
Expected: root Go tests pass.

Run: `python3 -m json.tool scenarios.json >/tmp/workflow-scenarios.json`
Expected: exit 0.

Run: `bash scripts/pre-push`
Expected: either validates configs or reports wfctl missing and exits 0.

**Step 3: Commit any verification fixes**

Commit only if Step 1 or Step 2 required changes.

**Step 4: Push and PR**

Run: `git push -u origin feat/dns-replay-scenarios`
Expected: branch pushed.

Run: `gh pr create --fill`
Expected: PR URL.
