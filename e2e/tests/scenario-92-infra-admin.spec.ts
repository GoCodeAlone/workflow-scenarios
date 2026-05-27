import { test, expect, type Page } from '@playwright/test';
import { createHmac } from 'crypto';

// Scenario 92 — Infra Admin (Dynamic, Proto-Driven)
//
// Exercises the host-side infra.admin module + form-builder UI end-to-end
// against the docker-compose stack from seed/seed.sh. Test ordering
// matches the plan §Task 24 spec block.
//
// SCENARIO_URL points at the running stack (default http://127.0.0.1:18092
// for scenario 92's port mapping). Override via env var.
//
// Auth: every /api/infra-admin/* and /admin/infra-admin/* request must
// carry a Bearer JWT signed by the scenario's HS256 secret, since
// PR-1 47341ff6f (T15 auth fix) added a route-level auth middleware.
// The token is minted once in beforeAll and threaded through fetch
// headers + page.setExtraHTTPHeaders for browser navigations.

const BASE_URL = process.env.SCENARIO_URL || 'http://127.0.0.1:18092';

// Must match config/app.yaml::modules[name=auth].config.hs256_secret.
const JWT_SECRET = 'scenario-92-jwt-secret-do-not-use-in-prod';
const JWT_ISSUER = 'scenario-92';

function base64Url(buf: Buffer | string): string {
  const b = Buffer.isBuffer(buf) ? buf : Buffer.from(buf);
  return b
    .toString('base64')
    .replace(/=+$/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
}

// mintHS256JWT issues a self-signed JWT matching auth.jwt's HS256
// verification path. Long expiry so a slow Playwright run never
// rolls past it; sub identifies the e2e suite for any audit-log
// breadcrumb that surfaces.
function mintHS256JWT(): string {
  const header = base64Url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const now = Math.floor(Date.now() / 1000);
  const payload = base64Url(
    JSON.stringify({
      iss: JWT_ISSUER,
      sub: 'playwright-scenario-92',
      iat: now,
      exp: now + 3600,
    }),
  );
  const unsigned = `${header}.${payload}`;
  const signature = base64Url(
    createHmac('sha256', JWT_SECRET).update(unsigned).digest(),
  );
  return `${unsigned}.${signature}`;
}

const BEARER_TOKEN = mintHS256JWT();
const AUTH_HEADER = { Authorization: `Bearer ${BEARER_TOKEN}` };

async function adminFetch(page: Page, path: string, body: unknown) {
  return page.evaluate(
    async ([url, payload, auth]) => {
      const resp = await fetch(url as string, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: auth as string,
        },
        body: JSON.stringify(payload),
      });
      let parsed: unknown = null;
      try {
        parsed = await resp.json();
      } catch (_) {
        /* not JSON — leave parsed null */
      }
      return { status: resp.status, body: parsed };
    },
    [path, body, AUTH_HEADER.Authorization] as const,
  );
}

const EVIDENCE = { authz_checked: true, authz_allowed: true };

// @scenario-92
test.describe('Scenario 92: Infra Admin (Dynamic, Proto-Driven)', () => {
  // Authenticate every browser navigation. /healthz is public (no
  // auth middleware) so it's safe even when the header is sent; the
  // /admin/infra-admin/* asset pages and /api/infra-admin/* RPCs
  // require it per PR-1 T15 auth gate (47341ff6f).
  test.beforeEach(async ({ page }) => {
    await page.setExtraHTTPHeaders({ Authorization: `Bearer ${BEARER_TOKEN}` });
  });

  test('@scenario-92 healthz OK', async ({ page }) => {
    const resp = await page.goto(`${BASE_URL}/healthz`);
    expect(resp?.status()).toBe(200);
  });

  test('@scenario-92 unauthenticated /api/infra-admin/* returns 401', async ({
    page,
  }) => {
    // PR-1 T15 auth-middleware regression gate. Without an
    // Authorization header, the auth gate MUST return 401 BEFORE
    // any handler runs — clients can't spoof the in-body evidence
    // {authz_checked:true, authz_allowed:true} to bypass the
    // application-level default-deny. Mirrors implementer-1's unit
    // test TestInfraAdmin_ClientCannotSpoofAuthzEvidence at the e2e
    // tier per spec-reviewer F2 (PR-2) + team-lead's option 2.
    const { status, body } = await page.evaluate(async url => {
      const resp = await fetch(`${url}/api/infra-admin/resources`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          evidence: { authz_checked: true, authz_allowed: true },
        }),
      });
      let parsed: unknown = null;
      try {
        parsed = await resp.json();
      } catch (_) {
        /* not JSON — leave null */
      }
      return { status: resp.status, body: parsed };
    }, BASE_URL);
    expect(status).toBe(401);
    // 401 is enforced by the auth middleware BEFORE the handler runs,
    // so the body should NOT contain a handler-shaped
    // `AdminListResourcesOutput` with a tag-100 error. Just assert no
    // 200-shaped resources field — the 401 status is the load-bearing
    // assertion here.
    if (body && typeof body === 'object') {
      expect((body as Record<string, unknown>).resources).toBeUndefined();
    }
  });

  test('@scenario-92 infra contributions auto-registered', async ({ page }) => {
    await page.goto(BASE_URL);
    // /api/admin/contributions is gated by admin.dashboard's
    // auth_module (matches infra.admin's gate); include the Bearer
    // token explicitly since this fetch doesn't go through the
    // setExtraHTTPHeaders-covered navigation path.
    const data = await page.evaluate(
      async ([url, auth]) => {
        const resp = await fetch(`${url}/api/admin/contributions`, {
          headers: { Authorization: auth as string },
        });
        return resp.json();
      },
      [BASE_URL, AUTH_HEADER.Authorization] as const,
    );
    const contributions = (data?.contributions ?? []) as Array<{ id: string }>;
    const ids = contributions.map(c => c.id);
    expect(ids).toEqual(
      expect.arrayContaining(['infra.resources', 'infra.resource-detail', 'infra.new']),
    );
  });

  test('@scenario-92 ListProviders returns at least the stub provider', async ({ page }) => {
    await page.goto(BASE_URL);
    const { status, body } = await adminFetch(page, `${BASE_URL}/api/infra-admin/providers`, {
      evidence: EVIDENCE,
    });
    expect(status).toBe(200);
    expect(body.providers?.length ?? 0).toBeGreaterThan(0);
    const types = body.providers.map((p: { provider_type: string }) => p.provider_type);
    expect(types).toContain('stub');
  });

  test('@scenario-92 ListResourceTypes returns all 13 typed Configs', async ({ page }) => {
    await page.goto(BASE_URL);
    const { status, body } = await adminFetch(page, `${BASE_URL}/api/infra-admin/types`, {
      evidence: EVIDENCE,
    });
    expect(status).toBe(200);
    const typeNames = (body.types ?? []).map((t: { type: string }) => t.type);
    expect(typeNames).toEqual(
      expect.arrayContaining([
        'infra.vpc',
        'infra.database',
        'infra.container_service',
        'infra.k8s_cluster',
        'infra.cache',
        'infra.load_balancer',
        'infra.dns',
        'infra.registry',
        'infra.api_gateway',
        'infra.firewall',
        'infra.iam_role',
        'infra.storage',
        'infra.certificate',
      ]),
    );
  });

  test('@scenario-92 authenticated request without evidence still default-denies', async ({
    page,
  }) => {
    // Two-tier security check exercised together: auth gate passes
    // (Bearer header set in adminFetch), but handler-library default-
    // deny rejects because the body omits the AdminAuthzEvidence
    // payload. Result is 200 with tag-100 error string (per design's
    // "errors surface via Output.error not Go-level errors" contract).
    // Spec-reviewer PR-2 review item #4.
    await page.goto(BASE_URL);
    const { status, body } = await adminFetch(page, `${BASE_URL}/api/infra-admin/resources`, {});
    expect(status).toBe(200);
    expect((body as { error?: string }).error).toBeTruthy();
  });

  test('@scenario-92 resources.html serves and references resources.js', async ({ page }) => {
    const resp = await page.goto(`${BASE_URL}/admin/infra-admin/resources.html`);
    expect(resp?.status()).toBe(200);
    const html = await page.content();
    expect(html).toContain('Infra Resources');
    expect(html).toMatch(/<script[^>]*src="\/admin\/infra-admin\/resources\.js"/);
  });

  test('@scenario-92 new.html form-builder loads and populates type dropdown', async ({ page }) => {
    await page.goto(`${BASE_URL}/admin/infra-admin/new.html`);
    // Wait for the loadCatalog fetch to populate the select.
    await expect(page.locator('#type')).toBeVisible();
    await page.waitForFunction(
      () => {
        const sel = document.getElementById('type') as HTMLSelectElement | null;
        return sel != null && sel.options.length > 1;
      },
      undefined,
      { timeout: 5000 },
    );
    const typeCount = await page.locator('#type option').count();
    expect(typeCount).toBeGreaterThan(1); // "— select —" + at least one type
  });

  test('@scenario-92 new-resource form: provider dropdown populates after type select', async ({
    page,
  }) => {
    await page.goto(`${BASE_URL}/admin/infra-admin/new.html`);
    await page.waitForFunction(() => {
      const sel = document.getElementById('type') as HTMLSelectElement | null;
      return sel != null && sel.options.length > 1;
    });
    await page.selectOption('#type', 'infra.vpc');
    // After type select, the provider field should render.
    const providerSelect = page.locator('select[name="provider"]');
    await expect(providerSelect).toBeVisible();
    const optCount = await providerSelect.locator('option').count();
    expect(optCount).toBeGreaterThan(1);
  });

  test('@scenario-92 new-resource form: region depends_on provider', async ({ page }) => {
    await page.goto(`${BASE_URL}/admin/infra-admin/new.html`);
    await page.waitForFunction(() => {
      const sel = document.getElementById('type') as HTMLSelectElement | null;
      return sel != null && sel.options.length > 1;
    });
    await page.selectOption('#type', 'infra.vpc');
    await expect(page.locator('select[name="provider"]')).toBeVisible();
    // Pick the first non-placeholder provider option.
    const firstProvider = await page
      .locator('select[name="provider"] option:not([value=""])')
      .first()
      .getAttribute('value');
    expect(firstProvider).toBeTruthy();
    await page.selectOption('select[name="provider"]', firstProvider!);
    // After provider chosen, region dropdown should populate.
    const regionSelect = page.locator('select[name="region"]');
    await expect(regionSelect).toBeVisible();
    await page.waitForFunction(() => {
      const sel = document.querySelector(
        'select[name="region"]',
      ) as HTMLSelectElement | null;
      return sel != null && sel.options.length > 1;
    });
    const regionCount = await regionSelect.locator('option').count();
    expect(regionCount).toBeGreaterThan(1);
  });

  test('@scenario-92 generate-config returns YAML snippet', async ({ page }) => {
    await page.goto(`${BASE_URL}/admin/infra-admin/new.html`);
    await page.waitForFunction(() => {
      const sel = document.getElementById('type') as HTMLSelectElement | null;
      return sel != null && sel.options.length > 1;
    });
    await page.selectOption('#type', 'infra.vpc');
    await page.fill('#name', 'demo-vpc');

    // Pick first available provider + region.
    const provVal = await page
      .locator('select[name="provider"] option:not([value=""])')
      .first()
      .getAttribute('value');
    await page.selectOption('select[name="provider"]', provVal!);
    await page.waitForFunction(() => {
      const sel = document.querySelector(
        'select[name="region"]',
      ) as HTMLSelectElement | null;
      return sel != null && sel.options.length > 1;
    });
    const regionVal = await page
      .locator('select[name="region"] option:not([value=""])')
      .first()
      .getAttribute('value');
    await page.selectOption('select[name="region"]', regionVal!);

    // VPC needs cidr.
    await page.fill('input[name="cidr"]', '10.0.0.0/16');

    await page.click('#submit');
    await expect(page.locator('#yaml-output')).toContainText('infra.vpc');
    await expect(page.locator('#yaml-output')).toContainText('demo-vpc');
  });

  test('@scenario-92 CSP enforces no inline scripts on asset pages', async ({ page }) => {
    // Asset pages MUST NOT contain inline `<script>` tags with content
    // (only external `src` references). This guards against the
    // design-cycle-5 CSP regression class.
    for (const path of ['resources.html', 'resource.html', 'new.html']) {
      await page.goto(`${BASE_URL}/admin/infra-admin/${path}`);
      const inlineScriptCount = await page.evaluate(() => {
        return Array.from(document.querySelectorAll('script'))
          .filter(s => !s.src && s.textContent && s.textContent.trim().length > 0)
          .length;
      });
      expect(inlineScriptCount, `${path} has inline scripts`).toBe(0);
    }
  });

  test('@scenario-92 full-page screenshot', async ({ page }) => {
    await page.goto(`${BASE_URL}/admin/infra-admin/new.html`);
    await page.waitForFunction(() => {
      const sel = document.getElementById('type') as HTMLSelectElement | null;
      return sel != null && sel.options.length > 1;
    });
    await page.screenshot({
      path: 'test-results/scenario-92-new-form.png',
      fullPage: true,
    });
  });
});
