# CODEWIKI

Code-level reference. Where things live, what they do, how to find what
you need. Snapshot: `main` (post `v3-launcher` merge + portable `run.sh`).
Pairs with `CLAUDE.md` (narrative / "why") and `PROJECT.md` (status).

---

## Repository layout

```
webterm-kit/
├── run.sh                     # portable runner: foreground process tree, Ctrl-C stops
├── install.sh                 # installed mode: render templates → bootstrap launchd
├── uninstall.sh               # tear down launchd services + generated/, --purge for full
├── README.md                  # 30-second pitch
├── CLAUDE.md                  # narrative guide for Claude Code in this repo
├── LICENSE                    # MIT
├── docs/
│   ├── PROJECT.md             # project status / roadmap / decisions
│   ├── CODEWIKI.md            # this file
│   └── DESIGN.md              # UI redesign brief
├── services.example.json      # schema example for ~/.config/webterm-kit/services.json
│
├── chooser/                   # Bubble Tea TUI session picker
│   ├── go.mod
│   └── main.go                # ~500 lines, single-file
│
├── dashboard/                 # Go HTTP API + embedded SPA
│   ├── go.mod                 # stdlib-only (no go.sum)
│   ├── main.go                # ~880 lines, single-file
│   └── static/
│       └── index.html         # ~730 lines, vanilla JS + CSS, embedded via go:embed
│
├── templates/                 # rendered into generated/ by install.sh
│   ├── ttyd.sh.tmpl           # per-ttyd wrapper script (chooser + per-playbook)
│   ├── launchd.plist.tmpl     # user LaunchAgent plist (one per service)
│   ├── dashboard.sh.tmpl      # dashboard binary wrapper
│   ├── Caddyfile.tmpl         # Caddy config (TLS terminator + path router)
│   └── caddy.plist.tmpl       # SYSTEM LaunchDaemon for Caddy (sudo to install)
│
├── generated/                 # gitignored; install.sh writes here
│   ├── ttyd-<name>.sh         # one per ttyd service
│   ├── claude-<playbook>.sh   # per-playbook tmux+Claude wrapper
│   ├── dashboard.sh           # dashboard launch script
│   ├── Caddyfile              # rendered Caddy config (Caddy reads this)
│   └── com.webterm.caddy.plist  # system daemon plist (user installs via sudo)
│
└── test/                      # see test/FEATURES.md for what's tested
    ├── smoke.sh               # tier 1: curl-driven, ~5 sec, no deps
    ├── run-all.sh             # tier 1+2 wrapper
    ├── exhaustive.sh          # tier 2 deep walk + real backend setup
    ├── FEATURES.md            # feature inventory ↔ test mapping
    └── browser/               # Playwright (chromium-headless via CDP)
        ├── package.json
        ├── playwright.config.js
        ├── *.spec.js          # regression specs (api, dashboard, page-modes, etc.)
        ├── exhaustive.spec.js # gated by INCLUDE_EXTENDED=1
        ├── explore.spec.js    # screenshot tour, gated by INCLUDE_EXTENDED=1
        └── scenarios.md       # tier 3 manual / AI walkthrough
```

---

## Runtime topology

```
┌─────────── tailnet ───────────┐
│ browser → https://host/        │
└──────────────┬─────────────────┘
               │
       ┌───────▼────────┐
       │  Caddy :443    │  TLS terminator + path router
       │  (system daemon, sudo to install)
       │  reads generated/Caddyfile, --watch + admin API on :2019
       └───────┬────────┘
               │ all backends bind 127.0.0.1
       ┌───────┼────────────┬──────────────┬──────────────┐
       │       │            │              │              │
   /            /chooser/   /playbook/     /<service>/    /api/*
   :8025        :8020       <name>/        (proxy_to)
   dashboard    chooser     :8030+         arbitrary
   (Go HTTP)    (ttyd→chooser
                Bubble Tea TUI)
                              ttyd→tmux→claude
                              one per playbook
```

System (root) daemons: **Caddy** only. Everything else is user LaunchAgents
labeled `com.webterm.<port>`.

---

## Ports

Fixed (never change):

| port | label | what |
|---|---|---|
| 80, 443 | (system) com.webterm.caddy | Caddy TLS terminator + path router |
| 8020 | com.webterm.8020 | chooser ttyd (Bubble Tea TUI) |
| 8021 default | com.webterm.<port> | dashboard (env override: `DASHBOARD_PORT`) |
| 2019 | (Caddy admin) | localhost-only — used by dashboard for `caddy reload` |

Allocated (one per item):

| port range | what |
|---|---|
| 8030, 8031, 8032… | per-playbook ttyds (one per `~/.claude-playbooks/*/CLAUDE.md`) |

Per-service routes added by the user via `/api/services` POST or by editing
`~/.config/webterm-kit/services.json` use whatever `proxy_to` they declare.

---

## Caddy routing (templates/Caddyfile.tmpl)

```
http://host  → 301 → https://host
https://host /chooser/*       → 127.0.0.1:8020 (ttyd)
                /chooser      → 301 → /chooser/
                /tmux/<name>/ → 302 → /chooser/?arg=<name>
                /tmux/        → falls through to dashboard
                /playbook/<name>/* → 127.0.0.1:803x (per-playbook ttyd)
                /playbook/    → falls through to dashboard
                /api/*        → 127.0.0.1:8025 (dashboard)
                /<service>/*  → 127.0.0.1:<proxy_to> (per services.json)
                /             → 127.0.0.1:8025 (dashboard, catch-all)
```

The dashboard-managed services block is wrapped in sentinels so the dashboard
can rewrite just that region:

```
# === BEGIN: webterm-kit auto-generated services ===
... handle /<service>/* { reverse_proxy ... } per service ...
# === END: webterm-kit auto-generated services ===
```

---

## API (`dashboard/main.go`)

| method | path | request | response | source |
|---|---|---|---|---|
| GET | `/api/sessions` | — | `{sessions, playbooks, chooserUrl}` | `tmux list-sessions/list-panes` + `~/.claude-playbooks/*` |
| GET | `/api/services` | — | `{services: Service[]}` | `~/.config/webterm-kit/services.json` |
| POST | `/api/services` | `Service` | 201 / 400 / 409 | appends + rewrites Caddyfile services block + `caddy reload` |
| DELETE | `/api/services?name=X` | — | 204 / 400 / 404 | removes + rewrites Caddyfile + `caddy reload` |
| GET | `/api/processes` | — | `{processes: Process[]}` with kind+protocol annotations | `lsof -nP -iTCP -sTCP:LISTEN` + `ps -o command=` + HTTP/HTTPS probe |
| GET | `/api/system` | — | `SystemStats` | `top -l 1 -n 0 -s 0` + `df` + `sysctl` |
| GET | `/api/status` | — | `{now, entries: StatusEntry[]}` | playbooks × tmux pids |

All JSON. All cached where it matters (system stats 3s, protocol probes 60s).

### Data shapes

```go
// dashboard/main.go
type Session   struct { Name string; Attached, Windows int; Panes []Pane }
type Pane      struct { Window, Pane int; Command, Title string }
type Playbook  struct { Name string; Running bool; LastActive int64; URL string }
type Service   struct { Name, Description, Category, Icon, URL, ProxyTo string }
type Process   struct { PID, Port int; Command, Cmdline, User, Bind, Kind, ServiceURL, Protocol string }
type SystemStats   struct { CPUPercent, RAMUsedGB, RAMTotalGB, DiskFreeGB, DiskTotalGB, Load1 float64; UptimeSec int64; User, Host, Home string }
type StatusEntry   struct { Playbook string; Running bool; LastActive int64; PID int }
```

`Process.Kind` values: `""` (addable), `"kit"` (webterm-kit's own infra),
`"exposed"` (already in services.json — port matched).

`Process.Protocol` values: `"http"`, `"https"`, `"unknown"` (probe via plain
GET / + TLS handshake fallback, 200ms timeout, 60s cache per pid:port).

---

## Config files

### `~/.config/webterm-kit/services.json`

Auto-seeded by `install.sh` if missing. Schema:

```json
{
  "services": [
    {
      "name": "jellyfin",                 // required, unique
      "description": "media server",      // optional
      "category": "media",                // services|storage|media (default: services)
      "icon": "🎬",                       // optional emoji
      "url": "/jellyfin/",                // required to be useful
      "proxy_to": "127.0.0.1:8096"        // optional — if set + url is /path/, install.sh / dashboard add a Caddy reverse_proxy block
    }
  ]
}
```

`services.example.json` in the repo has more entries showing variants
(external link mode, http vs https proxy targets, etc.).

### `~/.claude-playbooks/<name>/CLAUDE.md`

Existence triggers playbook discovery. install.sh enumerates these,
allocates a port (8030+), bootstraps a per-playbook ttyd that runs:

```bash
export CLAUDE_CONFIG_DIR="~/.claude-playbooks/<name>"
exec tmux new -A -s "claude-<name>" "claude"
```

The env export must happen BEFORE `tmux new -A` so reattach inherits it
(env is captured at session creation).

### `~/.claude-profile/machines/<host>.md`

Written by install.sh. Hostname, OS, hardware, memory, disk, install root,
playbooks dir, dashboard URL. Designed for playbooks to `@import`.

---

## launchd labels + management

User services (`gui/<UID>/<label>`):

- `com.webterm.<port>` — one per ttyd-backed service + the dashboard
- Plist template: `templates/launchd.plist.tmpl`
- Cheat sheet (substitute `<label>`):

| action | command |
|---|---|
| start | `launchctl kickstart gui/$UID/<label>` |
| restart | `launchctl kickstart -k gui/$UID/<label>` |
| stop | `launchctl kill SIGTERM gui/$UID/<label>` |
| status | `launchctl print gui/$UID/<label>` |
| logs | `tail -f ~/Library/Logs/<label>.log` |

System daemon: `com.webterm.caddy` — substitute `system/<label>` (no UID),
prepend `sudo`. install.sh generates the plist into `generated/` but does
NOT install it; the user copies + bootstraps via printed sudo commands.

---

## Build commands

```bash
# Whole rebuild + bootstrap
./install.sh

# Individual binaries
cd chooser   && go build -o chooser .
cd dashboard && go build -o dashboard .

# Standalone dashboard (HTTP only, no Caddy needed for local dev)
./dashboard/dashboard --bind 127.0.0.1 --port 8021 \
  --chooser-url http://localhost:8020 \
  --playbooks-dir ~/.claude-playbooks \
  --services-file ~/.config/webterm-kit/services.json \
  --caddyfile /tmp/test-Caddyfile

# Standalone chooser (needs tmux running)
./chooser/chooser              # picker mode
./chooser/chooser my-session   # auto-attach mode (mimics ttyd's -a passthrough)
```

---

## Test commands

```bash
./test/smoke.sh                    # tier 1 — 26 curl checks, ~5s
./test/run-all.sh                  # tier 1 + tier 2 (Playwright), ~15s
SKIP_BROWSER=1 ./test/run-all.sh   # tier 1 only (no Node needed)
./test/exhaustive.sh               # tier 2 deep walk + real backend, ~45s
                                   # spins up python3 -m http.server :17777
                                   # tears down: kills server, sweeps exhaust-* tmux
                                   # sessions and exhaust-/pw- prefix services

# Tier 3 (manual / AI agent walkthrough)
test/browser/scenarios.md          # checklist of things automation can't catch

# Visual tour (screenshots → multimodal review)
cd test/browser && INCLUDE_EXTENDED=1 npx playwright test explore.spec.js
ls screenshots/                    # then view PNGs
```

`test/FEATURES.md` maps every feature to the test that asserts it.

---

## Common navigation

- **"What does this URL serve?"** → `templates/Caddyfile.tmpl`
- **"What does the dashboard return for X?"** → `dashboard/main.go` (search `mux.HandleFunc`)
- **"Why is the SPA doing this?"** → `dashboard/static/index.html` (everything inline)
- **"What does the chooser do for key X?"** → `chooser/main.go` (search `case "X"`)
- **"How is service Y wired up?"** → `~/.config/webterm-kit/services.json` + the
  generated Caddyfile services block (live-rewritten by `regenerateCaddyfileServices`)
- **"What gets re-bootstrapped on `./install.sh`?"** → search `launchctl bootstrap` in install.sh
- **"What did I just break?"** → `./test/run-all.sh`
- **"What does the dashboard look like right now?"** → run `explore.spec.js`,
  read the PNGs

---

## Things to know before editing

- **Templates → generated/ → launchd**. Do not hand-edit `generated/*` —
  re-run `./install.sh`.
- **Caddyfile sentinels are load-bearing.** The dashboard's
  `regenerateCaddyfileServices` finds `# === BEGIN/END: webterm-kit
  auto-generated services ===` to know what to replace. Don't remove them.
- **`tmux new -A -s NAME` env semantics.** Env is captured at SESSION
  creation. Existing sessions ignore later env changes — kill + recreate
  to apply.
- **`tmux -F` separators.** Pass `\t` as the literal two-byte string
  (`` `\t` `` in Go), not a real tab — tmux sanitizes real tabs to `_`.
  See `dashboard/listSessions`.
- **launchd ≠ shell environment.** Use `TMPDIR` from the user shell (not
  the per-launchd-service `$TMPDIR`) for tmux socket discovery — see
  `install.sh`'s `USER_TMPDIR=...` and `templates/launchd.plist.tmpl`.
- **`caddy --watch` is unreliable on macOS.** We use the admin API at
  `localhost:2019` and call `caddy reload --config <file>` after writing
  the Caddyfile.
- **Bash `$(python3 ...)` strips trailing newlines.** Re-append a
  newline manually if the heredoc output's trailing whitespace matters
  (it does for the Caddy services block — bit us once).
- **Playwright test titles must be deterministic.** Don't include
  `Date.now()` etc. in `test('...')` strings — workers re-load specs and
  fail to find tests with mismatched titles.

---

## Dependencies

- **Required at runtime**: `ttyd`, `tmux`, `caddy` (Homebrew), Tailscale
  for the cert. macOS only (uses launchd + sysctl).
- **Required to install**: `go`, `python3` (the latter ships with macOS).
- **Required for Tier 2 tests**: Node ≥18 + Playwright (auto-installed
  on first `./test/run-all.sh`; downloads ~92MB chromium-headless once).
- **Optional**: `tailscale` (for cert + DNS); the kit works without it
  if you supply your own cert via `~/.tailscale-certs/<host>.{crt,key}`.
