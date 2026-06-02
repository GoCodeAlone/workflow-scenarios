import { test, expect, chromium, type BrowserContext } from '@playwright/test';

// Scenario 101 — Auth Admin Bootstrap
//
// Exercises the full passkey ceremony end-to-end using a CDP virtual
// authenticator (ctap2/internal, resident keys, user-verified).
//
// The stack MUST be running at SCENARIO_URL (default http://localhost:18101).
// rp_id is "localhost", so we navigate to localhost, NOT 127.0.0.1.
//
// Prerequisites: fresh DB (TRUNCATE credentials, users CASCADE).
// To reset: docker compose exec -T postgres psql -U scenario101 -d scenario101 \
//   -c "TRUNCATE credentials, users CASCADE;"

const BASE_URL = process.env.SCENARIO_URL || 'http://localhost:18101';
const BOOTSTRAP_CODE = 'scenario-101-bootstrap-code-do-not-use-in-prod';
const ADMIN_EMAIL = 'admin@scenario-101.test';

// ---------------------------------------------------------------------------
// CDP virtual-authenticator helpers
// ---------------------------------------------------------------------------

async function enableVirtualAuth(context: BrowserContext): Promise<string> {
  // Playwright 1.x: open a CDP session on the first page of the context.
  // WebAuthn.enable + addVirtualAuthenticator returns an authenticatorId.
  const page = context.pages()[0] ?? (await context.newPage());
  const cdp = await context.newCDPSession(page);

  await cdp.send('WebAuthn.enable', { enableUI: false });

  const { authenticatorId } = await cdp.send('WebAuthn.addVirtualAuthenticator', {
    options: {
      protocol: 'ctap2',
      transport: 'internal',
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
    },
  });

  return authenticatorId;
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

// @scenario-101
test.describe('Scenario 101: Auth Admin Bootstrap (passkey ceremony)', () => {
  // Use a fresh browser context per suite so sessionStorage is clean.
  // We must use chromium.launch (not the fixture `browser`) so we can
  // launch with `--enable-experimental-web-platform-features` which is
  // required for WebAuthn in headless Chromium on some builds.
  let context: BrowserContext;

  test.beforeAll(async () => {
    const browser = await chromium.launch({
      headless: true,
      args: [
        '--enable-experimental-web-platform-features',
        '--disable-web-security',
      ],
    });
    context = await browser.newContext({
      ignoreHTTPSErrors: true,
    });
  });

  test.afterAll(async () => {
    await context.close();
  });

  // -------------------------------------------------------------------------
  // T1: healthz
  // -------------------------------------------------------------------------
  test('@scenario-101 GET /healthz returns 200', async () => {
    const page = await context.newPage();
    const resp = await page.goto(`${BASE_URL}/healthz`);
    expect(resp?.status()).toBe(200);
    await page.close();
  });

  // -------------------------------------------------------------------------
  // T2: bootstrap status shows OPEN badge
  // -------------------------------------------------------------------------
  test('@scenario-101 UI shows bootstrap-open badge and form on fresh DB', async () => {
    const page = await context.newPage();
    await page.goto(BASE_URL);

    // Wait for init() to finish the status fetch.
    await expect(page.locator('#status-badge')).toHaveText('OPEN', { timeout: 5000 });
    await expect(page.locator('#panel-bootstrap')).toBeVisible();
    await expect(page.locator('#panel-authed')).not.toBeVisible();
    await expect(page.locator('#panel-signin')).not.toBeVisible();
    await page.close();
  });

  // -------------------------------------------------------------------------
  // T3: wrong code → error message stays on bootstrap panel
  // -------------------------------------------------------------------------
  test('@scenario-101 wrong bootstrap code shows error', async () => {
    const page = await context.newPage();
    await page.goto(BASE_URL);
    await expect(page.locator('#panel-bootstrap')).toBeVisible();

    await page.fill('#code', 'wrong-code');
    await page.click('#btn-redeem');

    await expect(page.locator('#msg-redeem')).toContainText(/invalid_code|Redeem failed/, {
      timeout: 5000,
    });
    await expect(page.locator('#panel-bootstrap')).toBeVisible();
    await page.close();
  });

  // -------------------------------------------------------------------------
  // T4–T7: full passkey ceremony (virtual authenticator)
  // -------------------------------------------------------------------------
  test('@scenario-101 full passkey ceremony: bootstrap → enrol → reload → login', async () => {
    const page = await context.newPage();

    // Enable virtual authenticator BEFORE navigating (so it intercepts
    // the navigator.credentials calls).
    const cdp = await context.newCDPSession(page);
    await cdp.send('WebAuthn.enable', { enableUI: false });
    await cdp.send('WebAuthn.addVirtualAuthenticator', {
      options: {
        protocol: 'ctap2',
        transport: 'internal',
        hasResidentKey: true,
        hasUserVerification: true,
        isUserVerified: true,
        automaticPresenceSimulation: true,
      },
    });

    // --- Step 1: Navigate and redeem bootstrap code -------------------------
    await page.goto(BASE_URL);
    await expect(page.locator('#panel-bootstrap')).toBeVisible({ timeout: 5000 });

    await page.fill('#code', BOOTSTRAP_CODE);
    await page.click('#btn-redeem');

    // After successful redeem, the authenticated panel must appear.
    await expect(page.locator('#panel-authed')).toBeVisible({ timeout: 5000 });
    await expect(page.locator('#authed-email')).toHaveText(ADMIN_EMAIL);

    // Token must be stored in sessionStorage.
    const token = await page.evaluate(() => sessionStorage.getItem('s101_token'));
    expect(token).toBeTruthy();

    // --- Step 2: Enrol passkey ---------------------------------------------
    await page.click('#btn-enrol');

    // The virtual authenticator auto-attests, so we should get a success msg.
    await expect(page.locator('#msg-enrol')).toContainText('Passkey enrolled', {
      timeout: 10000,
    });

    // --- Step 3: Reload — bootstrap must now be CLOSED ---------------------
    await page.reload();
    await expect(page.locator('#status-badge')).toHaveText('CLOSED', { timeout: 5000 });
    // Still authenticated via sessionStorage — authed panel shows.
    await expect(page.locator('#panel-authed')).toBeVisible();

    // --- Step 4: Logout ----------------------------------------------------
    await page.click('#btn-logout');
    // After logout, reload happens; now not authenticated + bootstrap closed
    // → sign-in panel.
    await expect(page.locator('#panel-signin')).toBeVisible({ timeout: 5000 });
    await expect(page.locator('#status-badge')).toHaveText('CLOSED');

    // --- Step 5: Sign in with passkey --------------------------------------
    await page.fill('#signin-email', ADMIN_EMAIL);
    await page.click('#btn-signin');

    // The virtual authenticator auto-asserts — authenticated panel should appear.
    await expect(page.locator('#panel-authed')).toBeVisible({ timeout: 10000 });
    await expect(page.locator('#authed-email')).toHaveText(ADMIN_EMAIL);

    await page.screenshot({
      path: 'test-results/scenario-101-passkey-authenticated.png',
      fullPage: true,
    });

    await page.close();
  });

  // -------------------------------------------------------------------------
  // T8: /admin/bootstrap/status returns { open: false } after ceremony
  // -------------------------------------------------------------------------
  test('@scenario-101 bootstrap/status is closed after enrolment', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/admin/bootstrap/status`);
    expect(resp.status()).toBe(200);
    const body = await resp.json() as { open: boolean };
    expect(body.open).toBe(false);
  });

  // -------------------------------------------------------------------------
  // T9: passkey register/begin returns 401 without token (gate intact)
  // -------------------------------------------------------------------------
  test('@scenario-101 passkey register/begin is auth-gated (401 without token)', async ({
    request,
  }) => {
    const resp = await request.post(`${BASE_URL}/admin/credentials/passkey/register/begin`);
    expect(resp.status()).toBe(401);
  });

  // -------------------------------------------------------------------------
  // T10: screenshot of bootstrap panel (open state) — requires fresh context
  // -------------------------------------------------------------------------
  test('@scenario-101 full-page screenshot of sign-in panel', async () => {
    const page = await context.newPage();
    // sessionStorage from previous tests still has token — go fresh page
    await page.goto(BASE_URL);
    // Either authed or signin panel is visible, take a screenshot regardless.
    await page.screenshot({
      path: 'test-results/scenario-101-final-state.png',
      fullPage: true,
    });
    await page.close();
  });
});
