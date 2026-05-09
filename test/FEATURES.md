# Feature inventory

What this project does, organized by surface. Used as the spec for the
test suite — every line item should map to one or more automated tests
(see `test/browser/*.spec.js` and `test/smoke.sh`). Items marked
`[manual]` need a human or AI agent (see `test/browser/scenarios.md`).

## A. HTTP routing (Caddy)

- A1. `GET /` → 200, dashboard SPA
- A2. `GET /chooser/` → 200, ttyd terminal
- A3. `GET /chooser` (no slash) → 301 → `/chooser/`
- A4. `GET /tmux/` → 200, dashboard SPA (page-mode = tmux)
- A5. `GET /tmux/<name>/` → 302 → `/chooser/?arg=<name>`
- A6. `GET /tmux/<name-with-slashes>/` → fall-through (regex won't capture)
- A7. `GET /playbook/` → 200, dashboard SPA
- A8. `GET /playbook/<name>/` → 200, that playbook's ttyd (when name exists)
- A9. `GET /<service>/*` → reverse-proxy to `proxy_to` host:port
- A10. `GET http://host` → 301 → `https://host`
- A11. Bind: `:443` and `:80` only, all backends bind 127.0.0.1
- A12. `--watch` reloads Caddyfile when re-rendered (with sentinels)

## B. Backend API (dashboard binary)

- B1. `GET /api/sessions` → `{sessions, playbooks, chooserUrl}`
- B2. `GET /api/services` → `{services: [...]}`
- B3. `POST /api/services` → 201, appends to services.json AND rewrites Caddyfile services block
- B4. `POST /api/services` with duplicate name → 409
- B5. `POST /api/services` with missing name/url → 400
- B6. `DELETE /api/services?name=X` → 204, removes from json AND Caddyfile
- B7. `DELETE /api/services?name=missing` → 404
- B8. `GET /api/processes` → `{processes: [{port, command, cmdline, user, bind, kind, serviceUrl?}]}`
- B9. `/api/processes` annotates kind as "kit" / "exposed" / "" correctly
- B10. `GET /api/system` → `{cpuPct, ramUsedGB, ramTotalGB, diskFreeGB, diskTotalGB, load1, uptimeSec, user, host, home}`
- B11. `/api/system` is cached for 3s (subsequent requests don't re-shell out)
- B12. `GET /api/status` → `{now, entries: [{playbook, running, lastActive, pid}]}`

## C. Dashboard SPA — global

- C1. `<title>` = "kit"
- C2. Header brand: `user@host:~ $ kit` (post-load)
- C3. Footer: keyboard hint
- C4. Tab strip: 5 tabs (webterm, services, storage, media, discover)
- C5. Default tab = webterm (no hash)
- C6. Hash deep-link: `#X` activates tab X for any X in the 5 names
- C7. Number keys `1`-`5` switch tabs (when not focused on input)
- C8. Click on tab activates it + updates URL hash
- C9. Inactive tab content is hidden (display:none)
- C10. SPA auto-refreshes data on tab regain visibility
- C11. SPA polls `/api/sessions` every 30s
- C12. SPA polls `/api/system` every 5s
- C13. SPA polls `/api/processes` every 30s

## D. Header system stat bar

- D1. CPU: shows N% with color (green/amber/red at 60/85)
- D2. Memory: shows used/totalG with color (70/90 of total)
- D3. Disk: shows N free with color (75/90 of total)
- D4. Load: shows N.NN with color (4/8 thresholds)
- D5. Uptime: shows Nd Nh / Nh Nm / Nm
- D6. Service tally: shows `Ns/Np/Nv` (sessions/playbooks/services counts)
- D7. All stats start as `—` and populate within 5s

## E. Webterm tab

- E1. Section: "Claude playbooks" with cards from `/api/sessions.playbooks`
- E2. Section: "tmux sessions" with cards from `/api/sessions.sessions`
- E3. "Open or create session" form
- E4. Submit form → navigate to `/chooser/?arg=<encoded-name>`
- E5. Empty state when no playbooks (with hint)
- E6. Empty state when no sessions (with hint)
- E7. Playbook card link: `/playbook/<name>/`
- E8. Session card link: `/chooser/?arg=<encoded-name>`
- E9. Card status dot: green when running/attached, gray otherwise
- E10. Card pill: "running" / "attached×N" / "idle"

## F. Services / Storage / Media tabs

- F1. Each tab shows cards filtered by `category` field
- F2. Default category = "services" if unset
- F3. Card href = service `url`
- F4. Card shows icon (emoji) + name + description + (proxy_to if set)
- F5. Empty state when no services for that category (with hint pointing at services.json)

## G. Discover tab

- G1. Process table: port, proc name, user, cmdline, action
- G2. Header row with column titles
- G3. Rows sorted: addable first, then exposed, then kit; secondary by port
- G4. `kit` rows: read-only, "webterm-kit" annotation
- G5. `exposed` rows: ✓ exposed link to service path
- G6. Addable rows: `+ add` button
- G7. Click `+ add` → inline form appears (name, category select, path)
- G8. Submit form → POST /api/services → row turns into "exposed"
- G9. Cancel button reverts to `+ add`
- G10. Form validates: name and path required

## H. Chooser TUI (Bubble Tea)

- H1. Lists tmux sessions
- H2. `p` toggles to playbooks view
- H3. Playbooks view: shows running/idle status + last-active
- H4. `enter` attaches to selected session/playbook
- H5. `n` opens new-session form
- H6. `r` refreshes
- H7. `q` quits
- H8. `s` opens shell
- H9. `k` (in playbooks) kills the playbook session

## I. Auto-attach mode (chooser argv)

- I1. URL `?arg=NAME` runs `tmux new -A -s NAME` immediately
- I2. URL-decoded `arg` (e.g. `claude%2Fwebterm-kit` → `claude/webterm-kit`)
- I3. After tmux exits cleanly, parks with message (no reconnect prompt)
- I4. Tab close sends SIGTERM → chooser exits cleanly

## J. Per-playbook ttyd

- J1. One ttyd per `~/.claude-playbooks/*/CLAUDE.md`
- J2. CLAUDE_CONFIG_DIR set before `tmux new -A`
- J3. `--base-path /playbook/<name>/` so WebSocket URLs resolve
- J4. Reattach inherits CLAUDE_CONFIG_DIR (env in tmux session env table)

## K. Operational

- K1. `install.sh` is idempotent
- K2. `install.sh` seeds `~/.config/webterm-kit/services.json` if missing
- K3. Generated Caddyfile contains BEGIN/END sentinels for the services block
- K4. ttyd font fallback chain (Menlo + Apple Symbols + emoji + Hiragino + …)
- K5. ttyd uses DOM renderer (per-character glyph fallback)
- K6. launchd plist sets `LANG=en_US.UTF-8` and `LC_ALL=en_US.UTF-8`
- K7. `~/.claude-profile/machines/<host>.md` written on every install

## [manual] tier-3 scenarios — see test/browser/scenarios.md

These need a human or AI agent (visual rendering, terminal interaction):
- A1: ttyd Ctrl-D → park message, no reconnect
- B1: Claude's `⏺ ✻ ※` glyphs render correctly
- B2: Turkish characters input/render
- C2: visiting a path-proxied service that breaks under prefix
- E1: CPU stress visibly bumps stat bar color
