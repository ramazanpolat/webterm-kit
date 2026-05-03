// Page-mode behavior — when the dashboard is served at /tmux/ or /playbook/
// (without a name), the SPA's pageMode JS hides the irrelevant section.
// Plus empty-state assertions for each tab when its data source is empty.
//
// IMPORTANT: tests in this file must NEVER delete user-owned services. If a
// category already has data, the empty-state test skips itself rather than
// nuking the user's config. (We learned this the hard way.)
import { test, expect } from '@playwright/test';

test.describe('page modes — /tmux/, /playbook/, /', () => {
  test('/ shows both playbooks AND sessions sections', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#playbooks-list')).toBeVisible();
    await expect(page.locator('#sessions-list')).toBeVisible();
    await expect(page.locator('form.controls')).toBeVisible();
  });

  test('/tmux/ keeps webterm tab content visible (no SPA-side hiding)', async ({ page }) => {
    await page.goto('/tmux/');
    await expect(page).toHaveTitle('kit');
    await expect(page.locator('#tab-webterm')).toBeVisible();
  });

  test('/playbook/ lands on dashboard with normal tabs', async ({ page }) => {
    await page.goto('/playbook/');
    await expect(page).toHaveTitle('kit');
    await expect(page.locator('nav.tabs a[data-tab="webterm"]')).toBeVisible();
  });
});

test.describe('empty states', () => {
  test('storage tab empty state appears when no storage services configured', async ({ page, request }) => {
    const all = (await (await request.get('/api/services')).json()).services;
    const storageCount = all.filter(s => s.category === 'storage').length;
    test.skip(storageCount > 0, `${storageCount} storage service(s) configured — can't assert empty state non-destructively`);
    await page.goto('/#storage');
    await expect(page.locator('#tab-storage .empty')).toBeVisible();
    await expect(page.locator('#tab-storage .empty')).toContainText('storage');
    await expect(page.locator('#tab-storage .empty')).toContainText('services.json');
  });

  test('media tab empty state appears when no media services configured', async ({ page, request }) => {
    const all = (await (await request.get('/api/services')).json()).services;
    const mediaCount = all.filter(s => s.category === 'media').length;
    test.skip(mediaCount > 0, `${mediaCount} media service(s) configured — can't assert empty state non-destructively`);
    await page.goto('/#media');
    await expect(page.locator('#tab-media .empty')).toBeVisible();
  });

  test('temp service appears in services tab while present', async ({ page, request }) => {
    const name = `pw-temp-${Date.now()}`;
    await request.post('/api/services', {
      data: { name, url: 'https://example.com/', icon: '🧪' },
    });
    try {
      await page.goto('/#services');
      await expect(page.locator(`#tab-services .card .name:text-is("${name}")`)).toBeVisible();
    } finally {
      // Always cleanup, even on failure.
      await request.delete(`/api/services?name=${name}`);
    }
  });
});

test.describe('header tally — non-destructive', () => {
  test('srv counter updates when a temp service is added/removed', async ({ page, request }) => {
    // Capture current count rather than nuking — safe.
    const before = (await (await request.get('/api/services')).json()).services.length;

    await page.goto('/');
    await expect(page.locator('#meta-line')).toContainText(`/${before}v`, { timeout: 5000 });

    const name = `pw-tally-${Date.now()}`;
    await request.post('/api/services', { data: { name, url: 'https://example.com/' } });
    try {
      await page.reload();
      await expect(page.locator('#meta-line')).toContainText(`/${before + 1}v`, { timeout: 5000 });
    } finally {
      await request.delete(`/api/services?name=${name}`);
    }
  });
});
