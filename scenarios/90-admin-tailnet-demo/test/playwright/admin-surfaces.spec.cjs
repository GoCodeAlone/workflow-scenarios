const { test, expect } = require('@playwright/test');

async function loginAdmin(page, request, email = 'admin@tailnet', password = 'admin-password') {
  await request.post('/api/admin/auth/register', {
    data: { email, password, name: email.split('@')[0] },
    failOnStatusCode: false,
  });
  await page.goto('/admin/');
  await page.locator('#admin-email').fill(email);
  await page.locator('#admin-password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.locator('#load-status')).toContainText(/Admin tools loaded|Contributions loaded|Loading/i, { timeout: 10000 });
}

function captureConsoleErrors(page, errors) {
  page.on('console', (message) => {
    if (message.type() === 'error') errors.push(message.text());
  });
  page.on('pageerror', (error) => errors.push(error.message));
}

test('Scenario 90 admin surfaces are usable and protected', async ({ page, context, request, browser }) => {
  const consoleErrors = [];
  captureConsoleErrors(page, consoleErrors);
  context.on('page', (newPage) => captureConsoleErrors(newPage, consoleErrors));

  await loginAdmin(page, request);
  await expect(page.getByRole('button', { name: 'Authentication' })).toBeVisible({ timeout: 10000 });

  await page.getByRole('button', { name: 'Authentication' }).click();
  await expect(page.locator('#panel-title')).toHaveText('Authentication');
  await expect(page.locator('#contribution-list')).toContainText('Passkey relying party ID', { timeout: 10000 });
  await expect(page.locator('#contribution-list')).toContainText('OAuth providers');
  await page.getByRole('button', { name: 'Validate changes' }).click();
  await expect(page.locator('#contribution-list')).toContainText(/valid/i);
  await expect(page.getByRole('button', { name: 'Apply changes' })).toBeVisible();
  await page.getByLabel('Passkey relying party ID').fill('127.0.0.1');
  await page.getByLabel('Passkey origin').fill('http://127.0.0.1:18080');
  await page.getByLabel('Auth routes').check();
  await page.getByLabel('Auth0 domain').fill('demo.us.auth0.com');
  await page.getByLabel('M2M client ID').fill('scenario90-browser-client');
  await page.getByLabel('M2M client secret').fill('scenario90-browser-secret-value');
  await page.getByRole('button', { name: 'Apply changes' }).click();
  await expect(page.locator('#contribution-list')).toContainText('"applied": true');
  await expect(page.locator('#contribution-list')).toContainText('"auth0_client_secret": "secret://scenario90/auth0_client_secret"');
  await expect(page.locator('#contribution-list')).not.toContainText('scenario90-browser-secret-value');
  await expect(page.getByLabel('M2M client secret')).toHaveValue('');
  let activeLabels = await page.locator('button.nav-item.active').evaluateAll((nodes) => nodes.map((node) => node.textContent.trim()));
  expect(activeLabels).toEqual(['Authentication']);

  await page.getByRole('button', { name: 'Authorization' }).click();
  await expect(page.locator('#panel-title')).toHaveText('Authorization');
  activeLabels = await page.locator('button.nav-item.active').evaluateAll((nodes) => nodes.map((node) => node.textContent.trim()));
  expect(activeLabels).toEqual(['Authorization']);

  const frame = page.frameLocator('#contribution-list iframe').first();
  await expect(frame.getByText('Authz Policy Manager')).toBeVisible({ timeout: 10000 });
  await expect(frame.locator('body')).not.toContainText('Not authorized');
  await expect(frame.locator('body')).toContainText(/RBAC|Role Assignments|Provider Overview/i);
  await frame.getByRole('button', { name: 'Overview' }).click();
  await expect(frame.locator('body')).toContainText('RBAC');
  await expect(frame.getByRole('button', { name: 'ABAC' })).toHaveCount(0);
  await expect(frame.getByRole('button', { name: 'ReBAC' })).toHaveCount(0);
  await frame.getByRole('button', { name: 'RBAC' }).click();
  await expect(frame.getByRole('button', { name: 'Add Role' })).toBeEnabled();
  await frame.getByLabel('User', { exact: true }).selectOption('app-user@tailnet');
  await frame.getByLabel('Role', { exact: true }).selectOption('support');
  await frame.locator('form.rule-form select').nth(2).selectOption('admin');
  await frame.locator('label.scope-option').filter({ hasText: 'admin:authz.roles:read' }).locator('input').check();
  await frame.getByRole('button', { name: 'Add Role' }).click();
  await expect(frame.locator('body')).toContainText('admin:authz.roles:read');
  const adminToken = await page.evaluate(() => {
    const shell = document.querySelector('[data-token-storage-key]');
    const storageKey = shell?.dataset?.tokenStorageKey || 'workflow.admin.token';
    return window.localStorage.getItem(storageKey);
  });
  const rolesAfterWrite = await request.get('/api/authz/roles', {
    headers: { Authorization: `Bearer ${adminToken}` },
  });
  expect(rolesAfterWrite.ok()).toBeTruthy();
  const roleRows = await rolesAfterWrite.json();
  expect(roleRows).toEqual(expect.arrayContaining([
    expect.objectContaining({
      user: 'app-user@tailnet',
      role: 'support',
      context: 'admin',
      scopes: expect.arrayContaining(['admin:authz.roles:read']),
    }),
  ]));
  await frame.getByRole('button', { name: 'Simulator' }).click();
  await expect(frame.locator('body')).toContainText(/Authorize|Subject|Object/i);
  await frame.getByRole('button', { name: 'Audit' }).click();
  await expect(frame.locator('body')).toContainText('Unavailable');

  const direct = await context.newPage();
  await direct.goto('/admin/authz/');
  await expect(direct.getByText('Authentication Required')).toBeVisible({ timeout: 10000 });
  await expect(direct.locator('body')).toContainText('Sign in through Workflow Admin');
  await expect(direct.locator('body')).not.toContainText('Authz Policy Manager');
  await expect(direct.locator('body')).not.toContainText('Role Assignments');
  await direct.close();

  await request.post('/api/app/auth/register', {
    data: { email: 'app-user@tailnet', password: 'app-password', name: 'Support User' },
    failOnStatusCode: false,
  });
  const supportContext = await browser.newContext({ baseURL: 'http://127.0.0.1:18080' });
  supportContext.on('page', (newPage) => captureConsoleErrors(newPage, consoleErrors));
  const supportPage = await supportContext.newPage();
  await loginAdmin(supportPage, request, 'app-user@tailnet', 'app-password');
  await expect(supportPage.getByRole('button', { name: 'Authorization' })).toBeVisible({ timeout: 10000 });
  await expect(supportPage.getByRole('button', { name: 'Authentication' })).toHaveCount(0);
  await supportPage.getByRole('button', { name: 'Authorization' }).click();
  const supportFrame = supportPage.frameLocator('#contribution-list iframe').first();
  await expect(supportFrame.getByText('Authz Policy Manager')).toBeVisible({ timeout: 10000 });
  await expect(supportFrame.locator('body')).not.toContainText('Not authorized');
  await supportFrame.getByRole('button', { name: 'RBAC' }).click();
  await expect(supportFrame.getByRole('button', { name: 'Add Role' })).toBeDisabled();
  await expect(supportFrame.locator('body')).toContainText('updating requires admin:authz.roles:update');
  await supportContext.close();

  expect(consoleErrors.filter((text) => !text.includes('favicon'))).toEqual([]);
});
