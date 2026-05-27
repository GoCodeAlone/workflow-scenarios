# Scenario 92 — Exploratory QA Template

Filled out by the post-PR-2 exploratory-QA agent via the `playwright-cli`
skill in headless mode with isolated browser sessions per workspace
convention. This is **separate** from the regression Playwright spec
at `workflow-scenarios/e2e/tests/scenario-92-infra-admin.spec.ts`.

## Setup

| Field | Value |
|---|---|
| Base URL | http://127.0.0.1:18092 |
| Variant | stub (default) or do-dryrun |
| Browser | Chromium headless |
| Capture dir | `test/screenshots/` |

Run `./seed/seed.sh` first; abort if `/healthz` doesn't come up.

## Pages walked

- [ ] `/admin/infra-admin/resources.html`
- [ ] `/admin/infra-admin/resource.html?name=<seeded>`
- [ ] `/admin/infra-admin/new.html`

Per page, capture: visible navigation, error region empty, filters
render, primary content loaded without console errors.

## Dropdown population per type (new.html)

For each typed module, open new.html, select the type, screenshot the
form, assert each dropdown is populated from the correct enum source.

| Type | provider dropdown | region dropdown | engine / size dropdown | screenshot |
|---|---|---|---|---|
| infra.vpc                |  |  | n/a |  |
| infra.container_service  |  |  | n/a |  |
| infra.k8s_cluster        |  |  | size: enum_dynamic / sizes |  |
| infra.database           |  |  | engine: enum_dynamic / engines (depends_on provider) |  |
| infra.cache              |  |  | engine: enum (redis/memcached/valkey) |  |
| infra.load_balancer      |  |  | n/a |  |
| infra.dns                |  | n/a (region omitted by design) | n/a |  |
| infra.registry           |  |  | n/a |  |
| infra.api_gateway        |  |  | n/a |  |
| infra.firewall           |  |  | n/a |  |
| infra.iam_role           |  |  | n/a |  |
| infra.storage            |  |  | n/a |  |
| infra.certificate        |  |  | n/a |  |

## Form submission per type

For 4 representative types (vpc, database, container_service, k8s_cluster),
fill the form with valid values and submit. Capture the generated YAML output.

| Type | Filled values | YAML output snippet | Pass/Fail |
|---|---|---|---|
| infra.vpc                | provider=stub-provider region=test-region-1 cidr=10.0.0.0/16 |  |  |
| infra.database           | provider=stub-provider region=test-region-1 engine=postgres size=m storage_gb=20 version=15.5 multi_az=false |  |  |
| infra.container_service  | provider=stub-provider region=test-region-1 image=nginx:latest replicas=2 ports=[80,443] |  |  |
| infra.k8s_cluster        | provider=stub-provider region=test-region-1 version=1.30 node_count=3 node_size=m |  |  |

## CSP / security observations

- [ ] No inline scripts on any asset page (Network DevTools)
- [ ] Cookies have SameSite + Secure attrs where applicable
- [ ] `frame-ancestors 'self'` header on every asset response
- [ ] CSP `script-src 'self'` only (no unsafe-inline)

## Screenshots index

Capture as `test/screenshots/scenario-92-<page>-<note>.png`.

- `resources-empty.png` — pre-seed state
- `resources-populated.png` — after seed.sh
- `resource-detail-vpc.png`
- `new-form-vpc.png`
- `new-form-database.png`
- `new-form-container-service.png`
- `new-form-k8s.png`
- `yaml-output-vpc.png`

## Issues found (file as workflow#xxx)

| # | Severity | Description | File at |
|---|---|---|---|
|   |   |   |   |

## Sign-off

- Agent: _________
- Date: __________
- Variant tested: stub / do-dryrun / both
- Outcome: pass / fail (with linked follow-ups above)
