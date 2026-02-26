import { test, expect } from '@playwright/test';

const BASE_URL = process.env.SCENARIO_URL || 'http://localhost:18022';
const UI_URL = `${BASE_URL}/ui/`;

// @scenario-22
test.describe('Scenario 22: E-Commerce App UI', () => {
  test('@scenario-22 UI loads at /ui/ prefix', async ({ page }) => {
    const response = await page.goto(UI_URL);
    expect(response?.status()).toBe(200);
  });

  test('@scenario-22 page title is correct', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(page).toHaveTitle('Ecommerce App — Scenario 22');
  });

  test('@scenario-22 header renders', async ({ page }) => {
    await page.goto(UI_URL);
    const h1 = page.locator('h1');
    await expect(h1).toBeVisible();
    await expect(h1).toContainText(/ecommerce/i);
  });

  test('@scenario-22 products section renders', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(page.locator('#productList')).toBeVisible();
    await expect(page.getByRole('button', { name: /add product/i })).toBeVisible();
  });

  test('@scenario-22 create product form renders', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(page.locator('#pName')).toBeVisible();
    await expect(page.locator('#pPrice')).toBeVisible();
    await expect(page.locator('#pStock')).toBeVisible();
  });

  test('@scenario-22 place order section renders', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(page.locator('#orderProduct')).toBeVisible();
    await expect(page.locator('#orderQty')).toBeVisible();
    await expect(page.getByRole('button', { name: /place order/i })).toBeVisible();
  });

  test('@scenario-22 run all tests button present', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(page.locator('#runAllBtn')).toBeVisible();
  });

  test('@scenario-22 root redirects to /ui/', async ({ page }) => {
    await page.goto(`${BASE_URL}/ui`);
    await expect(page).toHaveURL(/\/ui\//);
  });

  test('@scenario-22 full page screenshot', async ({ page }) => {
    await page.goto(UI_URL);
    await page.waitForLoadState('networkidle');
    await page.screenshot({
      path: 'test-results/scenario-22-ecommerce-ui.png',
      fullPage: true,
    });
  });
});
