// Discover-tab "+ add" flow end-to-end through the SPA.
//
// Picks the highest-port addable process (most likely to be a transient
// like a dev server, NOT a system binary), opens the form, sets a unique
// name, saves, asserts the row flips to "exposed", then tears down via
// the API so we don't leave clutter.
import { test, expect, request } from '@playwright/test';

test.describe('discover → add flow', () => {
  test('add a service via the SPA form, verify it lands as exposed, then DELETE', async ({ page, baseURL }) => {
    // Make a unique test name so reruns don't collide.
    const testName = `pw-add-${Date.now().toString(36)}`;

    await page.goto('/#discover');

    // Wait for at least one addable row (no .kit / .exposed class on tr).
    const addBtn = page.locator('#tab-discover table.procs tr:not(.kit):not(.exposed) .add-btn').first();
    await expect(addBtn).toBeVisible({ timeout: 5000 });

    // Capture the port from the row before clicking.
    const row = addBtn.locator('xpath=ancestor::tr');
    const port = await row.locator('td.port').textContent();

    // Click + add → inline form appears.
    await addBtn.click();

    // Form fields exist now.
    const nameInput = row.locator('.add-form input[id^="af-name-"]');
    const pathInput = row.locator('.add-form input[id^="af-path-"]');
    const catSelect = row.locator('.add-form select[id^="af-cat-"]');
    await expect(nameInput).toBeVisible();

    // Override the prefilled name + path with our test marker.
    await nameInput.fill(testName);
    await pathInput.fill(`/${testName}/`);
    await catSelect.selectOption('services');

    // Submit. The form's submit handler POSTs to /api/services and
    // re-fetches the table.
    await row.locator('.add-form button[type="submit"]').click();

    // After re-render the row for the same port should be tagged "exposed".
    // We can't use the original row locator (DOM was replaced); search by port.
    const newRow = page.locator(`#tab-discover table.procs tr.exposed:has(td.port:text-is("${port?.trim()}"))`);
    await expect(newRow).toBeVisible({ timeout: 5000 });

    // Also confirm it shows up under the services tab.
    await page.locator('nav.tabs a[data-tab="services"]').click();
    await expect(page.locator(`#tab-services .card .name:text-is("${testName}")`)).toBeVisible();

    // ---- cleanup: DELETE via the API so we don't leave junk in services.json
    const api = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
    const del = await api.delete(`/api/services?name=${encodeURIComponent(testName)}`);
    expect(del.status()).toBe(204);
  });
});
