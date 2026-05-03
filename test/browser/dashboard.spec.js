// Regression tests for the main dashboard SPA.
//
// These mirror the Tier-1 smoke checks but exercise the parts that need
// JavaScript to actually run — tab switching, URL hashes, system stat
// polling, the prompt-style brand. They DON'T touch ttyd terminals
// (those are integration territory; covered manually for now).
import { test, expect } from '@playwright/test';

test.describe('dashboard root', () => {
  test('loads with brand + all four content tabs visible', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveTitle('kit');
    // Brand is "user@host:~ $ kit" once /api/system populates.
    await expect(page.locator('.brand .cmd')).toHaveText('kit');
    // All five tabs in the strip
    for (const name of ['webterm', 'services', 'storage', 'media', 'discover']) {
      await expect(page.locator(`nav.tabs a[data-tab="${name}"]`)).toBeVisible();
    }
  });

  test('webterm is the default active tab', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('nav.tabs a[data-tab="webterm"]')).toHaveClass(/active/);
    await expect(page.locator('#tab-webterm')).toHaveClass(/active/);
    // Other tab content is hidden via CSS (display:none on non-active).
    await expect(page.locator('#tab-services')).not.toHaveClass(/active/);
  });

  test('clicking a tab switches both nav state and visible content', async ({ page }) => {
    await page.goto('/');
    await page.locator('nav.tabs a[data-tab="services"]').click();
    await expect(page.locator('nav.tabs a[data-tab="services"]')).toHaveClass(/active/);
    await expect(page.locator('#tab-services')).toHaveClass(/active/);
    await expect(page.locator('#tab-webterm')).not.toHaveClass(/active/);
    // Hash should have updated for deep linking.
    expect(page.url()).toMatch(/#services$/);
  });

  test('number keys jump tabs (1=webterm, 5=discover)', async ({ page }) => {
    await page.goto('/');
    await page.keyboard.press('5');
    await expect(page.locator('nav.tabs a[data-tab="discover"]')).toHaveClass(/active/);
    await page.keyboard.press('1');
    await expect(page.locator('nav.tabs a[data-tab="webterm"]')).toHaveClass(/active/);
  });

  test('hash deep-link activates the correct tab', async ({ page }) => {
    await page.goto('/#discover');
    await expect(page.locator('nav.tabs a[data-tab="discover"]')).toHaveClass(/active/);
    await expect(page.locator('#tab-discover')).toHaveClass(/active/);
  });
});

test.describe('header system stats', () => {
  test('populates from /api/system within a few seconds', async ({ page }) => {
    await page.goto('/');
    // Each stat starts as "—" and changes once the fetch resolves.
    // We assert it stops being a literal em-dash.
    for (const id of ['sys-cpu', 'sys-ram', 'sys-disk', 'sys-load', 'sys-up']) {
      const val = page.locator(`#${id} .val`);
      await expect(val).not.toHaveText('—', { timeout: 5000 });
    }
  });

  test('brand renders user@host:~ from /api/system', async ({ page }) => {
    await page.goto('/');
    // ctx span morphs from "user@host:~" placeholder to "actual@actual:~"
    // once /api/system responds.
    const ctx = page.locator('#brand-ctx');
    await expect(ctx).not.toHaveText('user@host:~', { timeout: 5000 });
    await expect(ctx).toContainText(':~');
    await expect(ctx).toContainText('@');
  });
});

test.describe('webterm tab content', () => {
  test('shows playbooks and sessions sections', async ({ page }) => {
    await page.goto('/#webterm');
    await expect(page.locator('#tab-webterm .row-title:has-text("Claude playbooks")')).toBeVisible();
    await expect(page.locator('#tab-webterm .row-title:has-text("tmux sessions")')).toBeVisible();
    // The "open or create session" form should be visible only on webterm tab.
    await expect(page.locator('form.controls input#new-name')).toBeVisible();
  });

  test('open form navigates to /chooser/?arg=<name>', async ({ page }) => {
    await page.goto('/');
    await page.fill('#new-name', 'pw-test-session');
    // Submitting the form sets window.location.href = /chooser/?arg=<encoded>.
    // We just wait for the navigation to land on that URL — proves the form
    // built the URL correctly. ttyd at /chooser/ then handles the request.
    const nav = page.waitForURL(/\/chooser\/\?arg=pw-test-session$/, { timeout: 5000 });
    await page.locator('form.controls button[type="submit"]').click();
    await nav;
  });
});

test.describe('discover tab', () => {
  test('renders process table with at least one row', async ({ page }) => {
    await page.goto('/#discover');
    // Wait for /api/processes to populate.
    const tbody = page.locator('#tab-discover table.procs tbody tr');
    await expect(tbody.first()).toBeVisible({ timeout: 5000 });
    // We always have ttyd + dashboard + caddy at minimum, so > 1 row.
    expect(await tbody.count()).toBeGreaterThan(1);
  });

  test('webterm-kit-owned rows are tagged read-only', async ({ page }) => {
    await page.goto('/#discover');
    // The table CSS adds class="kit" to read-only rows. At least one of
    // chooser/dashboard/caddy must be tagged.
    const kitRows = page.locator('#tab-discover table.procs tr.kit');
    await expect(kitRows.first()).toBeVisible({ timeout: 5000 });
  });
});
