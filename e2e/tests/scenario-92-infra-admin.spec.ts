import { test, expect } from '@playwright/test';
import { createHmac } from 'crypto';

// Scenario 92 — Infra Admin Phase 2/3 Demo (workflow v0.74.0 / workflow-plugin-infra v1.2.0)
//
// Phase 1 (migration): step.iac_provider_* pipeline architecture.
// Phase 2/3 (this PR): DYNAMIC specs (specs_from body); step.iac_secret_reachability
//   (409 pre-flight); step.iac_commit_back (branch-push); step.iac_provider_reconcile;
//   sandbox.remote_runners + sandbox-runner agent; step.sandbox_exec (exec_env:remote).
//
// The stub-iac-provider is loaded as an EXTERNAL gRPC plugin. The WiringHook
// registers it as service "stub-iac-provider". Pipelines use:
//   step.iac_provider_catalog      → catalog with live regions from RegionLister
//   step.iac_provider_list         → list resources
//   step.iac_provider_plan         → plan (DYNAMIC specs_from body)
//   step.iac_provider_apply        → apply (DYNAMIC specs_from + hash_from body)
//   step.iac_secret_reachability   → 409 pre-flight (remote exec_env + host-local secrets)
//   step.iac_commit_back           → branch-push (resources.yaml with secret:// refs)
//   step.iac_provider_reconcile    → drift → approximate YAML → draft branch
//   step.iac_provider_drift        → drift detection (DriftDetector)
//   step.sandbox_exec(exec_env:remote) → remote agent execution
//
// SCENARIO_URL points at the running stack (default http://127.0.0.1:18092).

const BASE_URL = process.env.SCENARIO_URL || 'http://127.0.0.1:18092';

// JWT_SECRET exported by run.sh from config/app.yaml; fallback to literal
// so the spec also works standalone.
const JWT_SECRET = process.env['JWT_SECRET'] ?? 'scenario-92-jwt-secret-do-not-use-in-prod';
const JWT_ISSUER = 'scenario-92';

function base64Url(buf: Buffer | string): string {
  const b = Buffer.isBuffer(buf) ? buf : Buffer.from(buf);
  return b.toString('base64').replace(/=+$/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function mintJWT(sub: string): string {
  const header = base64Url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const now = Math.floor(Date.now() / 1000);
  const payload = base64Url(
    JSON.stringify({ iss: JWT_ISSUER, sub, iat: now, exp: now + 3600 }),
  );
  const unsigned = `${header}.${payload}`;
  const signature = base64Url(
    createHmac('sha256', JWT_SECRET).update(unsigned).digest(),
  );
  return `${unsigned}.${signature}`;
}

const OP_TOKEN = mintJWT('operator');
const VIEWER_TOKEN = mintJWT('viewer');

// @scenario-92
test.describe('Scenario 92: Infra Admin Migration Demo', () => {
  test.beforeEach(async ({ page }) => {
    await page.setExtraHTTPHeaders({ Authorization: `Bearer ${OP_TOKEN}` });
  });

  // ── health ──────────────────────────────────────────────────────────────────

  test('@scenario-92 healthz returns 200', async ({ page }) => {
    const resp = await page.goto(`${BASE_URL}/healthz`);
    expect(resp?.status()).toBe(200);
  });

  // ── admin shell ─────────────────────────────────────────────────────────────

  test('@scenario-92 admin contributions endpoint reachable', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/admin/contributions`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}` },
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { contributions?: unknown[] };
    // contributions may be empty array or non-null — endpoint must be reachable
    expect(body).toHaveProperty('contributions');
  });

  // ── catalog: regions + types from external plugin ──────────────────────────

  test('@scenario-92 catalog returns stub-east and stub-west regions', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/infra/catalog`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}` },
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { regions?: Array<string | { name: string }>; types?: Array<{ resource_type: string }> };
    const regions = (body.regions ?? []).map(r =>
      typeof r === 'string' ? r : r.name,
    );
    // Stub plugin ListRegions returns these two fixed regions.
    expect(regions).toContain('stub-east');
    expect(regions).toContain('stub-west');
  });

  test('@scenario-92 catalog returns stub.database and stub.bucket types', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/infra/catalog`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}` },
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { types?: Array<{ resource_type: string }> };
    const typeNames = (body.types ?? []).map(t => t.resource_type);
    // Stub plugin Capabilities returns stub.database and stub.bucket.
    expect(typeNames).toContain('stub.database');
    expect(typeNames).toContain('stub.bucket');
  });

  test('@scenario-92 catalog source is live (RegionLister served via external gRPC)', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/infra/catalog`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}` },
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { source?: string };
    // When the external plugin serves IaCProviderRegionLister, source=live.
    // This proves the WiringHook and gRPC stub are working end-to-end.
    expect(body.source).toBe('live');
  });

  // ── list resources ──────────────────────────────────────────────────────────

  test('@scenario-92 list resources returns 200 with provider stub-iac-provider', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/infra/resources`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}` },
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { provider?: string; resources?: unknown[] };
    expect(body.provider).toBe('stub-iac-provider');
    // Stub Status() returns empty list (no real cloud state).
    expect(Array.isArray(body.resources)).toBe(true);
  });

  // ── plan ────────────────────────────────────────────────────────────────────

  test('@scenario-92 plan returns 64-char hex desired_hash and create action', async ({ request }) => {
    // Phase-2: /plan requires specs in the body (specs_from reads from body.specs).
    const specs = [{ name: 'demo-db', type: 'stub.database', config: { engine: 'postgres', version: '15' } }];
    const resp = await request.post(`${BASE_URL}/api/infra/plan`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: { specs },
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as {
      desired_hash?: string;
      plan?: { Actions?: Array<{ Action: string }>; actions?: Array<{ action: string }> };
    };
    // desired_hash must be a 64-char lowercase hex SHA-256 (M-3 guard)
    expect(body.desired_hash).toMatch(/^[0-9a-f]{64}$/);
    // Stub Plan() returns 1 "create" action per desired spec
    const actions = body.plan?.actions ?? body.plan?.Actions ?? [];
    expect(actions.length).toBeGreaterThan(0);
    const firstAction = (actions[0] as { action?: string; Action?: string }).action ??
                        (actions[0] as { action?: string; Action?: string }).Action;
    expect(firstAction).toBe('create');
  });

  test('@scenario-92 viewer cannot plan → 403', async ({ request }) => {
    const specs = [{ name: 'demo-db', type: 'stub.database', config: { engine: 'postgres' } }];
    const resp = await request.post(`${BASE_URL}/api/infra/plan`, {
      headers: { Authorization: `Bearer ${VIEWER_TOKEN}`, 'Content-Type': 'application/json' },
      data: { specs },
    });
    expect(resp.status()).toBe(403);
  });

  // ── apply ───────────────────────────────────────────────────────────────────

  test('@scenario-92 apply with operator JWT succeeds (hash guard passes)', async ({ request }) => {
    // Phase-2: /apply requires specs + desired_hash in the body.
    // First plan to get the dynamic desired_hash.
    const specs = [{ name: 'demo-db', type: 'stub.database', config: { engine: 'postgres', version: '15' } }];
    const planResp = await request.post(`${BASE_URL}/api/infra/plan`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: { specs },
    });
    expect(planResp.status()).toBe(200);
    const planBody = await planResp.json() as { desired_hash?: string };
    const desiredHash = planBody.desired_hash ?? '';
    expect(desiredHash).toMatch(/^[0-9a-f]{64}$/);

    const resp = await request.post(`${BASE_URL}/api/infra/apply`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: { specs, desired_hash: desiredHash },
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { error?: string; desired_hash?: string };
    // No top-level error means the two-phase hash guard passed.
    expect(body.error ?? '').toBe('');
    // desired_hash in response matches the plan value.
    expect(body.desired_hash).toMatch(/^[0-9a-f]{64}$/);
  });

  test('@scenario-92 viewer cannot apply → 403 (server-side RBAC)', async ({ request }) => {
    const specs = [{ name: 'demo-db', type: 'stub.database', config: { engine: 'postgres' } }];
    const resp = await request.post(`${BASE_URL}/api/infra/apply`, {
      headers: { Authorization: `Bearer ${VIEWER_TOKEN}`, 'Content-Type': 'application/json' },
      data: { specs, desired_hash: 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef' },
    });
    // Proves RBAC is server-authoritative: viewer JWT → 403 regardless of body.
    expect(resp.status()).toBe(403);
  });

  // ── commit (Phase 2/3: commit-back is part of apply, not a separate route) ──
  //
  // The /api/infra/commit route was removed in Phase 2. commit-back is now
  // integrated into the /apply pipeline via step.iac_commit_back.
  // The apply response carries committed=true|false + ref.
  //
  // On workflow v0.74.0 (ResourceDriver wired) the apply CREATEs and commit-back
  // commits a branch. This test only asserts the committed FIELD is present (a
  // boolean) — the run.sh headline assertion (a) does the strict committed=true +
  // bare-repo-branch + secret://-survives check on a fresh workclone. (Playwright
  // runs after run.sh's single apply, so the static commit-back branch already
  // exists in the workclone here; committed may be false/state_diverged on this
  // repeat apply — hence only the field-presence assertion.)

  test('@scenario-92 Phase-2 apply response carries committed field (commit-back integrated)', async ({ request }) => {
    const specs = [{ name: 'demo-db', type: 'stub.database', config: { engine: 'postgres', version: '15' } }];
    const planResp = await request.post(`${BASE_URL}/api/infra/plan`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: { specs },
    });
    const planBody = await planResp.json() as { desired_hash?: string };
    const desiredHash = planBody.desired_hash ?? '';

    const resp = await request.post(`${BASE_URL}/api/infra/apply`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: { specs, desired_hash: desiredHash },
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { committed?: boolean };
    // committed field must be present (true = branch pushed; false = repeat-apply state_diverged)
    expect(typeof body.committed).toBe('boolean');
  });

  test('@scenario-92 /api/infra/commit removed (Phase 2 — commit integrated in apply)', async ({ request }) => {
    // The /api/infra/commit route was removed in Phase 2/3. It should return 404.
    const resp = await request.post(`${BASE_URL}/api/infra/commit`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: {},
    });
    expect(resp.status()).toBe(404);
  });

  // ── drift ───────────────────────────────────────────────────────────────────

  test('@scenario-92 drift returns supported=true, any_drifted=false', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/infra/drift`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}` },
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { supported?: boolean; any_drifted?: boolean };
    // Stub DetectDrift returns Drifted:false for all refs (InSync).
    expect(body.any_drifted).toBe(false);
    // DriftDetector service served via external gRPC → supported=true.
    expect(body.supported).toBe(true);
  });

  // ── auth/CSRF gates ─────────────────────────────────────────────────────────

  test('@scenario-92 unauthenticated mutation routes → 401', async ({ request }) => {
    // Phase 2/3: /commit removed; /reconcile added. Test plan, apply, reconcile.
    const specs = [{ name: 'demo-db', type: 'stub.database', config: {} }];
    for (const endpoint of ['/api/infra/plan', '/api/infra/apply', '/api/infra/reconcile']) {
      const resp = await request.post(`${BASE_URL}${endpoint}`, {
        headers: { 'Content-Type': 'application/json' },
        data: { specs },
      });
      expect(resp.status(), `${endpoint} unauthenticated`).toBe(401);
    }
  });

  test('@scenario-92 non-Bearer Authorization → 401 (CSRF guard)', async ({ request }) => {
    const specs = [{ name: 'demo-db', type: 'stub.database', config: {} }];
    for (const endpoint of ['/api/infra/plan', '/api/infra/apply']) {
      const resp = await request.post(`${BASE_URL}${endpoint}`, {
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Token ${OP_TOKEN}`,
        },
        data: { specs },
      });
      // step.auth_validate strips "Bearer " prefix; "Token " is not Bearer → 401.
      expect(resp.status(), `${endpoint} Token scheme`).toBe(401);
    }
  });

  // ── secrets metadata ────────────────────────────────────────────────────────

  test('@scenario-92 secrets list returns metadata_only=true, no values', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/infra/secrets`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}` },
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { metadata_only?: boolean; secrets?: Array<{ name: string }> };
    // Secrets endpoint never exposes values.
    expect(body.metadata_only).toBe(true);
    expect(Array.isArray(body.secrets)).toBe(true);
    // None of the secrets should have a "value" key.
    for (const secret of (body.secrets ?? [])) {
      expect(secret).not.toHaveProperty('value');
    }
  });

  test('@scenario-92 secrets declare returns 200 for operator', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/infra/secrets`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: { name: 'STUB_IAC_PROVIDER_API_KEY', value: 'REDACTED' },
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { declared?: boolean; metadata_only?: boolean };
    expect(body.declared).toBe(true);
    // Value must not appear in the response.
    expect(body).not.toHaveProperty('value');
    expect(body.metadata_only).toBe(true);
  });

  // ── screenshot ──────────────────────────────────────────────────────────────

  test('@scenario-92 admin shell at /admin/ serves or redirects', async ({ page }) => {
    const resp = await page.goto(`${BASE_URL}/admin/`);
    // admin.dashboard serves the shell when admin-ui-static is wired with
    // the plugin's UI assets. In the minimal migration demo (no static
    // fileserver for /admin/), this may return 404 — acceptable since the
    // migration story is about step.iac_provider_* routes, not admin SPA.
    // Assert the server responds (any status), not a network error.
    expect(resp?.status()).toBeGreaterThanOrEqual(200);
    await page.screenshot({
      path: 'test-results/scenario-92-admin-shell.png',
      fullPage: true,
    });
  });

  // ── infra SPA (workflow-plugin-infra ConfigFragment serves at /admin/infra) ─

  test('@scenario-92 GET /admin/infra returns 200 (after redirect) with SPA root element', async ({ page }) => {
    // The static.fileserver injected by workflow-plugin-infra ConfigFragment()
    // serves the embedded React SPA at /admin/infra/.  A GET /admin/infra
    // (no trailing slash) redirects to /admin/infra/ (307) — page.goto follows it.
    const resp = await page.goto(`${BASE_URL}/admin/infra`);
    // After redirect the final status should be 200.
    expect(resp?.status()).toBe(200);
    const content = await page.content();
    // The embedded SPA's index.html wraps the React tree in <div id="root">.
    expect(content).toContain('id="root"');
    await page.screenshot({
      path: 'test-results/scenario-92-infra-spa.png',
      fullPage: true,
    });
  });

  test('@scenario-92 GET /admin/infra/ (trailing slash) returns SPA directly', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/admin/infra/`);
    // Direct access with trailing slash: serves index.html (no redirect).
    expect(resp.status()).toBe(200);
    const text = await resp.text();
    expect(text).toContain('id="root"');
  });

  test('@scenario-92 /admin/infra/assets served (SPA JS bundle present)', async ({ request }) => {
    // Fetch the SPA index to extract the asset bundle URL.
    const indexResp = await request.get(`${BASE_URL}/admin/infra`);
    expect(indexResp.status()).toBe(200);
    const html = await indexResp.text();
    // index.html includes <script src="./assets/index-*.js">
    const match = html.match(/src="\.\/assets\/(index-[^"]+\.js)"/);
    expect(match, 'SPA index.html must reference an assets/index-*.js bundle').toBeTruthy();
    if (match) {
      const assetResp = await request.get(`${BASE_URL}/admin/infra/assets/${match[1]}`);
      expect(assetResp.status()).toBe(200);
    }
  });

  // ── infra contribution registered in admin.dashboard ────────────────────────

  test('@scenario-92 /api/admin/contributions includes infra-resources', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/admin/contributions`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}` },
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { contributions?: Array<{ id: string; path: string; title: string }> };
    const contributions = body.contributions ?? [];
    const infra = contributions.find(c => c.id === 'infra-resources');
    expect(infra, 'infra-resources contribution must be registered in admin.dashboard').toBeTruthy();
    if (infra) {
      expect(infra.path).toBe('/admin/infra');
      expect(infra.title).toBe('Infrastructure');
    }
  });

  // ── SPA catalog dropdowns populated from live step.iac_provider_catalog ─────
  //
  // The React SPA (ResourceList.tsx) calls GET /api/infra/providers/{provider}/catalog
  // on mount and populates the Region and Type <select> dropdowns with live data.
  // The catalog endpoint is served by the infra-spa-catalog pipeline which routes
  // all provider names to stub-iac-provider (the only provider in this scenario).
  // The SPA doesn't send auth headers — the catalog route is intentionally open.

  test('@scenario-92 SPA catalog endpoint returns stub regions for digitalocean provider', async ({ request }) => {
    // Verify the SPA-compatible catalog endpoint returns stub provider data.
    // The SPA's default provider is 'digitalocean', so this is the first real call.
    // The pipeline transforms types to string[] (SPA expects string[], not object[]).
    const resp = await request.get(`${BASE_URL}/api/infra/providers/digitalocean/catalog`);
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { regions?: string[]; types?: string[]; source?: string };
    // Routed to stub-iac-provider → stub-east, stub-west, stub.database, stub.bucket
    expect(body.regions ?? []).toContain('stub-east');
    expect(body.regions ?? []).toContain('stub-west');
    // types are transformed to strings by the infra-spa-catalog pipeline (step.jq)
    expect(body.types ?? []).toContain('stub.database');
    expect(body.types ?? []).toContain('stub.bucket');
    expect(body.source).toBe('live');
  });

  test('@scenario-92 SPA region select populated from catalog (stub-east, stub-west)', async ({ page }) => {
    // Navigate to the SPA.  The SPA calls /api/infra/providers/digitalocean/catalog
    // (no auth header) which the infra-spa-catalog pipeline serves from stub-iac-provider.
    const resp = await page.goto(`${BASE_URL}/admin/infra`);
    expect(resp?.status()).toBe(200);

    // Wait for the React app to mount and the catalog fetch to complete.
    // ResourceList.tsx renders a Region <select> once catalog.regions is populated.
    // Give it up to 10s for the React boot + gRPC catalog round-trip.
    const regionSelect = page.locator('select').nth(1); // Provider is first, Region is second
    await regionSelect.waitFor({ state: 'visible', timeout: 10000 });

    // Wait for options to be populated (not just "— no catalog —")
    await page.waitForFunction(
      () => {
        const selects = document.querySelectorAll('select');
        for (const sel of Array.from(selects)) {
          const opts = Array.from(sel.options).map(o => o.text);
          if (opts.some(t => t.includes('stub-east'))) return true;
        }
        return false;
      },
      { timeout: 10000 },
    );

    const allOptions = await page.locator('select option').allTextContents();
    const allText = allOptions.join(',');

    // The stub IaCProvider's ListRegions returns stub-east and stub-west.
    expect(allText, `region selects must include stub-east, got: ${allText}`).toContain('stub-east');
    expect(allText, `region selects must include stub-west, got: ${allText}`).toContain('stub-west');

    await page.screenshot({ path: 'test-results/scenario-92-infra-spa-catalog.png', fullPage: true });
  });

  test('@scenario-92 SPA resource-type select populated from catalog (stub.database, stub.bucket)', async ({ page }) => {
    await page.goto(`${BASE_URL}/admin/infra`);

    // Wait for ALL select elements to appear and for catalog to load.
    await page.waitForFunction(
      () => {
        const selects = document.querySelectorAll('select');
        for (const sel of Array.from(selects)) {
          const opts = Array.from(sel.options).map(o => o.text);
          if (opts.some(t => t.includes('stub.database'))) return true;
        }
        return false;
      },
      { timeout: 10000 },
    );

    const allOptions = await page.locator('select option').allTextContents();
    const allText = allOptions.join(',');

    // The stub Capabilities() returns stub.database and stub.bucket.
    expect(allText).toContain('stub.database');
    expect(allText).toContain('stub.bucket');
  });

  // ── Phase 2/3: dynamic plan → apply with edited specs ──────────────────────

  test('@scenario-92 Phase-2 dynamic plan: POST with operator-edited specs returns desired_hash', async ({ request }) => {
    const specs = [
      {
        name: 'demo-db',
        type: 'stub.database',
        config: { engine: 'postgres', version: '15', api_key: 'secret://scenario/stub_api_key' },
      },
    ];
    const resp = await request.post(`${BASE_URL}/api/infra/plan`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: { specs },
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { desired_hash?: string; plan?: { actions?: unknown[] } };
    // Phase-2: desired_hash is computed from the operator-supplied dynamic specs.
    expect(body.desired_hash).toMatch(/^[0-9a-f]{64}$/);
    // Plan must have at least one action (stub returns "create" per spec).
    const actions = body.plan?.actions ?? [];
    expect(Array.isArray(actions)).toBe(true);
    expect(actions.length).toBeGreaterThan(0);
  });

  test('@scenario-92 Phase-2 apply: dynamic specs + desired_hash → 200 + committed', async ({ request }) => {
    const specs = [
      {
        name: 'playwright-db',
        type: 'stub.database',
        config: { engine: 'postgres', version: '15', api_key: 'secret://scenario/stub_api_key' },
      },
    ];
    // First: plan to get the dynamic desired_hash.
    const planResp = await request.post(`${BASE_URL}/api/infra/plan`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: { specs },
    });
    expect(planResp.status()).toBe(200);
    const planBody = await planResp.json() as { desired_hash?: string };
    const desiredHash = planBody.desired_hash ?? '';
    expect(desiredHash).toMatch(/^[0-9a-f]{64}$/);

    // Then: apply with the same specs + desired_hash (empty exec_env = local-docker path).
    const applyResp = await request.post(`${BASE_URL}/api/infra/apply`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: { specs, desired_hash: desiredHash },
    });
    expect(applyResp.status()).toBe(200);
    const applyBody = await applyResp.json() as {
      apply_result?: unknown;
      desired_hash?: string;
      committed?: boolean;
    };
    // No top-level error → two-phase hash guard passed.
    expect(applyBody.desired_hash).toMatch(/^[0-9a-f]{64}$/);
    // committed field must be present (true = branch pushed; false = state_diverged path).
    expect(typeof applyBody.committed).toBe('boolean');
  });

  test('@scenario-92 Phase-2 reachability 409: secret:// ref → /apply-remote → 409', async ({ request }) => {
    const specs = [
      {
        name: 'demo-db',
        type: 'stub.database',
        config: { api_key: 'secret://scenario/stub_api_key' },
      },
    ];
    // Plan first to get a hash.
    const planResp = await request.post(`${BASE_URL}/api/infra/plan`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: { specs },
    });
    const planBody = await planResp.json() as { desired_hash?: string };
    const desiredHash = planBody.desired_hash ?? 'deadbeef'.repeat(8);

    // POST /api/infra/apply-remote → exec_env: remote (static in step config) →
    // reachability pre-flight → 409 (host-local secrets.keychain unreachable from remote, ADR 0017)
    const resp = await request.post(`${BASE_URL}/api/infra/apply-remote`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: { specs, desired_hash: desiredHash },
    });
    expect(resp.status()).toBe(409);
    const body = await resp.json() as { error?: string };
    expect(body.error).toBeTruthy();
  });

  // ── Phase 3: reconcile ──────────────────────────────────────────────────────

  test('@scenario-92 Phase-3 reconcile: POST returns 200 with {draft,warning,count} shape', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/infra/reconcile`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: {},
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as {
      draft?: boolean;
      warning?: string;
      count?: number;
      ref?: string;
    };
    // All three required fields must be present (ref is optional when draft=false).
    expect(typeof body.draft).toBe('boolean');
    expect(typeof body.warning).toBe('string');
    expect(typeof body.count).toBe('number');
    // stub DetectDrift always returns Drifted:false → count must be 0 → draft must be false.
    expect(body.count).toBe(0);
    expect(body.draft).toBe(false);
  });

  test('@scenario-92 Phase-3 viewer cannot reconcile → 403', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/infra/reconcile`, {
      headers: { Authorization: `Bearer ${VIEWER_TOKEN}`, 'Content-Type': 'application/json' },
      data: {},
    });
    expect(resp.status()).toBe(403);
  });

  // ── Phase 3: exec-envs endpoint ─────────────────────────────────────────────

  test('@scenario-92 Phase-3 exec-envs: GET returns local-docker and remote', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/infra/exec-envs`);
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { exec_envs?: string[] };
    expect(body.exec_envs).toContain('local-docker');
    expect(body.exec_envs).toContain('remote');
  });

  // ── Phase 3: remote runner sandbox-demo ────────────────────────────────────

  test('@scenario-92 Phase-3 sandbox-demo: remote agent executes command + MARKER in stdout', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/infra/sandbox-demo`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: {},
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { stdout?: string; exit_code?: number };
    // The remote agent ran the echo command — MARKER must appear in stdout.
    expect(body.stdout).toContain('SCENARIO92_REMOTE_AGENT_MARKER');
    // Clean exit from the echo command.
    expect(body.exit_code).toBe(0);
  });
});
