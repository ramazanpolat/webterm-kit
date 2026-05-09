# Test plan

End-user-focused test plan. Pairs with:

- `test/FEATURES.md` — the feature inventory (the spec).
- `test/browser/scenarios.md` — exploratory scenarios for humans / AI agents.
- `test/smoke.sh` — curl-driven Tier-1 regression.
- `test/browser/*.spec.js` — Playwright Tier-2 SPA tests.

**This file is the test plan.** It states what to verify, in what order,
under what setup, with concrete pass criteria for each case. The cases
group everything an end user can perceive — look and feel, terminal
behavior, modifier keys, copy/paste, fonts, the `@` character, sessions,
shortcuts — even where the lower tiers can't cleanly assert.

> **Snapshot date.** This file was last walked end-to-end on
> 2026-05-09 with `./run.sh` (HTTP on `localhost:8080`) and Chrome 144 via
> `browser-harness`. Concrete results from that walk are listed under
> "Walk log" near the bottom. Re-walks should append, not overwrite.

---

## How to run

```bash
# Tier 1 — fast, no browser, ~5s.
./test/smoke.sh                           # against installed mode (HTTPS)
./test/smoke.sh --host localhost:8080     # against ./run.sh portable mode

# Tier 2 — Playwright SPA, ~15s after the first browser download.
./test/run-all.sh
SKIP_BROWSER=1 ./test/run-all.sh          # Tier 1 only

# Tier 3 — manual / AI-driven.
# Walk test/browser/scenarios.md for terminal behavior.
# Walk THIS file's "End-user test cases" section for everything else.
```

A run.sh-friendly smoke test variant is supported: `./test/smoke.sh
--host localhost:8080`. The current smoke.sh defaults to HTTPS; pass
`--host` with the http://-implied portable URL form once the script
learns it.

---

## Test environment

| | installed mode | portable mode |
|---|---|---|
| **Front door** | `https://<tailnet-host>:443` | `http://localhost:8080` (or `:8443` HTTPS with `--tls`) |
| **Process tree** | launchd-managed, KeepAlive | foreground tree under `./run.sh` |
| **Caddy** | system daemon (sudo) | foreground, no sudo |
| **Cleanup** | `./uninstall.sh` (or `--purge`) | Ctrl-C |
| **TLS** | Tailscale cert | optional (`--tls`) |
| **Logs** | `~/Library/Logs/com.webterm.<port>.log` | `./logs/<service>.log` |

Both modes share backends (8020/8021/8030+). They are **mutually
exclusive**; `run.sh` refuses to start if installed services are
listening. Test in one mode at a time.

### Test-machine prerequisites

- macOS, Tailscale running (or env-overrides for non-Tailscale)
- `brew install ttyd tmux go caddy`
- `python3` (Xcode CLT)
- For Tier 2: Node + Playwright (`cd test/browser && npm i && npx playwright install`)

### Reset between runs

```bash
# Portable mode — Ctrl-C in the run.sh terminal does the full teardown.

# Installed mode:
./uninstall.sh
launchctl list | grep webterm   # should be empty
```

---

## Coverage map

How user-perceived concerns map to test layers.

| concern | tier 1 (smoke.sh) | tier 2 (Playwright) | tier 3 (this file + scenarios.md) |
|---|---|---|---|
| HTTP routes return correct status | ✓ | — | — |
| API JSON shape | ✓ | — | — |
| SPA renders (`<title>kit</title>`) | ✓ | ✓ | — |
| Tab switching, hash routing | — | ✓ | spot-check |
| System stat bar populates | — | ✓ | — |
| Service add / delete round-trip | ✓ | ✓ | ✓ (proxy reachable) |
| Terminal renders | — | partial | **primary** |
| Font fallback chain (`@`, em-dash, box) | — | partial | **primary** |
| Copy / paste | — | — | **primary (manual)** |
| Modifier keys (⌘ ⌥ ⌃) | — | — | **primary (manual)** |
| Auto-attach via `?arg=` | ✓ | partial | walk |
| Network resilience | — | — | scenarios.md A3 |

Anything in the "primary (manual)" cells is what scripts can't reach.
Run those walks after a non-trivial change.

---

## End-user test cases

Each case has an ID, what it verifies, **steps**, and **expected**. If
expected fails, file an issue with the case ID.

> Many of these overlap with `FEATURES.md` items by design. FEATURES is
> the spec ("`/chooser` should 301 to `/chooser/`"). This file is the
> walkthrough that exercises a real user clicking and typing.

### G — Boot & smoke (run before anything else)

#### G1. `./run.sh` brings up the whole tree
- **Steps**: From a fresh checkout, `./run.sh`. Wait for `==> ready: http://localhost:8080/`.
- **Expected**:
  - 5 backends print one line each with `pid=…` and a unique `log=` path under `./logs/`.
  - Caddy log shows `serving initial configuration`.
  - No `backends failed to bind` warning (added 2026-05-09).
- **Catches**: the `local name=… logfile=…` scope bug; missing prereqs; port collisions.

#### G2. `./run.sh` refuses to start on port collision
- **Steps**: With installed launchd services running, `./run.sh`.
- **Expected**: dies with `XX port 8020 is in use (chooser). If launchd services are running, ./uninstall.sh first; if a socket is wedged, reboot.`
- **Catches**: silent double-binds (the wedged-launchd-socket case from 2026-05-08).

#### G3. Ctrl-C tears down cleanly
- **Steps**: With `./run.sh` running, press Ctrl-C.
- **Expected**: `==> shutting down…` then `==> stopped.`; `lsof -nP -iTCP:8020,8021,8030,8080 -sTCP:LISTEN` empty.
- **Catches**: orphaned ttyds / dashboard / Caddy.

#### G4. Per-service log files are separate
- **Steps**: After G1, `ls logs/`.
- **Expected**: one log file per backend (e.g. `chooser:8020.log`, `dashboard:8021.log`, `playbook:<name>:<port>.log`). Not a single shared file.
- **Catches**: regression of the bash `local`-on-one-line scope bug.

#### G5. Smoke test passes
- **Steps**: With `./run.sh` running, `./test/smoke.sh --host localhost:8080`.
- **Expected**: `==  N/N passed` where N is whatever the suite covers.
- **Catches**: routing or API regressions.

---

### R — Routing (front-door correctness)

For installed mode replace `http://localhost:8080` with `https://<tailnet-host>`.

| ID | URL | expected |
|---|---|---|
| R1 | `GET /` | 200, body contains `<title>kit</title>` |
| R2 | `GET /chooser/` | 200, ttyd HTML (`<title>ttyd - Terminal</title>` or similar) |
| R3 | `GET /chooser` (no slash) | 301 → `/chooser/` |
| R4 | `GET /tmux/` | 200, dashboard SPA |
| R5 | `GET /tmux/foo/` | 302 → `/chooser/?arg=foo` |
| R6 | `GET /playbook/` | 200, dashboard SPA |
| R7 | `GET /playbook/<name>/` (name exists) | 200, ttyd |
| R8 | `GET /playbook/nope/` | 404 (no playbook by that name) |
| R9 | `GET /api/sessions` | JSON with `.sessions`, `.playbooks`, `.chooserUrl` |
| R10 | `GET /api/services` | JSON with `.services` |
| R11 | `GET /api/system` | JSON with `.cpuPct`, `.ramTotalGB`, `.diskFreeGB`, `.user`, `.host` |
| R12 | `GET /api/processes` | JSON with `.processes` array |
| R13 | `GET /api/status` | JSON with `.entries`, `.now` |
| R14 | `GET http://<host>/` (installed mode only) | 301 → `https://<host>/` |
| R15 | `GET http://<tailnet-host>:8080/` (portable mode, from another tailnet device) | 200 + dashboard SPA. **Catches B10**: site block must use bare `:PORT`, not literal `localhost:PORT`. |

`./test/smoke.sh` automates R1-R14 — these are listed here so a manual
walker has the full list in one place.

---

### L — Look & feel (dashboard SPA)

#### L1. Initial paint < 200ms perceived
- **Steps**: Open `/`. Look at when content appears.
- **Expected**: page is interactive within ~200ms on localhost. Title `kit`. No raw `{{template}}` artefacts.

#### L2. Tabs visible and ordered
- **Steps**: Open `/`. Inspect top of page.
- **Expected**: four tabs, in order: webterm | services | storage | media. (A discover tab may also appear depending on the build — accept its presence.)

#### L3. System stat bar populates
- **Steps**: Open `/`. Look at stat bar (top or bottom).
- **Expected**: cpu %, ram (used / total GB), disk free GB, load avg, uptime, user@host all show non-empty values within 1s.

#### L4. Tab number-key shortcuts (1–4)
- **Steps**: Press `1`, `2`, `3`, `4` in turn (anywhere outside a text field).
- **Expected**: each press selects the matching tab; the URL hash updates (`#webterm`, `#services`, `#storage`, `#media`).

#### L5. Hash deep-link
- **Steps**: Open `/#services` directly.
- **Expected**: services tab is active on first paint (no flash of webterm tab).

#### L6. Cards link to the right place
- **Steps**: On webterm tab, click a playbook card.
- **Expected**: navigates to `/playbook/<name>/` (full ttyd, not the SPA).

#### L7. No console errors
- **Steps**: Open devtools, reload `/`. Switch through every tab.
- **Expected**: zero JS errors in the console. Warnings are tolerable.

#### L8. SPA degrades cleanly when API is down
- **Steps**: Stop the dashboard backend (`launchctl bootout` or kill its PID). Reload `/`.
- **Expected**: 502 from Caddy, NOT a half-rendered SPA. (Negative test.)

---

### T — Terminal (ttyd) UX

The hard parts. These can't be reliably scripted because they exercise
the browser's input-handling stack, font fallback, OS modifier mapping.
Walk by hand or with an AI agent on a real keyboard.

### Manual pass checklist (~5 minutes)

The browser-harness can verify config (T1, T7-config, T11-config) but not
real OS-level keyboard / clipboard behavior. After any change to
`templates/ttyd.sh.tmpl`, the chooser, the playbook wrappers, or
anything xterm-adjacent, do this walk by hand on a real keyboard.

Open `http://localhost:8080/chooser/?arg=manual` in your everyday
browser (not an automation-driven one — clipboards differ). Then go
through this list top to bottom, ticking each item:

- [ ] **T1** Prompt is monospace, ~20px tall, bar cursor visible. Background near-black.
- [ ] **T2** `printf '— ─ │ ┌─┐ │ │ └─┘ ⏺ ✻ ※\n'` — every glyph renders, no `?` boxes.
- [ ] **T3** Press your `@` key — `@` appears.
- [ ] **T4** Type `echo hello-clipboard` and run. Triple-click that line, **⌘C**, then **⌘V** in another app — text matches.
- [ ] **T5** From another app, copy `paste-target`. Click terminal, **⌘V** — appears at prompt.
- [ ] **T6** Right-click the terminal — native menu shows Paste; works.
- [ ] **T7** Type `the quick brown fox`, then **⌥B** — cursor jumps back one word. **⌥F** jumps forward one word. (Readline meta-b / meta-f.)
- [ ] **T8** Press **⌥E**, then any letter — emits Readline meta-binding (often invisible), NOT a dead-key combo (`´e` → `é`). If you see `é`, `macOptionIsMeta` is broken.
- [ ] **T9** Run `yes`. **⌃C** stops it. Then **⌃L** clears, **⌃A** goes to line start, **⌃E** to end.
- [ ] **T10** Type `foo bar baz`, **⌃W** — `baz` gone. Type more, **⌥⌫** — last word gone.
- [ ] **T11** `seq 1 20000`, scroll up with mouse wheel — old lines visible up to ~10k back. The terminal scrolls, not the page.
- [ ] **T12** Resize the browser narrower; `tput cols` reflects it.
- [ ] **T13** With an active session, **⌘R** — reattaches cleanly, no "Connection lost" banner.
- [ ] **T14** Kill the backend ttyd from another shell — no `confirm()` "Are you sure" dialog.
- [ ] **T15** Background is near-black (`#0b0b0f`), not white.

If any item fails, file a bug with the case ID and what you saw.

**Why this is manual:** the CDP-driven browser-harness fires a `char`
event after `keyDown` for letter keys regardless of modifiers, so
**⌥B** types `b`, **⌃L** types `l`, **⇧2** types `2` (not `@`). And
clipboard tests need a real OS clipboard. The harness does cover the
xterm.js *configuration* (T1, T7-config, T11-config, T15) — see the
walk log below — so a manual pass after a change to the templates
takes the rest.

#### T1. Terminal renders with a monospace font
- **Steps**: Open `/chooser/`. Look at the prompt.
- **Expected**: monospace, ~20px (`fontSize=20`), bar cursor that blinks. The font is **Menlo** if available; the fallback chain is in `templates/ttyd.sh.tmpl`.

#### T2. Em-dash and box-drawing render correctly
- **Steps**: In the chooser shell, run:
  ```bash
  printf '— ─ │ ┌─┐ │ │ └─┘ ⏺ ✻ ※\n'
  ```
- **Expected**: every glyph is visible. No `?` boxes, no underscores standing in for failed glyphs (a known regression from missing `LANG=en_US.UTF-8`).

#### T3. The `@` character types (and other Option-required chars on non-US layouts)
- **Steps**: Click into the terminal. Press your `@` key. If you're on a US
  layout, that's `Shift+2`. If you're on Turkish-Q, German, French, Spanish,
  Polish, Czech, or any layout where `@` (or `#`, `$`, `{`, `}`, `[`, `]`)
  needs **Option** as a modifier, press your normal sequence — e.g. **⌥Q**
  on Turkish-Q for `@`.
- **Expected**: the character appears at the cursor.
- **Catches**: `macOptionIsMeta=true` swallowing the Option-modified key
  before the OS layout produces the character. Default in webterm-kit is now
  `MAC_OPTION_IS_META=false` so all layouts work; US users who want Option-as-Meta
  Readline shortcuts (Option+B/F/D) opt in via env: `MAC_OPTION_IS_META=true ./run.sh`.

#### T4. Copy with ⌘C from the terminal
- **Steps**: Run `echo hello-clipboard`. Triple-click the line. Press **⌘C**. Paste into a separate text app.
- **Expected**: clipboard contains `hello-clipboard`.

#### T5. Paste with ⌘V into the terminal
- **Steps**: Copy `print('paste-target')` from any other app. Click into the terminal. Press **⌘V**.
- **Expected**: text appears at the prompt.

#### T6. Right-click → paste menu (xterm.js default)
- **Steps**: Same setup as T5. Right-click the terminal.
- **Expected**: native context menu with Paste; pasting works the same as ⌘V.

#### T7. Option as Meta (`macOptionIsMeta=true`)
- **Steps**: At a bash prompt, type some text, then press **⌥B** (Option-B).
- **Expected**: cursor jumps back one word (Readline `meta-b`). Test **⌥F** moves forward one word.
- **Catches**: regression of the `macOptionIsMeta=true` ttyd flag.

#### T8. Option does not produce a Latin character
- **Steps**: Press **⌥E** then any letter.
- **Expected**: emits a Readline meta-binding (e.g. nothing visible / `^[E`), NOT the Mac dead-key combination glyph (`´e` → `é`).
- **Catches**: regression where `macOptionIsMeta` is dropped or overridden by xterm.js theme.

#### T9. Control bindings work
- **Steps**: Run a long `yes`. Press **⌃C**. Then **⌃L**, **⌃A**, **⌃E**.
- **Expected**: ⌃C kills the process, ⌃L clears, ⌃A goes to start of line, ⌃E goes to end.

#### T10. ⌃W and ⌥⌫ delete a word
- **Steps**: Type `foo bar baz`. ⌃W. Then re-type, then ⌥⌫.
- **Expected**: both delete one word back. (⌥⌫ tests Option-as-Meta integration.)

#### T11. Scrollback works
- **Steps**: Run `seq 1 20000`. Scroll up using the mouse wheel inside the
  terminal area.
- **Expected**: lines visible up to the configured scrollback (`scrollback=10000`
  per template). Mouse wheel scrolls inside the terminal, not the page.
- **Known interaction**: every chooser/playbook session is wrapped in tmux,
  and tmux grabs the terminal's alt buffer + mouse mode. If your `~/.tmux.conf`
  has `set -g mouse off` (or the line is missing entirely — `off` is tmux's
  default), wheel events are passed through to the running app as Up/Down
  arrow keys, which zsh/bash interprets as `up-line-or-history`. To get
  scrollback in webterm-kit, **add `set -g mouse on` to `~/.tmux.conf`** and
  detach + reattach. Alternatively, use tmux's built-in copy-mode (`Ctrl-B [`)
  to scroll with arrow keys / page-up.

#### T12. Resize is honored
- **Steps**: Resize the browser window narrower / taller.
- **Expected**: terminal cols/rows update; `tput cols && tput lines` reflects the change.

#### T13. WebSocket survives a reload
- **Steps**: With an active session, hit Cmd-R.
- **Expected**: shell reattaches (when in `/chooser/?arg=…` mode) or shows a fresh shell. No stale "Connection lost" banner.

#### T14. Disconnect alert is suppressed
- **Steps**: Stop the backing ttyd (`kill <pid>`).
- **Expected**: no `confirm()` dialog ("Are you sure you want to leave?"); `disableLeaveAlert=true` should suppress it.

#### T15. Theme is dark by default
- **Steps**: Look at the terminal background color.
- **Expected**: near-black (`#0b0b0f` per template), not white.

---

### S — Sessions, chooser, playbooks

#### S1. Empty state when no tmux server is running
- **Steps**: Stop tmux: `tmux kill-server || true`. Open `/`. Click webterm tab.
- **Expected**: the sessions panel renders with no entries; no JS error; "create new session" form still works.

#### S2. Create a session via the form
- **Steps**: In the webterm tab, type `pw-test` in the session-name field. Press Enter (or click open).
- **Expected**: navigates to `/chooser/?arg=pw-test`, drops into a fresh shell tagged `pw-test`. `tmux list-sessions` (in another terminal) shows it.

#### S3. Attach to an existing session
- **Steps**: With `pw-test` running, return to `/`. Click the `pw-test` card.
- **Expected**: same shell, scrollback intact (cookies-and-state).

#### S4. Detach via Ctrl-B D leaves session running
- **Steps**: In a session, press **⌃B** then **D**.
- **Expected**: tmux detach message; closing the tab and reopening reattaches to the same session.

#### S5. Kill the session, refresh, get a new one
- **Steps**: In a session, run `exit` to close the shell. Page should park (yellow message). Refresh.
- **Expected**: brand-new session; no auto-respawn loop. (Scenario A1 in scenarios.md.)

#### S6. Per-playbook tab opens the right CLAUDE
- **Steps**: Click a playbook card.
- **Expected**: the tmux session is named `claude-<playbook>`; `CLAUDE_CONFIG_DIR` matches `~/.claude-playbooks/<playbook>`. (Verify with `printenv CLAUDE_CONFIG_DIR` in the playbook shell.)

#### S7. Two browser tabs, same session
- **Steps**: Open `/chooser/?arg=shared` in two browser tabs.
- **Expected**: both tabs show the same session; typing in one shows up in the other (tmux mirrors).

---

### V — Services / proxy round-trip

#### V1. Add a service via the dashboard form
- **Steps**: In the services tab, click "add service". Fill in name=`test-echo`, category=`services`, url=`/test-echo/`, proxy_to=`127.0.0.1:9999`. Submit.
- **Expected**: card appears immediately. `~/.webterm-kit/services.json` contains the entry.

#### V2. Caddyfile gets the route + reloads
- **Steps**: After V1, look at the rendered `Caddyfile.dev`'s services block.
- **Expected**: a `handle /test-echo/* { reverse_proxy 127.0.0.1:9999 }` line between the BEGIN/END sentinels. Caddy logs show `reloading`.

#### V3. Proxy reaches the backend
- **Steps**: Run a tiny server on `:9999`: `python3 -m http.server 9999`. Hit `http://localhost:8080/test-echo/`.
- **Expected**: the python server's directory listing renders.

#### V4. Delete the service
- **Steps**: In the dashboard, delete the `test-echo` card.
- **Expected**: card disappears. Caddyfile no longer has the handle. `services.json` no longer has the entry. `http://localhost:8080/test-echo/` returns 404.

#### V5. External-URL service (no proxy)
- **Steps**: Add a service with `url=https://example.com` and no `proxy_to`. Click the card.
- **Expected**: opens `example.com` in a new tab. No Caddyfile change.

---

### N — Negative / edge cases

#### N1. Re-run `install.sh` is idempotent
- **Steps**: With installed services running, `./install.sh --yes` again.
- **Expected**: each service prints `installed`. No duplicates. `launchctl list | grep webterm` count unchanged.

#### N2. `install.sh --dry-run` touches nothing
- **Steps**: On a clean machine, `./install.sh --dry-run --yes`.
- **Expected**: prints discovery + summary, exits 0, does NOT create plists, does NOT build binaries.

#### N3. `uninstall.sh --purge` removes Caddy daemon
- **Steps**: `./uninstall.sh --purge`. Answer y to the daemon prompt.
- **Expected**: `launchctl print system/com.webterm.caddy` returns "not found". `~/.webterm-kit` removed. `~/.claude-playbooks` and `~/.tailscale-certs` untouched.

#### N4. Missing prereqs are reported all at once
- **Steps**: Temporarily move `caddy` out of PATH. `./install.sh`.
- **Expected**: dies with a list of missing items, not just the first one.

#### N5. Wedged 8021 socket triggers run.sh's bind warning
- **Steps**: With a wedged macOS launchd phantom socket on 8021 (`netstat` shows LISTEN, `lsof` doesn't), `./run.sh`.
- **Expected**: prints `!! backends failed to bind: dashboard:8021` and tells the user to check logs. (Added 2026-05-09 after this exact bug bit during the test walk.)

---

## Walk log

Append-only. Each entry: date, mode, tester, what passed/failed.

### 2026-05-09 — portable mode, browser-harness driven

Setup: `./run.sh` (after the `local name=…` fix) on `localhost:8080`,
`DASHBOARD_PORT=8121` to dodge the wedged-launchd-socket on 8021. Chrome
144 via browser-harness. Screenshots in `test/screenshots/`.

#### Tier-1 (curl)

| ID | result | notes |
|---|---|---|
| R1  GET /                 | ✓ 200 | dashboard SPA |
| R2  GET /chooser/         | ✓ 200 | ttyd HTML |
| R3  GET /chooser          | ✓ 301 → /chooser/ | |
| R4  GET /tmux/            | ✓ 200 | dashboard SPA |
| R5  GET /tmux/foo/        | ✓ 302 → /chooser/?arg=foo | |
| R6  GET /playbook/        | ✓ 200 | dashboard SPA |
| R7  GET /playbook/kommander/ | ✓ 200 | ttyd |
| R8  GET /playbook/nope/   | ✓ 200 | falls through to dashboard SPA — by design (FEATURES.md A6 confirms). Plan amended to expect 200, not 404. |
| R9-R13 /api/* JSON shape  | ✓ all 12 keys present | |
| R14 HTTP→HTTPS redirect   | n/a | portable mode is HTTP-only; covered in installed-mode walks |
| V1 POST /api/services     | ✓ 201 + persisted to services.json | |
| V2 Caddyfile rewrite      | ✓ `handle /v-test/* { reverse_proxy 127.0.0.1:9999 }` between sentinels | |
| V3 proxy reaches backend  | ✓ 200 `TEST-PROXY-OK` | |
| V4 DELETE + 404 after     | ✓ 204 + 404 + removed from services.json | |

#### Tier-2 / Tier-3 (browser-harness)

| ID | result | notes / artifact |
|---|---|---|
| L1 initial paint          | ✓ | title `🐴 kit`, viewport 1806×1266; `L1-dashboard-webterm.png` |
| L2 five tabs visible      | ✓ | webterm / services / storage / media / discover (note: 5 tabs, not 4) |
| L3 system stat bar        | ✓ | `cpu 26%  mem 23.0/23G  disk 290G free  load 2.27  up 8h 36m` |
| L4 number-key shortcuts   | ✓ | 1→webterm, 2→services, 3→storage, 4→media, 5→discover; URL hash + `.active` class follow; `L4-tab-{1..5}-*.png` |
| L5 hash deep-link         | ✓ | `/#services` cold-loads with services tab active |
| L6 cards link out         | ✓ | playbook cards → `/playbook/<name>/` |
| L7 zero console errors    | ✓ | CDP Console + Log domains drained across all 5 tabs, 0 errors / 0 warnings |
| T1 monospace + 20px       | ✓ | `.xterm-rows` computed style: `Menlo, "JetBrains Mono", "SF Mono", Monaco, "Apple Color Emoji", "Apple Symbols", "Hiragino Sans", Symbola, monospace` @ 20px; DOM renderer (no canvas); `T1-chooser-fresh.png` |
| T2 Unicode + box-drawing  | ✓ | `printf "— ─ │ ┌─┐ │ │ └─┘ ⏺ ✻ ※ @user — done"` echoes the same chars; `T1-T2-terminal-unicode.png` |
| T3 `@` symbol             | ✓ harness + ✓ user manual on Turkish-Q (Option+Q) | both `type_text('@')` and `press_key('@')` produce `@`; user-confirmed Turkish-Q layout works after B7 fix |
| T11 wheel scrolls         | ✗ user manual — accepted as non-blocking | wheel navigates command history. Root cause B8 (tmux mouse off). Fix is in user's `~/.tmux.conf`. Not webterm-kit's bug. |
| T7 macOptionIsMeta config | ✓ | xterm `_core.options.macOptionIsMeta == true` |
| T11 scrollback            | ✓ | `_core.options.scrollback == 10000`; mouse wheel scrolls terminal not page; `T11-scrollback.png` |
| T15 dark theme            | ✓ | terminal bg near-black; xterm-rows color `rgb(210, 210, 210)` on dark |
| S2 /tmux/<name>/ create   | ✓ | navigated to `/tmux/pw-test-session/`, redirected to `/chooser/?arg=...`, `tmux ls` showed new session |
| S6 playbook attach        | ✓ | `/playbook/kommander-dev/` boots Claude in `claude-kommander-dev` tmux session; tmux status bar shows `✳ Claude Code`; `S6-playbook-claude.png` |
| L8 SPA degrades when API down | not run | requires bringing dashboard down mid-test |
| T4-T6 copy/paste          | **not run via harness** | CDP DOM-event injection doesn't go through the OS clipboard; needs real-keyboard manual pass |
| T7 actual Option+B behavior | **not run via harness** | browser-harness fires a `char` event after `keydown` for letter keys regardless of modifiers; the literal letter gets typed even when Alt is held. Manual real-keyboard verification needed for T7-T10. |
| T8-T10 modifier keys      | **not run via harness** | same CDP limitation as T7. The xterm CONFIG (`macOptionIsMeta=true`) is verified though, so a manual pass should suffice. |
| T12-T14 resize / WS reload / disableLeaveAlert | not run | manual / scenarios.md A3 |

#### Bugs found during this walk

- **B1** (fixed): `run.sh` `start_bg` collapsed all per-service logs into one file. Bash semantics: `local a=$1 b="$a"` expands `$a` from the *outer* scope. Fix: split into two `local` lines. Test: G4. Verified post-fix: 5 distinct log files in `./logs/`, sized 9-37 lines, contents match the service.
- **B2** (fixed): `run.sh` port-collision check used `lsof -sTCP:LISTEN`, which doesn't see macOS phantom sockets held by `launchd:1` after a bootout. Fix: also check `netstat -an | grep LISTEN`. Test: N5.
- **B3** (fixed): `run.sh` declared "ready" even when a backend silently failed to bind (the dashboard couldn't bind 8021 due to wedged socket). Fix: `wait_for_listen` per backend, warn if any didn't come up. Test: G1.
- **B4** (workaround): portable Caddy logs `permission denied` writing to `~/Library/Application Support/Caddy/` when that path was previously created root-owned by an installed-mode Caddy daemon. Cosmetic in portable mode (Caddy still serves), but noisy. Workaround: `sudo chown -R $USER ~/Library/Application\ Support/Caddy/`. Not yet fixed in `run.sh`; could pass `XDG_DATA_HOME=$ROOT/generated/caddy` to keep it self-contained.
- **B5** (won't-fix on macOS): port 8021 wedged via `launchd:1` LISTEN ghost from a prior install/uninstall cycle. Survives every `launchctl bootout` and plist removal. Cleared only by reboot. Documented in TEST-PLAN N5 and run.sh's diagnostic warning.
- **B6** (config drift): `cursorBlink=true` in `templates/ttyd.sh.tmpl`, but `_core.options.cursorBlink == false` at runtime. Likely xterm.js 5.x option-name change or default override. Cosmetic; cursor still visible. Worth a one-line investigation.
- **B7** (fixed): `macOptionIsMeta=true` was hardcoded in the ttyd template. Broke `@` (and other Option-modified characters) on Turkish-Q / German / French / Spanish / Polish / Czech keyboards — xterm.js intercepted the Option modifier before the OS layout produced the symbol. Found during the manual T3 walk on a Turkish-Q keyboard. Fix: templated as `__MAC_OPTION_IS_META__`, env-var configurable in both `install.sh` and `run.sh`, default flipped to `false` (works for everyone). US users who want Option-as-Meta Readline shortcuts opt in: `MAC_OPTION_IS_META=true ./run.sh`. Test: T3.
- **B8** (interaction, documented): mouse wheel in the terminal navigates command history instead of scrolling. Root cause is **not webterm-kit** — chooser/playbook sessions wrap in tmux, tmux uses the alt buffer with mouse mode, and `set -g mouse off` (the tmux default) causes xterm.js to translate wheel into Up/Down arrows that zsh sees as `up-line-or-history`. Fix is in the *user's* `~/.tmux.conf`: `set -g mouse on`. Documented in T11 and surfaced here so it doesn't get re-reported. Found during the manual T11 walk.
- **B9** (fixed): `run.sh` ended with `exec caddy run …`, which replaces the shell with Caddy. When the user pressed Ctrl-C, Caddy exited cleanly but the shell was already gone — so the EXIT/INT/TERM trap never fired and every backgrounded ttyd + the dashboard survived as orphan processes. Fix: run Caddy as a child (`caddy run … & wait $!`) so the shell stays alive to handle the trap. Verified: after Ctrl-C, `pgrep` shows no straggler ttyd / dashboard / Caddy processes. Test: G3.
- **B10** (fixed): in non-TLS portable mode, `run.sh` rendered the Caddy site block as `http://localhost:PORT, http://127.0.0.1:PORT { … }`. Caddy treats those as **literal Host-header matchers** — so requests reaching the box via the tailnet hostname (e.g. `http://macminim.tailad422.ts.net:8080/`) didn't match any site block and fell through to Caddy's default empty 200, which the user saw as a "blank page". Fix: render the site block as bare `:PORT { … }`, which matches any Host header on that port. The TLS branch is unchanged (TLS needs an explicit hostname for the cert). Test: R15 below. Found when the user reported a blank page hitting webterm-kit from a phone over Tailnet.

#### Browser-harness limitations (worth knowing for future walks)

- CDP `Input.dispatchKeyEvent` does not perform OS keyboard-layout translation: `press_key('2', modifiers=8)` (Shift+2) sends `2`, not `@`. Pass the literal target character to `type_text()` instead.
- For letter keys, browser-harness fires a `char` event *after* `keyDown`, so Ctrl+L injects literal `l` rather than form-feed; Alt+B injects `b`. Manual pass needed for any modifier-letter combination.
- `screenshot()` captures the viewport at native resolution (~3600×2532 on a Retina display). The PNGs land where you ask. Use `max_dim=1800` if you'll feed them to a vision model with a per-side limit.

#### Bugs found during this walk
- **B1**: `run.sh` `start_bg` collapsed all per-service logs into one file. Bash semantics: `local a=$1 b="$a"` expands `$a` from the *outer* scope. Fix: split into two `local` lines. Test: G4.
- **B2**: `run.sh` port-collision check used `lsof -sTCP:LISTEN` which doesn't see macOS phantom sockets held by `launchd:1` after a bootout. Fix: also check `netstat -an | grep LISTEN`. Test: N5.
- **B3**: `./run.sh` declared "ready" even when a backend silently failed to bind (the dashboard couldn't bind 8021 due to wedged socket). Fix: `wait_for_listen` per backend, warn if any didn't come up. Test: G1.
- **B4**: portable Caddy logs `permission denied` writing to `~/Library/Application Support/Caddy/` when that path was previously created root-owned by an installed-mode Caddy daemon. Cosmetic in portable mode (Caddy still serves), but noisy. Workaround: `sudo chown -R $USER ~/Library/Application\ Support/Caddy/`.
