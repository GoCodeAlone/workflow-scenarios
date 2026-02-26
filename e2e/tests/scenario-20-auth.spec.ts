import { test, expect } from '@playwright/test';

const BASE_URL = process.env.SCENARIO_URL || 'http://localhost:18020';
const UI_URL = `${BASE_URL}/ui/`;

// @scenario-20
test.describe('Scenario 20: Auth Service UI', () => {
  test('@scenario-20 UI loads at /ui/ prefix', async ({ page }) => {
    const response = await page.goto(UI_URL);
    expect(response?.status()).toBe(200);
  });

  test('@scenario-20 page title is correct', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(page).toHaveTitle('Auth Service — Scenario 20');
  });

  test('@scenario-20 header renders', async ({ page }) => {
    await page.goto(UI_URL);
    const h1 = page.locator('h1');
    await expect(h1).toBeVisible();
    await expect(h1).toContainText('Auth Service');
  });

  test('@scenario-20 register form has required fields', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(page.locator('#reg-name')).toBeVisible();
    await expect(page.locator('#reg-email')).toBeVisible();
    await expect(page.locator('#reg-password')).toBeVisible();
    await expect(page.getByRole('button', { name: /register/i })).toBeVisible();
  });

  test('@scenario-20 login form has required fields', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(page.locator('#login-email')).toBeVisible();
    await expect(page.locator('#login-password')).toBeVisible();
    await expect(page.getByRole('button', { name: /login/i })).toBeVisible();
  });

  test('@scenario-20 run all tests button present', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(page.getByRole('button', { name: /run all tests/i })).toBeVisible();
  });

  test('@scenario-20 root redirects to /ui/', async ({ page }) => {
    await page.goto(`${BASE_URL}/ui`);
    await expect(page).toHaveURL(/\/ui\//);
  });

  test('@scenario-20 full page screenshot', async ({ page }) => {
    await page.goto(UI_URL);
    await page.waitForLoadState('networkidle');
    await page.screenshot({
      path: 'test-results/scenario-20-auth-ui.png',
      fullPage: true,
    });
  });
});
