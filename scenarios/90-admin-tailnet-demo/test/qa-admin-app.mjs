import { createRequire } from 'node:module';
import { mkdir } from 'node:fs/promises';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const baseURL = process.env.BASE || 'http://127.0.0.1:18080';
const screenshotDir = new URL('../.build/qa/', import.meta.url);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function ensureUser(path, email, password, name) {
  await fetch(`${baseURL}${path}/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email, password, name }),
  }).catch(() => {});
  const response = await fetch(`${baseURL}${path}/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  assert(response.ok, `${email} login failed with ${response.status}`);
  const body = await response.json();
  assert(body.token || body.access_token, `${email} login did not return a token`);
}

async function eventually(label, fn) {
  const deadline = Date.now() + 10_000;
  let lastError;
  while (Date.now() < deadline) {
    try {
      await fn();
      return;
    } catch (error) {
      lastError = error;
      await new Promise(resolve => setTimeout(resolve, 200));
    }
  }
  throw new Error(`${label}: ${lastError?.message || 'timed out'}`);
}

async function contains(locator, text, label) {
  await eventually(label, async () => {
    const content = await locator.textContent();
    assert((content || '').includes(text), `${label} missing ${text}; saw ${content}`);
  });
}

async function visible(locator, label) {
  await eventually(label, async () => {
    assert(await locator.isVisible(), `${label} not visible`);
  });
}

async function disabled(locator, label) {
  await eventually(label, async () => {
    assert(await locator.isDisabled(), `${label} not disabled`);
  });
}

async function newPage(browser) {
  const page = await browser.newPage({ viewport: { width: 1440, height: 960 } });
  const errors = [];
  page.on('console', message => {
    const text = message.text();
    if (message.type() === 'error' && !text.includes('status of 403 (Forbidden)')) errors.push(text);
  });
  page.on('pageerror', error => errors.push(error.message));
  return { page, errors };
}

async function qaRootApp(browser) {
  await ensureUser('/api/app/auth', 'app-user@tailnet', 'app-password', 'Support User');
  const { page, errors } = await newPage(browser);
  await page.goto(baseURL);
  assert((await page.title()).includes('Scenario 90 Workflow App'), 'root app title missing');
  await page.getByLabel('Email').fill('app-user@tailnet');
  await page.getByLabel('Password').fill('app-password');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await contains(page.locator('#status'), 'Signed in as app-user@tailnet', 'support app login');
  await contains(page.locator('#access'), '"role": "support"', 'support role projection');
  await contains(page.locator('#access'), 'frontend:orders:read', 'support read scope');
  assert(!(await page.locator('#access').textContent()).includes('frontend:orders:update'), 'support unexpectedly has update scope');
  await contains(page.locator('#orders'), '"allowed": true', 'support order read');
  await page.getByRole('button', { name: 'Update order' }).click();
  await contains(page.locator('#orders'), '"status": 403', 'support update denial');
  await contains(page.locator('#orders'), 'missing frontend:orders:update', 'support denial reason');
  await page.screenshot({ path: new URL('root-support.png', screenshotDir).pathname, fullPage: true });
  assert(errors.length === 0, `root app console errors: ${errors.join('\n')}`);
  await page.close();
}

async function qaAdminAsAdmin(browser) {
  await ensureUser('/api/admin/auth', 'admin@tailnet', 'admin-password', 'Scenario Admin');
  const { page, errors } = await newPage(browser);
  await page.goto(`${baseURL}/admin/`);
  await visible(page.locator('#login-panel h2'), 'admin sign-in heading');
  await page.locator('#admin-email').fill('admin@tailnet');
  await page.locator('#admin-password').fill('admin-password');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await contains(page.locator('#load-status'), 'Admin tools loaded', 'admin tools load');
  await visible(page.getByRole('button', { name: 'Authorization' }), 'authorization nav');
  await visible(page.getByRole('button', { name: 'Authentication' }), 'authentication nav');

  await page.getByRole('button', { name: 'Authentication' }).click();
  await visible(page.getByRole('heading', { name: 'Authentication' }), 'authentication heading');
  await visible(page.getByText('Passkey relying party ID'), 'passkey setting');
  await visible(page.getByText('Password login', { exact: true }), 'password setting');
  await page.getByRole('button', { name: 'Validate changes' }).click();
  await contains(page.locator('.config-result'), '"valid"', 'auth config validation result');

  await page.getByRole('button', { name: 'Authorization' }).click();
  const authz = page.frameLocator('iframe[title="Authorization"]');
  await visible(authz.getByRole('heading', { name: 'Authz Policy Manager' }), 'authz iframe heading');
  await authz.getByRole('button', { name: 'RBAC' }).click();
  await visible(authz.getByRole('heading', { name: 'Role Assignments' }), 'rbac heading');
  await visible(authz.getByLabel('Search declared scopes'), 'declared scope search');
  await visible(authz.locator('.scope-card').filter({ hasText: 'frontend:orders:read' }).first(), 'frontend scope option');
  await visible(authz.locator('.scope-card').filter({ hasText: 'admin:authz.roles:update' }).first(), 'admin update scope option');
  await page.screenshot({ path: new URL('admin-authz.png', screenshotDir).pathname, fullPage: true });
  assert(errors.length === 0, `admin console errors: ${errors.join('\n')}`);
  await page.close();
}

async function qaAdminAsSupport(browser) {
  await ensureUser('/api/app/auth', 'app-user@tailnet', 'app-password', 'Support User');
  const { page, errors } = await newPage(browser);
  await page.goto(`${baseURL}/admin/`);
  await page.locator('#admin-email').fill('app-user@tailnet');
  await page.locator('#admin-password').fill('app-password');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await contains(page.locator('#load-status'), 'Admin tools loaded', 'support admin tools load');
  await visible(page.getByRole('button', { name: 'Authorization' }), 'support authorization nav');
  assert(await page.getByRole('button', { name: 'Authentication' }).count() === 0, 'support can see Authentication admin tool');
  await page.getByRole('button', { name: 'Authorization' }).click();
  const authz = page.frameLocator('iframe[title="Authorization"]');
  await authz.getByRole('button', { name: 'RBAC' }).click();
  await disabled(authz.getByRole('button', { name: 'Add Role' }), 'support add role');
  await visible(authz.getByText('updating requires admin:authz.roles:update'), 'support readonly authz notice');
  assert(errors.length === 0, `support admin console errors: ${errors.join('\n')}`);
  await page.close();
}

await mkdir(screenshotDir, { recursive: true });
const browser = await chromium.launch();
try {
  await qaRootApp(browser);
  await qaAdminAsAdmin(browser);
  await qaAdminAsSupport(browser);
  console.log('PASS: Playwright QA completed');
} finally {
  await browser.close();
}
