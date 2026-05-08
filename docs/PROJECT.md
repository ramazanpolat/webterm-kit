# PROJECT

Snapshot of where this project is, what it's for, what it isn't, and what's
next. Pairs with `CODEWIKI.md` (code reference) and `CLAUDE.md` (in-repo
narrative). Snapshot: `main` (post `v3-launcher` merge + portable `run.sh`).

---

## What it is

A personal mini control panel for one Mac on a Tailnet. Browser-accessible
terminals, Claude Code sessions per-playbook, plus a discover-and-add
catalog of arbitrary local services proxied behind Caddy with HTTPS via the
Tailscale-issued cert.

In one sentence: **`https://mymac.tailad422.ts.net/` opens a launcher; one
click takes you to a terminal, a Claude session, or any local web service
you've registered.**

## What it isn't

- **Not a public-internet thing.** Tailnet-only. No auth layer beyond
  "you're on the tailnet."
- **Not a multiplexer.** The dashboard launches; it does not embed terminals.
- **Not a process manager.** It doesn't start/stop arbitrary services
  for you. You run `brew services` / `docker` / whatever; the dashboard
  registers them as cards and routes to them.
- **Not a homepage replacement** like Heimdall/Homepage/Dashy. Those
  are general-purpose, prettier, and have wider widget ecosystems. This
  one is opinionated about Claude playbooks + tmux sessions because
  that's what it grew out of.
- **Not cross-platform.** macOS (uses launchd, sysctl, top, lsof,
  vm_stat output formats specific to macOS).

---

## Current state

| area | status |
|---|---|
| Path-routed reverse proxy via Caddy | ✅ working |
| Per-playbook tmux-wrapped Claude sessions | ✅ working |
| Tabbed dashboard SPA with system stats | ✅ working |
| `/api/services` add/list/delete + Caddyfile rewrite + reload | ✅ working |
| Discover tab — list every listening TCP service | ✅ working |
| HTTP/HTTPS protocol detection on discover | ✅ working |
| Smoke test suite (curl) | ✅ 26 assertions |
| Regression suite (Playwright) | ✅ 36 specs |
| Exhaustive walkthrough with real backend | ✅ 42 specs + screenshot capture |
| Manual test scenarios doc | ✅ 11 scenarios |
| AI-driven exploratory loop | ⏸ via screenshot review (not browser-use) |

All v2 + v3 work is now on `main`. Tests passing as of last full run.
Dogfooded daily by the maintainer.

---

## How it grew (3 generations)

### v1 (initial commit)
- ttyd + tmux + a Bubble Tea TUI chooser
- Per-port URLs (`:8020`, `:8022`, `:8024`)
- Hardcoded `SERVICES=(...)` array in install.sh
- One service for tmux, one for the chooser, one for `claude` if installed

### v2 (`v2-playbook-integration`)
- **Playbook auto-discovery** — `~/.claude-playbooks/*/CLAUDE.md` becomes one
  ttyd per
- **Caddy on :443** — TLS terminator, path-routed, no port numbers in URLs
- **tmux-wrapping for resilience** — `tmux new -A -s claude-<name> claude`
  so phone disconnects don't kill the session
- Cert via `tailscale cert`, all backends bind 127.0.0.1

### v3 (current — on `main`)
- **Tabbed launcher** — webterm | services | storage | media | discover
- **Service registry** — `~/.webterm-kit/services.json`, dashboard reads
  + dashboard writes (POST /api/services rewrites the Caddyfile services
  block via sentinels and triggers `caddy reload`)
- **Discover tab** — `lsof | ps` enumeration with HTTP/HTTPS probe;
  one-click add to expose anything local through Caddy
- **System stat bar** — cpu / mem / disk / load / uptime, color-coded
- **Three-tier test infrastructure** — smoke (curl), regression
  (Playwright), exhaustive (real backend round trip + visual screenshots)
- **Visual review loop** — Playwright captures every page; multimodal
  reading replaces "I think it works"

---

## Architectural decisions worth knowing

(Each of these took at least one bug to figure out. Don't undo without
reading the comment in the relevant file.)

- **Caddy admin API for reload, not `--watch`.** macOS file watching
  (FSEvents/kqueue) didn't fire reload events on this setup for any
  write style. `admin localhost:2019` + `caddy reload --config` is
  deterministic. (`dashboard/main.go` `regenerateCaddyfileServices`)
- **Caddyfile services block is sentinel-bounded.** `# === BEGIN/END:
  webterm-kit auto-generated services ===` lets the dashboard rewrite
  just that region without re-rendering the whole file. install.sh
  always emits the sentinels, even with zero services.
- **Sessions auto-attached via `?arg=`, not per-session ttyds.** One
  chooser ttyd serves every named tmux session via `tmux new -A -s NAME`.
  Per-session ttyds would mean N services for a dynamic N.
- **Park-on-end in the chooser.** When tmux exits cleanly, the chooser
  blocks on a signal channel instead of exiting — otherwise ttyd's
  "Press Enter to Reconnect" silently re-creates the killed session
  with the same name. (`chooser/main.go` auto-attach branch)
- **DOM renderer in ttyd, not WebGL.** WebGL/Canvas don't do per-character
  font fallback; the DOM renderer does. Cost: minor perf hit on huge
  scrollback. Win: Unicode glyphs (`⏺ ✻ ※`) render.
- **`LANG=en_US.UTF-8` in launchd plist.** Without it, child processes
  see `LANG=""` and Claude Code falls back to ASCII art for box-drawing
  chars.
- **Tailnet-only is the threat model.** No auth at the Caddy or app
  layer. If you change this, you're signing up for a much bigger problem
  surface (terminals are remote shells; one auth bypass = full machine).
- **Path routing, not subdomain routing.** Subdomains would need extra
  DNS work per service AND a cert per hostname (Tailscale issues per
  exact name, no wildcards). Path mode works zero-config; the cost is
  apps with hardcoded `/foo/bar` paths break under `/<service>/foo/bar`
  prefix. Mitigation: external-link mode for those.

---

## Known limitations

- **Path-prefix incompatibility for some apps.** Single-page apps that
  use absolute URLs (e.g. `<link href="/favicon.ico">`) break under
  `/<service>/` proxying. Workaround: register them as external-link
  mode (no `proxy_to`, just `url: http://host:port/`). See `opencode`
  in `services.example.json`.
- **No subdomain mode (yet).** Would need (a) Tailscale aliases per
  service, (b) per-service `tailscale cert`, (c) a separate Caddy server
  block per. Doable, not built.
- **Tier-3 scenarios are manual.** Things that need eyeballs: font
  rendering, the Ctrl-D parking message, real keyboard interactions in
  ttyd. Documented as a checklist in `test/browser/scenarios.md`. An AI
  agent can walk it via the visual review loop (screenshot → read →
  PASS/FAIL).
- **Process protocol detection is best-effort.** A 200ms HTTP probe
  catches most things; gRPC-only services and apps that hang on plain
  GET get tagged `unknown`.
- **No service health checks on dashboard cards.** A service can be
  dead and the card still renders normally. Would be nice to add a
  green/red dot per card, polling each `proxy_to` for liveness.
- **No rate limit / abuse controls.** Tailnet-only assumption — a
  malicious tailnet member could enumerate processes, add services,
  etc. Not a concern for personal use, would be for shared.

---

## Roadmap (rough, not promises)

**Reasonable next moves** if you want to keep extending:

- **Subdomain mode for apps that don't like path prefixes.** UI option
  in the discover-add form: "path proxy" (current default) vs
  "subdomain proxy" (generates the cert command + Caddy server block).
- **Per-card health checks.** Periodically probe each `proxy_to`,
  surface a dot. Reuse the existing protocol probe; flip dot color on
  ok/timeout.
- **Service edit UI.** Currently you DELETE + POST to change a service.
  A `PATCH /api/services/<name>` + form would be friendlier.
- **Push notifications when an agent needs you.** Hook into Claude Code's
  Stop event in playbook settings → POST to ntfy.sh / Pushover. Mobile
  becomes actually mobile-first.
- **Idle/cost killer per playbook.** "Kill claude-X if idle > 4h" config
  per playbook to bound API spend on forgotten sessions.
- **Activity feed per playbook.** Read each playbook's `history.jsonl` to
  surface "last tool: Edit, 2m ago, turn 47 of 60." Turns the dashboard
  into AgentOps visibility.

**Things to actively NOT build** (already in the "rejected" file mentally):
- A general-purpose homepage with widget marketplace — adopt Homepage
  if you want that.
- A workflow GUI for chaining agents — every successful version of this
  is a programming language anyway.
- Authelia/Authentik front for terminal access — Tailscale is the auth
  layer. One bypass on a different layer = full shell.

---

## Repo state

- **Origin**: https://github.com/ramazanpolat/webterm-kit
- **Single trunk**: `main`. All v2 + v3 work merged; the `v2-playbook-integration`
  and `v3-launcher` branches have been retired.
- **Two ways to run**: `./run.sh` (portable foreground, no sudo) or
  `./install.sh` (launchd-managed, sudo for Caddy daemon). Same backends.

---

## How to start contributing (or remember how things work after a break)

1. Read this file for the why, `CLAUDE.md` for the narrative, `CODEWIKI.md`
   for the where-things-live reference.
2. `./install.sh` to set up a clean install on a Mac with Tailscale.
3. `./test/run-all.sh` to confirm the suite is green (~15s).
4. `./test/exhaustive.sh` for the deep walk (~45s, requires Caddy running).
5. Make the change. Re-run `./test/run-all.sh`. If you touched anything
   user-visible, also `cd test/browser && INCLUDE_EXTENDED=1 npx playwright
   test explore.spec.js` and look at the PNGs in `screenshots/`.
6. Walk the relevant section of `test/browser/scenarios.md` if it
   touches terminals or fonts.
7. Open a PR or merge to your fork.

---

## Maintainer notes

- The user runs Claude Code in a tmux session named
  `claude/webterm-kit/review` while iterating on this project. Test
  scripts deliberately avoid touching `claude/*` and `main` sessions —
  they only kill `exhaust-*` prefix sessions. Don't undo this safety.
- Cleanup of test artifacts (services with `pw-*` and `exhaust-*`
  prefixes) is in `test/exhaustive.sh`'s teardown trap. Keep it
  comprehensive — accumulated leftover services have broken the
  Caddyfile twice already.
- The screenshots/ directory under `test/browser/` is gitignored. They
  are throwaway artifacts of a single test run.
