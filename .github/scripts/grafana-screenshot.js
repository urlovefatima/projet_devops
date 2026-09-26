// Logs into Grafana, opens the LLM DevOps dashboard, waits for panels to
// render real data, and saves a full-page PNG screenshot.
//
// Expects Grafana to be reachable at http://localhost:3000 (via
// `kubectl port-forward`) with the admin/admin credentials set in
// 06-grafana-deployment.yaml.

const { chromium } = require('playwright');

const GRAFANA_URL = 'http://localhost:3000';
const DASHBOARD_URL = `${GRAFANA_URL}/d/llm-app-dashboard`;
const USERNAME = 'admin';
const PASSWORD = 'admin';
const OUTPUT_PATH = 'grafana-dashboard.png';

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });

  try {
    // 1. Log in
    await page.goto(`${GRAFANA_URL}/login`, { waitUntil: 'networkidle' });
    await page.fill('input[name="user"]', USERNAME);
    await page.fill('input[name="password"]', PASSWORD);
    await page.click('button[type="submit"]');
    await page.waitForURL(`${GRAFANA_URL}/**`, { timeout: 15000 });

    // Skip the "change password" prompt if Grafana shows it
    const skipButton = page.locator('text=Skip');
    if (await skipButton.isVisible({ timeout: 3000 }).catch(() => false)) {
      await skipButton.click();
    }

    // 2. Open the dashboard
    await page.goto(DASHBOARD_URL, { waitUntil: 'networkidle' });

    // 3. Give the panels time to fetch data from Prometheus and render
    await page.waitForTimeout(8000);

    // 4. Screenshot
    await page.screenshot({ path: OUTPUT_PATH, fullPage: true });
    console.log(`Screenshot saved to ${OUTPUT_PATH}`);
  } catch (err) {
    console.error('Failed to capture Grafana screenshot:', err);
    await page.screenshot({ path: 'grafana-debug-failure.png', fullPage: true }).catch(() => {});
    process.exit(1);
  } finally {
    await browser.close();
  }
})();
