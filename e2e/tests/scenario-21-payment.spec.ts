import { test, expect } from '@playwright/test';

const BASE_URL = process.env.SCENARIO_URL || 'http://localhost:18021';
const UI_URL = `${BASE_URL}/ui/`;

// @scenario-21
test.describe('Scenario 21: Payment Service UI', () => {
  test('@scenario-21 UI loads at /ui/ prefix', async ({ page }) => {
    const response = await page.goto(UI_URL);
    expect(response?.status()).toBe(200);
  });

  test('@scenario-21 page title is correct', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(page).toHaveTitle('Payment Service — Scenario 21');
  });

  test('@scenario-21 header renders', async ({ page }) => {
    await page.goto(UI_URL);
    const h1 = page.locator('h1');
    await expect(h1).toBeVisible();
    await expect(h1).toContainText('Payment Service');
  });

  test('@scenario-21 create payment form renders', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(page.locator('#create-amount')).toBeVisible();
    await expect(page.locator('#create-currency')).toBeVisible();
    await expect(page.locator('#create-order-id')).toBeVisible();
    await expect(page.locator('#create-callback')).toBeVisible();
    await expect(page.locator('button[onclick="createPayment()"]')).toBeVisible();
  });

  test('@scenario-21 lookup payment form renders', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(page.locator('#lookup-id')).toBeVisible();
    await expect(page.locator('button[onclick="lookupPayment()"]')).toBeVisible();
  });

  test('@scenario-21 payment actions section renders', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(page.locator('#action-id')).toBeVisible();
    await expect(page.getByRole('button', { name: /capture/i })).toBeVisible();
    await expect(page.getByRole('button', { name: /refund/i })).toBeVisible();
  });

  test('@scenario-21 automated tests button present', async ({ page }) => {
    await page.goto(UI_URL);
    await expect(page.locator('#run-tests-btn')).toBeVisible();
  });

  test('@scenario-21 root redirects to /ui/', async ({ page }) => {
    await page.goto(`${BASE_URL}/ui`);
    await expect(page).toHaveURL(/\/ui\//);
  });

  test('@scenario-21 full page screenshot', async ({ page }) => {
    await page.goto(UI_URL);
    await page.waitForLoadState('networkidle');
    await page.screenshot({
      path: 'test-results/scenario-21-payment-ui.png',
      fullPage: true,
    });
  });
});
