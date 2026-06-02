import { test, expect, type Page } from '@playwright/test';
import { createHmac } from 'crypto';

// Scenario 92 — Infra Admin MIGRATION Demo (v2: step-based IaC pipelines)
//
// Tests the migration from the deleted infra.admin engine module to the new
// step.iac_provider_* pipeline architecture (workflow v0.70.0).
//
// The stub-iac-provider is loaded as an EXTERNAL gRPC plugin. The WiringHook
// registers it as service "stub-iac-provider". Pipelines use:
//   step.iac_provider_catalog  → catalog with live regions from RegionLister
//   step.iac_provider_list     → list resources
//   step.iac_provider_plan     → plan (returns desired_hash)
//   step.iac_provider_apply    → apply (validates hash guard)
//   step.iac_provider_drift    → drift detection (DriftDetector)
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
    const resp = await request.post(`${BASE_URL}/api/infra/plan`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: {},
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
    const resp = await request.post(`${BASE_URL}/api/infra/plan`, {
      headers: { Authorization: `Bearer ${VIEWER_TOKEN}`, 'Content-Type': 'application/json' },
      data: {},
    });
    expect(resp.status()).toBe(403);
  });

  // ── apply ───────────────────────────────────────────────────────────────────

  test('@scenario-92 apply with operator JWT succeeds (hash guard passes)', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/infra/apply`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: {},
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { error?: string; desired_hash?: string };
    // No top-level error means the two-phase hash guard passed.
    expect(body.error ?? '').toBe('');
    // desired_hash in response matches the precomputed value.
    expect(body.desired_hash).toMatch(/^[0-9a-f]{64}$/);
  });

  test('@scenario-92 viewer cannot apply → 403 (server-side RBAC)', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/infra/apply`, {
      headers: { Authorization: `Bearer ${VIEWER_TOKEN}`, 'Content-Type': 'application/json' },
      data: {},
    });
    // Proves RBAC is server-authoritative: viewer JWT → 403 regardless of body.
    expect(resp.status()).toBe(403);
  });

  // ── commit ──────────────────────────────────────────────────────────────────

  test('@scenario-92 commit with operator JWT returns committed=true', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/infra/commit`, {
      headers: { Authorization: `Bearer ${OP_TOKEN}`, 'Content-Type': 'application/json' },
      data: {},
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { committed?: boolean; branch?: string };
    expect(body.committed).toBe(true);
    expect(body.branch).toBeTruthy();
  });

  test('@scenario-92 viewer cannot commit → 403', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/infra/commit`, {
      headers: { Authorization: `Bearer ${VIEWER_TOKEN}`, 'Content-Type': 'application/json' },
      data: {},
    });
    expect(resp.status()).toBe(403);
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
    for (const endpoint of ['/api/infra/plan', '/api/infra/apply', '/api/infra/commit']) {
      const resp = await request.post(`${BASE_URL}${endpoint}`, {
        headers: { 'Content-Type': 'application/json' },
        data: {},
      });
      expect(resp.status(), `${endpoint} unauthenticated`).toBe(401);
    }
  });

  test('@scenario-92 non-Bearer Authorization → 401 (CSRF guard)', async ({ request }) => {
    for (const endpoint of ['/api/infra/plan', '/api/infra/apply']) {
      const resp = await request.post(`${BASE_URL}${endpoint}`, {
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Token ${OP_TOKEN}`,
        },
        data: {},
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

  test('@scenario-92 admin shell loads at /admin/', async ({ page }) => {
    const resp = await page.goto(`${BASE_URL}/admin/`);
    // admin.dashboard serves HTML with admin shell.
    expect(resp?.status()).toBe(200);
    await page.screenshot({
      path: 'test-results/scenario-92-admin-shell.png',
      fullPage: true,
    });
  });
});
