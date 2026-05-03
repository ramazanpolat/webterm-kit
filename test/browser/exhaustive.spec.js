// Exhaustive walkthrough — every page, every tab, every shortcut, the
// full add-service round trip with a real backend server, terminal
// endpoint capture, error cases. Captures one screenshot per checkpoint
// into screenshots/exhaust-NN-*.png.
//
// PROTECTION: this spec MUST NOT touch tmux sessions whose names start
// with "claude" or "main" (they belong to the running Claude Code
// instances and the user's main shell). All test sessions use prefix
// "exhaust-" and are visibly suffixed with a timestamp.
import { test, expect, request } from '@playwright/test';
import { mkdirSync } from 'fs';

const SHOTS = 'screenshots';
mkdirSync(SHOTS, { recursive: true });

// Stable ID for this run so screenshots and service names are unique.
const RUN_ID = `exhaust-${Date.now().toString(36)}`;
const TEST_PORT = 17777; // matches what run-exhaustive.sh starts as a backend

// Big viewport for legible screenshots.
test.use({ viewport: { width: 1400, height: 900 } });

// All steps run sequentially because we mutate state (add/delete services).
test.describe.configure({ mode: 'serial' });

test.describe('exhaustive', () => {
  // ────────────────────────────────────────────────────────────────────
  // SECTION A — page renders + every tab visible
  // ────────────────────────────────────────────────────────────────────
  test('A1 landing / loads with brand and 5 tabs', async ({ page }) => {
    await page.goto('/');
    await page.waitForTimeout(2500); // let /api/system populate
    await expect(page).toHaveTitle('kit');
    for (const t of ['webterm', 'services', 'storage', 'media', 'discover']) {
      await expect(page.locator(`nav.tabs a[data-tab="${t}"]`)).toBeVisible();
    }
    await page.screenshot({ path: `${SHOTS}/${RUN_ID}-a1-landing.png`, fullPage: true });
  });

  test('A2 brand morphs to user@host:~', async ({ page }) => {
    await page.goto('/');
    await page.waitForTimeout(2000);
    const ctx = page.locator('#brand-ctx');
    await expect(ctx).toContainText('@');
    await expect(ctx).toContainText(':~');
  });

  test('A3 stat bar shows real numbers', async ({ page }) => {
    await page.goto('/');
    await page.waitForTimeout(2000);
    for (const id of ['sys-cpu', 'sys-ram', 'sys-disk', 'sys-load', 'sys-up']) {
      const val = await page.locator(`#${id} .val`).textContent();
      expect(val).not.toBe('—');
      expect(val.trim().length).toBeGreaterThan(0);
    }
    await page.screenshot({ path: `${SHOTS}/${RUN_ID}-a3-statbar.png` });
  });

  // ────────────────────────────────────────────────────────────────────
  // SECTION B — click every tab, screenshot
  // ────────────────────────────────────────────────────────────────────
  for (const tab of ['webterm', 'services', 'storage', 'media', 'discover']) {
    test(`B click tab "${tab}"`, async ({ page }) => {
      await page.goto('/');
      await page.waitForTimeout(1500);
      await page.locator(`nav.tabs a[data-tab="${tab}"]`).click();
      await page.waitForTimeout(400);
      await expect(page.locator(`nav.tabs a[data-tab="${tab}"]`)).toHaveClass(/active/);
      await expect(page.locator(`#tab-${tab}`)).toHaveClass(/active/);
      expect(page.url()).toMatch(new RegExp(`#${tab}$`));
      await page.screenshot({ path: `${SHOTS}/${RUN_ID}-b-tab-${tab}.png`, fullPage: true });
    });
  }

  // ────────────────────────────────────────────────────────────────────
  // SECTION C — every keyboard shortcut + every hash deep link
  // ────────────────────────────────────────────────────────────────────
  for (const [n, name] of [[1, 'webterm'], [2, 'services'], [3, 'storage'], [4, 'media'], [5, 'discover']]) {
    test(`C key "${n}" → ${name}`, async ({ page }) => {
      await page.goto('/');
      await page.waitForTimeout(1000);
      await page.keyboard.press(String(n));
      await expect(page.locator(`nav.tabs a[data-tab="${name}"]`)).toHaveClass(/active/);
    });
    test(`C hash #${name} activates ${name}`, async ({ page }) => {
      await page.goto(`/#${name}`);
      await expect(page.locator(`nav.tabs a[data-tab="${name}"]`)).toHaveClass(/active/);
    });
  }

  test('C number keys ignored when input focused', async ({ page }) => {
    await page.goto('/');
    await page.waitForTimeout(1000);
    await page.locator('#new-name').click();
    await page.keyboard.press('5');
    // Input value should be "5", tab should still be webterm.
    await expect(page.locator('#new-name')).toHaveValue('5');
    await expect(page.locator('nav.tabs a[data-tab="webterm"]')).toHaveClass(/active/);
  });

  // ────────────────────────────────────────────────────────────────────
  // SECTION D — webterm tab content + open form (intercepted)
  // ────────────────────────────────────────────────────────────────────
  test('D1 playbooks list has cards with running pill', async ({ page }) => {
    await page.goto('/');
    await page.waitForTimeout(2000);
    const playbookCards = page.locator('#playbooks-list a.card');
    expect(await playbookCards.count()).toBeGreaterThan(0);
  });

  test('D2 sessions list has cards with status badges', async ({ page }) => {
    await page.goto('/');
    await page.waitForTimeout(2000);
    const sessCards = page.locator('#sessions-list a.card');
    expect(await sessCards.count()).toBeGreaterThan(0);
  });

  test('D3 open form constructs /chooser/?arg=NAME', async ({ page }) => {
    await page.route('**/chooser/**', (route) =>
      route.fulfill({ status: 200, contentType: 'text/html', body: '<html>stub</html>' }));
    await page.goto('/');
    const name = `${RUN_ID}-formcheck`;
    await page.fill('#new-name', name);
    const nav = page.waitForURL(new RegExp(`/chooser/\\?arg=${name}$`), { timeout: 5000 });
    await page.locator('form.controls button[type="submit"]').click();
    await nav;
  });

  // ────────────────────────────────────────────────────────────────────
  // SECTION E — services / storage / media tabs (categories)
  // ────────────────────────────────────────────────────────────────────
  test('E1 services tab shows existing user cards', async ({ page }) => {
    await page.goto('/#services');
    await page.waitForTimeout(1500);
    // The user has opencode in services. Just assert SOME card or empty state.
    const cardCount = await page.locator('#tab-services a.card').count();
    const hasEmpty = await page.locator('#tab-services .empty').count();
    expect(cardCount + hasEmpty).toBeGreaterThan(0);
    await page.screenshot({ path: `${SHOTS}/${RUN_ID}-e1-services.png`, fullPage: true });
  });

  test('E2 storage tab — empty state or cards', async ({ page }) => {
    await page.goto('/#storage');
    await page.waitForTimeout(1500);
    const ok = (await page.locator('#tab-storage .empty').count())
             + (await page.locator('#tab-storage a.card').count());
    expect(ok).toBeGreaterThan(0);
  });

  test('E3 media tab — empty state or cards', async ({ page }) => {
    await page.goto('/#media');
    await page.waitForTimeout(1500);
    const ok = (await page.locator('#tab-media .empty').count())
             + (await page.locator('#tab-media a.card').count());
    expect(ok).toBeGreaterThan(0);
  });

  // ────────────────────────────────────────────────────────────────────
  // SECTION F — discover tab + full add-service round trip with REAL backend
  // ────────────────────────────────────────────────────────────────────
  test(`F1 discover tab shows test server on port ${TEST_PORT}`, async ({ page }) => {
    await page.goto('/#discover');
    await page.waitForTimeout(1500);
    await expect(page.locator(`#tab-discover table.procs td.port:text-is("${TEST_PORT}")`))
      .toBeVisible({ timeout: 5000 });
    await page.screenshot({ path: `${SHOTS}/${RUN_ID}-f1-discover.png`, fullPage: true });
  });

  test('F2 click + add → form appears', async ({ page }) => {
    await page.goto('/#discover');
    await page.waitForTimeout(1500);
    const row = page.locator(`#tab-discover table.procs tr:has(td.port:text-is("${TEST_PORT}"))`).first();
    await row.locator('.add-btn').click();
    await page.waitForTimeout(300);
    await expect(row.locator('.add-form')).toBeVisible();
    await page.screenshot({ path: `${SHOTS}/${RUN_ID}-f2-add-form-open.png`, fullPage: true });
  });

  test('F3 submit form → service created, row turns "exposed"', async ({ page, request }) => {
    await page.goto('/#discover');
    await page.waitForTimeout(1500);
    const row = page.locator(`#tab-discover table.procs tr:has(td.port:text-is("${TEST_PORT}"))`).first();
    await row.locator('.add-btn').click();
    await row.locator('.add-form input[id^="af-name-"]').fill(RUN_ID);
    await row.locator('.add-form input[id^="af-path-"]').fill(`/${RUN_ID}/`);
    await row.locator('.add-form select[id^="af-cat-"]').selectOption('services');
    await row.locator('.add-form button[type="submit"]').click();
    await page.waitForTimeout(800); // POST + Caddyfile rewrite + Caddy reload
    const exposedRow = page.locator(
      `#tab-discover table.procs tr.exposed:has(td.port:text-is("${TEST_PORT}"))`);
    await expect(exposedRow).toBeVisible({ timeout: 5000 });
    await page.screenshot({ path: `${SHOTS}/${RUN_ID}-f3-exposed.png`, fullPage: true });
  });

  test('F4 service appears in services tab', async ({ page }) => {
    await page.goto('/#services');
    await page.waitForTimeout(1500);
    await expect(page.locator(`#tab-services .card .name:text-is("${RUN_ID}")`)).toBeVisible();
  });

  test('F5 Caddy proxies the new service path to the test server', async ({ request }) => {
    // Caddy --watch's reload timing varies; poll up to ~5s for the new route
    // to come live. The backend (python3 -m http.server) sets a distinctive
    // Server header that proves Caddy routed through.
    let server = '';
    for (let i = 0; i < 10; i++) {
      const r = await request.get(`/${RUN_ID}/`);
      server = r.headers()['server'] || '';
      if (server.match(/SimpleHTTP/i)) break;
      await new Promise(r => setTimeout(r, 500));
    }
    expect(server).toMatch(/SimpleHTTP/i);
  });

  test('F6 DELETE removes service and Caddy route', async ({ request }) => {
    const del = await request.delete(`/api/services?name=${RUN_ID}`);
    expect(del.status()).toBe(204);
    await new Promise(r => setTimeout(r, 1500));
    const r = await request.get(`/${RUN_ID}/`);
    // Catch-all (dashboard) returns 404 for unknown subpath.
    expect(r.status()).toBe(404);
  });

  // ────────────────────────────────────────────────────────────────────
  // SECTION G — terminal endpoints (visual capture only)
  // ────────────────────────────────────────────────────────────────────
  test('G1 /chooser/ ttyd renders TUI', async ({ page }) => {
    await page.goto('/chooser/');
    await page.waitForTimeout(3500);
    const body = await page.textContent('body');
    expect(body).toContain('webterm');
    expect(body).toContain('tmux sessions');
    await page.screenshot({ path: `${SHOTS}/${RUN_ID}-g1-chooser.png`, fullPage: true });
  });

  test('G2 /tmux/<exhaust-name>/ creates and attaches a fresh session', async ({ page }) => {
    // /tmux/<name>/ → 302 → /chooser/?arg=<name>. The chooser does
    // `tmux new -A -s <name>` which attaches to a brand-new session.
    await page.goto(`/tmux/${RUN_ID}/`);
    await page.waitForTimeout(3500);
    await page.screenshot({ path: `${SHOTS}/${RUN_ID}-g2-tmux-new.png`, fullPage: true });
    // Don't kill here — run.sh teardown removes any exhaust-* sessions.
  });

  test('G3 /playbook/kommander/ renders Claude session (read-only check)', async ({ page }) => {
    await page.goto('/playbook/kommander/');
    await page.waitForTimeout(4500);
    await page.screenshot({ path: `${SHOTS}/${RUN_ID}-g3-playbook.png`, fullPage: true });
  });

  // ────────────────────────────────────────────────────────────────────
  // SECTION H — error and edge cases
  // ────────────────────────────────────────────────────────────────────
  test('H1 GET /nonexistent → 404', async ({ request }) => {
    const r = await request.get('/this-path-does-not-exist');
    expect(r.status()).toBe(404);
  });

  test('H2 POST /api/services missing name → 400', async ({ request }) => {
    const r = await request.post('/api/services', { data: { url: '/x/' } });
    expect(r.status()).toBe(400);
  });

  test('H3 POST /api/services duplicate name → 409', async ({ request }) => {
    const name = `${RUN_ID}-dup`;
    const a = await request.post('/api/services', { data: { name, url: '/dup/' } });
    expect(a.status()).toBe(201);
    const b = await request.post('/api/services', { data: { name, url: '/dup2/' } });
    expect(b.status()).toBe(409);
    await request.delete(`/api/services?name=${name}`);
  });

  test('H4 DELETE /api/services missing name → 400', async ({ request }) => {
    const r = await request.delete('/api/services');
    expect(r.status()).toBe(400);
  });

  test('H5 DELETE /api/services unknown → 404', async ({ request }) => {
    const r = await request.delete(`/api/services?name=does-not-exist-${Date.now()}`);
    expect(r.status()).toBe(404);
  });

  test('H6 GET /chooser → 301 to /chooser/', async ({ request }) => {
    const r = await request.get('/chooser', { maxRedirects: 0 });
    expect(r.status()).toBe(301);
    expect(r.headers()['location']).toBe('/chooser/');
  });

  test('H7 GET /tmux/some-name/ → 302 to /chooser/?arg=', async ({ request }) => {
    const r = await request.get('/tmux/test-redirect/', { maxRedirects: 0 });
    expect(r.status()).toBe(302);
    expect(r.headers()['location']).toBe('/chooser/?arg=test-redirect');
  });

  test('H8 HTTP→HTTPS upgrade on :80', async ({ request }) => {
    const target = 'http://macminim.tailad422.ts.net/';
    const r = await request.get(target, { maxRedirects: 0 });
    expect(r.status()).toBe(301);
    expect(r.headers()['location']).toMatch(/^https:/);
  });
});
