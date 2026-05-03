// Visual exploration tour. NOT a regression test — its job is to capture
// every screen of the dashboard so a human (or LLM with a multimodal
// reader) can eyeball what's actually being served.
//
// Outputs PNGs to test/browser/screenshots/. Pair with `npx playwright
// test explore --reporter=line` and review the images afterward.
//
// Run separately from the regression suite via:
//   cd test/browser && npx playwright test explore.spec.js
import { test } from '@playwright/test';
import { mkdirSync } from 'fs';

const SHOTS = 'screenshots';
mkdirSync(SHOTS, { recursive: true });

// Big-ish viewport for legibility in the captured PNGs.
test.use({ viewport: { width: 1400, height: 900 } });

test.describe('dashboard tour', () => {
  test('all five tabs', async ({ page }) => {
    await page.goto('/');
    // Wait for /api/system + /api/sessions + /api/processes to all paint.
    await page.waitForTimeout(2500);

    await page.screenshot({ path: `${SHOTS}/01-tab-webterm.png`, fullPage: true });

    const tabs = ['services', 'storage', 'media', 'discover'];
    let i = 2;
    for (const tab of tabs) {
      await page.locator(`nav.tabs a[data-tab="${tab}"]`).click();
      await page.waitForTimeout(400);
      await page.screenshot({ path: `${SHOTS}/0${i++}-tab-${tab}.png`, fullPage: true });
    }
  });

  test('discover tab — addable row form open', async ({ page }) => {
    await page.goto('/#discover');
    await page.waitForTimeout(1500);
    // Click the first + add button to expand the inline form.
    const addBtn = page.locator('#tab-discover table.procs tr:not(.kit):not(.exposed) .add-btn').first();
    if (await addBtn.count() > 0) {
      await addBtn.click();
      await page.waitForTimeout(300);
      await page.screenshot({ path: `${SHOTS}/06-discover-add-form.png`, fullPage: true });
    }
  });
});

test.describe('terminal endpoints', () => {
  test('/chooser/ ttyd', async ({ page }) => {
    await page.goto('/chooser/');
    // Give ttyd time to do its WS handshake + render the TUI.
    await page.waitForTimeout(3500);
    await page.screenshot({ path: `${SHOTS}/10-chooser-tui.png`, fullPage: true });
  });

  test('/playbook/kommander/ Claude session', async ({ page }) => {
    await page.goto('/playbook/kommander/');
    // Claude takes a moment to attach + render its banner.
    await page.waitForTimeout(4000);
    await page.screenshot({ path: `${SHOTS}/11-playbook-kommander.png`, fullPage: true });
  });

  test('/playbook/kommander-dev/', async ({ page }) => {
    await page.goto('/playbook/kommander-dev/');
    await page.waitForTimeout(4000);
    await page.screenshot({ path: `${SHOTS}/12-playbook-kommander-dev.png`, fullPage: true });
  });
});

test.describe('service paths', () => {
  test('/opencode/ external link target', async ({ page }) => {
    // After the user added opencode in external-link mode, the card url is
    // http://...:9999/. Visit that directly to see what opencode renders.
    await page.goto('http://macminim.tailad422.ts.net:9999/').catch(() => {});
    await page.waitForTimeout(2500);
    await page.screenshot({ path: `${SHOTS}/20-opencode-direct.png`, fullPage: true });
  });
});
