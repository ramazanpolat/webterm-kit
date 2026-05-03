// Playwright config for webterm-kit browser tests.
//
// Target URL is taken from TARGET_URL env, falling back to the local
// Tailnet hostname. Self-signed cert tolerated via ignoreHTTPSErrors.
import { defineConfig, devices } from '@playwright/test';

const target =
  process.env.TARGET_URL ||
  (process.env.TAILNET_HOST
    ? `https://${process.env.TAILNET_HOST}`
    : 'https://macminim.tailad422.ts.net');

export default defineConfig({
  testDir: '.',
  // Default discovery skips exhaustive + explore — they need extra setup
  // (test http server, screenshot reads). Their wrapper scripts set
  // INCLUDE_EXTENDED=1 to opt in.
  testIgnore: process.env.INCLUDE_EXTENDED === '1'
    ? []
    : ['exhaustive.spec.js', 'explore.spec.js'],
  // Each test file is its own world; no shared state between them.
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: 0,
  workers: 1,
  reporter: process.env.CI ? 'github' : 'list',
  use: {
    baseURL: target,
    ignoreHTTPSErrors: true,
    // Trace + screenshot on failure — handy when iterating.
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    actionTimeout: 5000,
    navigationTimeout: 15000,
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
