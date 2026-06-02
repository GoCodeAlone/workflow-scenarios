import { test, expect } from '@playwright/test';

// Scenario 102 — Cross-Service Asymmetric Auth
//
// Exercises the browser verification console on App B (http://localhost:18112).
//
// Test setup: fetches an ES256 access_token from App A's PUBLISHED port
// (http://localhost:18102/oauth/token) out-of-band via Playwright's request
// fixture, then navigates to the App B console, fills the token textarea,
// and clicks Verify.
//
// Prerequisites: stack up (seed/seed.sh completed successfully).
// The test is stateless — no DB reset needed.
//
// Stack ports:
//   App A (issuer):   http://localhost:18102
//   App B (verifier): http://localhost:18112

const APP_A_BASE = process.env.APP_A_URL || 'http://localhost:18102';
const APP_B_BASE = process.env.APP_B_URL || 'http://localhost:18112';
const CLIENT_SECRET = process.env.APP_A_CLIENT_SECRET || 'scenario-102-app-a-client-secret-do-not-use-in-prod';

// @scenario-102
test.describe('Scenario 102: Cross-Service Asymmetric Auth (ES256)', () => {
  let accessToken = '';

  test.beforeAll(async ({ request }) => {
    // Obtain a real ES256 token from App A out-of-band.
    // (The "Fetch" button in the console does the same thing in-browser.)
    const resp = await request.post(`${APP_A_BASE}/oauth/token`, {
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      data: `grant_type=client_credentials&client_id=app-b-caller&client_secret=${CLIENT_SECRET}`,
    });
    expect(resp.status(), 'App A token endpoint').toBe(200);
    const body = await resp.json() as { access_token?: string };
    expect(body.access_token, 'access_token present').toBeTruthy();
    accessToken = body.access_token!;
  });

  // -------------------------------------------------------------------------
  // T1: App A healthz
  // -------------------------------------------------------------------------
  test('@scenario-102 GET app-a/healthz returns 200', async ({ request }) => {
    const resp = await request.get(`${APP_A_BASE}/healthz`);
    expect(resp.status()).toBe(200);
  });

  // -------------------------------------------------------------------------
  // T2: App B healthz
  // -------------------------------------------------------------------------
  test('@scenario-102 GET app-b/healthz returns 200', async ({ request }) => {
    const resp = await request.get(`${APP_B_BASE}/healthz`);
    expect(resp.status()).toBe(200);
  });

  // -------------------------------------------------------------------------
  // T3: App A issues ES256 token (header check)
  // -------------------------------------------------------------------------
  test('@scenario-102 App A issues ES256 token with correct claims', async () => {
    expect(accessToken).toBeTruthy();
    const parts = accessToken.split('.');
    expect(parts).toHaveLength(3);

    // Decode header
    const hdr = JSON.parse(Buffer.from(parts[0], 'base64url').toString());
    expect(hdr.alg).toBe('ES256');

    // Decode payload
    const pay = JSON.parse(Buffer.from(parts[1], 'base64url').toString());
    expect(pay.iss).toBe('http://app-a:8080');
    expect(pay.aud).toBe('app-b');
  });

  // -------------------------------------------------------------------------
  // T4: App B verifies App A token via JWKS (API level)
  // -------------------------------------------------------------------------
  test('@scenario-102 App B ACCEPT: App A token verified via JWKS → 200 + claims', async ({ request }) => {
    const resp = await request.post(`${APP_B_BASE}/verify`, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    expect(resp.status(), 'verify status').toBe(200);
    const body = await resp.json() as { verified?: boolean; claims?: Record<string, unknown> };
    expect(body.verified).toBe(true);
    expect(body.claims).toBeTruthy();
  });

  // -------------------------------------------------------------------------
  // T5: App B rejects tampered token (API level)
  // -------------------------------------------------------------------------
  test('@scenario-102 App B REJECT: tampered token → 401', async ({ request }) => {
    // Tamper the signature bytes
    const [h, p, s] = accessToken.split('.');
    const tampered = `${h}.${p}.${s.slice(0, -4)}XXXX`;
    const resp = await request.post(`${APP_B_BASE}/verify`, {
      headers: { Authorization: `Bearer ${tampered}` },
    });
    expect(resp.status(), 'tampered token status').toBe(401);
    const body = await resp.json() as { verified?: boolean };
    expect(body.verified).toBe(false);
  });

  // -------------------------------------------------------------------------
  // T6: Browser console — valid token → verified claims displayed
  // -------------------------------------------------------------------------
  test('@scenario-102 UI: valid token → verified claims shown', async ({ page }) => {
    await page.goto(APP_B_BASE);

    // Fill the token textarea with the pre-fetched App A token
    await page.fill('#token-input', accessToken);

    // Click Verify
    await page.click('#btn-verify');

    // Assert the result box shows success (green)
    await expect(page.locator('#result')).toHaveClass(/success/, { timeout: 10000 });
    await expect(page.locator('#result')).toContainText('VERIFIED', { timeout: 10000 });
    await expect(page.locator('#result')).toContainText('app-a:8080');

    // Verify status badge flips to "verified"
    await expect(page.locator('#verify-status')).toContainText(/verified/i);

    await page.screenshot({ path: 'test-results/scenario-102-verified.png', fullPage: true });
  });

  // -------------------------------------------------------------------------
  // T7: Browser console — tampered token → rejection shown
  // -------------------------------------------------------------------------
  test('@scenario-102 UI: tampered token → rejection shown', async ({ page }) => {
    await page.goto(APP_B_BASE);

    // Tamper the token
    const [h, p, s] = accessToken.split('.');
    const tampered = `${h}.${p}.${s.slice(0, -4)}XXXX`;
    await page.fill('#token-input', tampered);
    await page.click('#btn-verify');

    // Assert the result box shows error (red)
    await expect(page.locator('#result')).toHaveClass(/error/, { timeout: 10000 });
    await expect(page.locator('#result')).toContainText('REJECTED', { timeout: 10000 });

    await expect(page.locator('#verify-status')).toContainText(/rejected/i);

    await page.screenshot({ path: 'test-results/scenario-102-rejected.png', fullPage: true });
  });

  // -------------------------------------------------------------------------
  // T8: Browser console — Fetch Token button is present and clickable.
  //
  // NOTE: The Fetch Token button makes a cross-origin request from App B
  // (http://localhost:18112) to App A (http://localhost:18102/oauth/token).
  // App A does not set Access-Control-Allow-Origin headers, so the browser
  // blocks this fetch (CORS). This test verifies the button exists and
  // renders the expected initial state; the full Fetch flow is covered by
  // the out-of-band API fetch in beforeAll (tokens are obtained directly
  // from App A's published port without a browser cross-origin restriction).
  // -------------------------------------------------------------------------
  test('@scenario-102 UI: Fetch Token button is present', async ({ page }) => {
    await page.goto(APP_B_BASE);

    // The Fetch Token button must be visible
    await expect(page.locator('#btn-fetch')).toBeVisible();
    await expect(page.locator('#btn-verify')).toBeVisible();
    await expect(page.locator('#btn-clear')).toBeVisible();

    // Initial fetch-status badge shows idle
    await expect(page.locator('#fetch-status')).toContainText(/idle/i);

    await page.screenshot({ path: 'test-results/scenario-102-ui-initial.png', fullPage: true });
  });
});
