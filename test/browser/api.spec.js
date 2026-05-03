// Full /api/* contract tests — beyond smoke.sh (which only checks key
// presence), this asserts the SHAPE and TYPE of each value. Catches "I
// renamed the json field but forgot to update the SPA" regressions.
//
// Uses Playwright's `request` fixture instead of a browser page — these
// are pure HTTP tests, faster than launching chromium per test.
import { test, expect } from '@playwright/test';

test.describe('API: /api/sessions', () => {
  test('returns sessions, playbooks, chooserUrl with correct types', async ({ request }) => {
    const r = await request.get('/api/sessions');
    expect(r.status()).toBe(200);
    const d = await r.json();
    expect(Array.isArray(d.sessions)).toBe(true);
    expect(Array.isArray(d.playbooks)).toBe(true);
    expect(typeof d.chooserUrl).toBe('string');
  });

  test('session entries have name, attached, windows, panes', async ({ request }) => {
    const d = await (await request.get('/api/sessions')).json();
    if (d.sessions.length === 0) test.skip(true, 'no sessions to validate');
    for (const s of d.sessions) {
      expect(typeof s.name).toBe('string');
      expect(typeof s.attached).toBe('number');
      expect(typeof s.windows).toBe('number');
      expect(Array.isArray(s.panes)).toBe(true);
    }
  });

  test('playbook entries have name, running, lastActive, url', async ({ request }) => {
    const d = await (await request.get('/api/sessions')).json();
    if (d.playbooks.length === 0) test.skip(true, 'no playbooks to validate');
    for (const p of d.playbooks) {
      expect(typeof p.name).toBe('string');
      expect(typeof p.running).toBe('boolean');
      expect(typeof p.lastActive).toBe('number');
      expect(p.url).toMatch(/^\/playbook\/.+\/$/);
    }
  });
});

test.describe('API: /api/services', () => {
  test('GET returns services array', async ({ request }) => {
    const r = await request.get('/api/services');
    expect(r.status()).toBe(200);
    const d = await r.json();
    expect(Array.isArray(d.services)).toBe(true);
  });

  test('POST with missing name returns 400', async ({ request }) => {
    const r = await request.post('/api/services', { data: { url: '/foo/' } });
    expect(r.status()).toBe(400);
  });

  test('POST with missing url returns 400', async ({ request }) => {
    const r = await request.post('/api/services', { data: { name: 'foo' } });
    expect(r.status()).toBe(400);
  });

  test('POST + duplicate name returns 409', async ({ request }) => {
    const name = `pw-dup-${Date.now()}`;
    const first = await request.post('/api/services', {
      data: { name, url: '/p1/', category: 'services' },
    });
    expect(first.status()).toBe(201);
    const dup = await request.post('/api/services', {
      data: { name, url: '/p2/', category: 'services' },
    });
    expect(dup.status()).toBe(409);
    // cleanup
    await request.delete(`/api/services?name=${encodeURIComponent(name)}`);
  });

  test('DELETE without name returns 400', async ({ request }) => {
    const r = await request.delete('/api/services');
    expect(r.status()).toBe(400);
  });

  test('DELETE missing service returns 404', async ({ request }) => {
    const r = await request.delete('/api/services?name=does-not-exist-xyz123');
    expect(r.status()).toBe(404);
  });

  test('full add → list → delete round-trip', async ({ request }) => {
    const name = `pw-rt-${Date.now()}`;
    const post = await request.post('/api/services', {
      data: { name, url: '/rt/', category: 'storage', icon: '🗂', proxy_to: '127.0.0.1:65535' },
    });
    expect(post.status()).toBe(201);

    const list = await request.get('/api/services');
    const services = (await list.json()).services;
    const found = services.find(s => s.name === name);
    expect(found).toBeTruthy();
    expect(found.category).toBe('storage');
    expect(found.proxy_to).toBe('127.0.0.1:65535');

    const del = await request.delete(`/api/services?name=${name}`);
    expect(del.status()).toBe(204);

    const after = (await (await request.get('/api/services')).json()).services;
    expect(after.find(s => s.name === name)).toBeFalsy();
  });
});

test.describe('API: /api/processes', () => {
  test('returns processes array with full process shape', async ({ request }) => {
    const r = await request.get('/api/processes');
    expect(r.status()).toBe(200);
    const d = await r.json();
    expect(Array.isArray(d.processes)).toBe(true);
    expect(d.processes.length).toBeGreaterThan(0);
    for (const p of d.processes) {
      expect(typeof p.pid).toBe('number');
      expect(typeof p.command).toBe('string');
      expect(typeof p.user).toBe('string');
      expect(typeof p.bind).toBe('string');
      expect(typeof p.port).toBe('number');
      // .kind may be "" (addable) / "kit" / "exposed"
      expect(['', 'kit', 'exposed']).toContain(p.kind || '');
    }
  });

  test('webterm-kit binaries are flagged kind=kit', async ({ request }) => {
    const procs = (await (await request.get('/api/processes')).json()).processes;
    // ttyd is always part of the install.
    const ttyd = procs.find(p => p.command === 'ttyd');
    expect(ttyd).toBeTruthy();
    expect(ttyd.kind).toBe('kit');
  });

  test('exposed services carry serviceUrl', async ({ request }) => {
    // Add a fake service against an actual running port (the dashboard's own).
    const dashboard = (await (await request.get('/api/processes')).json())
      .processes.find(p => p.command.includes('dashboard'));
    if (!dashboard) test.skip(true, 'dashboard process not found');
    const name = `pw-exp-${Date.now()}`;
    await request.post('/api/services', {
      data: {
        name,
        category: 'services',
        url: `/${name}/`,
        proxy_to: `127.0.0.1:${dashboard.port}`,
      },
    });
    const procs = (await (await request.get('/api/processes')).json()).processes;
    const found = procs.find(p => p.port === dashboard.port);
    expect(found.kind).toBe('exposed');
    expect(found.serviceUrl).toBe(`/${name}/`);
    await request.delete(`/api/services?name=${name}`);
  });
});

test.describe('API: /api/system', () => {
  test('returns all expected fields with sensible types', async ({ request }) => {
    const r = await request.get('/api/system');
    expect(r.status()).toBe(200);
    const d = await r.json();
    for (const k of ['cpuPct', 'ramUsedGB', 'ramTotalGB', 'diskFreeGB', 'diskTotalGB', 'load1']) {
      expect(typeof d[k]).toBe('number');
      expect(d[k]).toBeGreaterThanOrEqual(0);
    }
    expect(typeof d.uptimeSec).toBe('number');
    expect(d.uptimeSec).toBeGreaterThan(0);
    expect(typeof d.user).toBe('string');
    expect(d.user.length).toBeGreaterThan(0);
    expect(typeof d.host).toBe('string');
    expect(d.host.length).toBeGreaterThan(0);
    expect(typeof d.home).toBe('string');
    expect(d.home).toMatch(/^\/Users\//);
  });

  test('values are reasonable (RAM > 1G, disk > 10G)', async ({ request }) => {
    const d = await (await request.get('/api/system')).json();
    expect(d.ramTotalGB).toBeGreaterThan(1);
    expect(d.diskTotalGB).toBeGreaterThan(10);
    expect(d.cpuPct).toBeLessThan(200); // sometimes >100 on multicore reporting
  });

  test('cached for ~3s — two rapid calls return identical bytes', async ({ request }) => {
    const a = await (await request.get('/api/system')).json();
    const b = await (await request.get('/api/system')).json();
    // Within the cache window, all the probed values should match.
    // (uptimeSec is clamped to 1-second resolution by the cache.)
    expect(a.cpuPct).toBe(b.cpuPct);
    expect(a.uptimeSec).toBe(b.uptimeSec);
  });
});

test.describe('API: /api/status', () => {
  test('returns now + entries with full shape', async ({ request }) => {
    const r = await request.get('/api/status');
    expect(r.status()).toBe(200);
    const d = await r.json();
    expect(typeof d.now).toBe('number');
    expect(d.now).toBeGreaterThan(1700000000); // sanity: past 2023
    expect(Array.isArray(d.entries)).toBe(true);
    for (const e of d.entries) {
      expect(typeof e.playbook).toBe('string');
      expect(typeof e.running).toBe('boolean');
      expect(typeof e.lastActive).toBe('number');
      expect(typeof e.pid).toBe('number');
    }
  });
});
