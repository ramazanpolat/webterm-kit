# webterm-kit

Reach your Mac's terminal — `tmux` sessions, [Claude Code](https://claude.com/claude-code)
playbooks, and any HTTP service you point at — from any device on your Tailnet,
through a browser. No GUI app, no public internet exposure.

```
   any device on Tailnet
            │
            ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  https://mymac.tailXX.ts.net/                  ← dashboard   │
   │  https://mymac.tailXX.ts.net/chooser/          ← TUI picker  │
   │  https://mymac.tailXX.ts.net/tmux/<name>/      ← attach      │
   │  https://mymac.tailXX.ts.net/playbook/<name>/  ← Claude      │
   └─────────────────┬────────────────────────────────────────────┘
                     │ Caddy on :443  (TLS via Tailscale cert) — installed mode
                     │ Caddy on :8080 (plain HTTP)              — portable mode
   ┌─────────────────┴────────────────────────────────────┐
   ▼                          ▼                          ▼
   ttyd (chooser)      ttyd × N (one per playbook)   Go dashboard
   127.0.0.1:8020      127.0.0.1:8030+               127.0.0.1:8021
                       (each wraps tmux + claude)
```

All ttyds and the dashboard bind `127.0.0.1`. Caddy is the only process that
listens on a public-ish port — `:443` (HTTPS, with the Tailscale cert) in
installed mode, or a high HTTP port in portable mode.

## What you get

- **Browser-accessible terminals** over your Tailnet.
- **One URL per thing**, no port numbers to remember (in installed mode):
  - `/` — dashboard, with tabs: webterm | services | storage | media | discover
  - `/chooser/` — Bubble Tea TUI session picker
  - `/tmux/<name>/` — attach (or create) tmux session `<name>`
  - `/playbook/<name>/` — that Claude playbook in its own tmux-wrapped ttyd
  - `/<your-service>/` — anything you put in `~/.config/webterm-kit/services.json`
- **launchd-managed** (installed mode) so it survives reboots and crashes,
  or **foreground tree** (portable mode) for fast dev iteration.
- **Auto-discovery** of `~/.claude-playbooks/*/CLAUDE.md` — drop a folder,
  re-run, get a new URL.
- **Works with non-US keyboards** out of the box (Turkish-Q, German, French,
  Spanish, Polish, …) — see [keyboard layouts](#keyboard-layouts) below.

## Requirements

| | |
|---|---|
| macOS | uses `launchd` |
| [Tailscale](https://tailscale.com/) | provides the hostname + TLS cert (or place certs manually — see below) |
| `ttyd` | `brew install ttyd` |
| `tmux` | `brew install tmux` |
| `caddy` | `brew install caddy` (TLS terminator on `:443`) |
| Go 1.22+ | `brew install go` (build-time only) |
| `python3` | ships with macOS Command Line Tools (parses `services.json`) |

`./install.sh` checks every one of these and exits with the right `brew install`
hint if anything is missing.

## Two ways to run it

| | when |
|---|---|
| `./run.sh` | **portable / dev mode**. Foreground, Ctrl-C stops it. No sudo, no launchd, no system changes. Defaults to HTTP on `localhost:8080`. |
| `./install.sh` | **installed mode**. launchd-managed, survives reboots, Caddy on `:443` over HTTPS. Needs sudo once for the Caddy daemon. |

Both use the same backends and ports (`8020`/`8021`/`8030+`), so they can't run
side by side — pick one. `./uninstall.sh` reverses installed mode; `Ctrl-C`
reverses portable mode.

### Portable mode

```bash
git clone https://github.com/ramazanpolat/webterm-kit.git
cd webterm-kit
./run.sh                            # background by default — prompt returns
./stop.sh                           # stop the running instance
./run.sh -it                        # foreground (interactive); Ctrl-C stops it
./run.sh --tls                      # HTTPS on :8443 (needs Tailscale cert)
./run.sh --port 9000 --host my.lan  # any host/port you want
./run.sh --no-build                 # skip `go build` if binaries are current
```

`./run.sh` builds the binaries, renders a dev Caddyfile, starts every backend
and Caddy, then **detaches** so you get your prompt back. The supervisor PID
is recorded in `./generated/run.pid`; `./stop.sh` reads it, sends SIGTERM,
waits for the trap to clean up children, then removes the file. Re-running
`./run.sh` while one's already up dies with `already running (pid …). Stop
it first: ./stop.sh`. Per-service logs land in `./logs/<service>.log` and
the supervisor log in `./logs/run.log`.

For development where you want to watch output live, use `./run.sh -it` —
same as above but in the foreground.

The Caddy front door binds **all interfaces** by default, so once it's up
you can reach it from any device on your tailnet at
`http://<your-tailnet-host>:8080/` — no installed mode required for browsing
from your phone.

If a port is already in use (e.g. installed services are running), `run.sh`
refuses to start with a clear message. Run `./uninstall.sh` first. You can
also override any backend port: `DASHBOARD_PORT=8121 ./run.sh` (handy if a
launchd phantom socket is wedged on the default).

### Installed mode

```bash
git clone https://github.com/ramazanpolat/webterm-kit.git
cd webterm-kit
./install.sh
```

The installer:

1. Verifies prereqs and detects your Tailnet hostname + IP (override at the prompt).
2. Issues a TLS cert via `tailscale cert` if one isn't already at
   `~/.tailscale-certs/<host>.{crt,key}`.
3. Builds the Go `chooser` and `dashboard` binaries.
4. Renders per-service shell wrappers + launchd plists into `generated/` and
   `~/Library/LaunchAgents/`, then `launchctl bootstrap`s each one.
5. Renders `generated/Caddyfile`.
6. **Caddy is the one step that needs `sudo`** (it binds `:80`/`:443`). The
   installer offers to run the bootstrap for you, or prints the exact commands
   if you'd rather do it yourself.

When it finishes you'll see the full URL list. Bookmark `/` (the dashboard).

### Install without Tailscale

You can skip Tailscale and bring your own cert. Set `TAILNET_HOST` and `BIND_IP`
in the env, place a cert pair at `~/.tailscale-certs/$TAILNET_HOST.crt` and
`.key` (any PEM cert works — name them this way), and `./install.sh` will use them.

```bash
TAILNET_HOST=mymac.local BIND_IP=192.168.1.20 ./install.sh
```

### Re-run any time

`install.sh` is idempotent. Re-run after:

- editing templates or `install.sh`
- adding/removing playbooks under `~/.claude-playbooks/`
- editing `~/.config/webterm-kit/services.json`

Caddy reloads via its admin API (the dashboard triggers it after rewriting
the Caddyfile services block), so a fresh `./install.sh` picks up new
playbooks without restarting the daemon. Use `./install.sh --dry-run` to
preview without touching anything, or `./install.sh --yes` to skip prompts.

## Keyboard layouts

Many non-US layouts use **Option** as a modifier to produce common
characters: Turkish-Q `Option+Q` for `@`, German `Option+5` for `[`, etc.
By default webterm-kit sets `MAC_OPTION_IS_META=false` so those keys reach
the OS layout layer and produce the right symbol. The trade-off is that
Readline meta-shortcuts (`Option+B` / `Option+F` to jump words) won't fire
— if you're on a US keyboard and want them, opt in:

```bash
MAC_OPTION_IS_META=true ./run.sh
MAC_OPTION_IS_META=true ./install.sh
```

Setting it persistently: `export MAC_OPTION_IS_META=true` in your shell rc.

## Uninstall

```bash
./uninstall.sh           # remove user services + generated files
./uninstall.sh --purge   # also remove Caddy daemon + ~/.config/webterm-kit/
```

`--purge` will prompt for sudo (to remove the system Caddy daemon) and will
**not** touch `~/.claude-playbooks/` or `~/.tailscale-certs/`.

## Manage services

After `./install.sh`, services start immediately *and* survive reboots
(launchd plists carry `RunAtLoad=true` + `KeepAlive=true`). You don't need
to start them manually — but you may want to stop, restart, or disable
them without uninstalling. Use `./service.sh`:

```bash
./service.sh status     # which services are running, which are disabled
./service.sh stop       # stop now; comes back on next login
./service.sh start      # start them now
./service.sh restart    # kickstart -k each (force restart)
./service.sh disable    # stop now AND don't start on reboot — like `systemctl disable`
./service.sh enable     # re-enable + start
```

Add `--include-caddy` to also act on the system Caddy daemon (sudo prompted).
Use `--label com.webterm.8020` to target a single service.

Direct `launchctl` cheatsheet for the curious:

| systemd | launchd | `service.sh` |
|---|---|---|
| `systemctl start foo`   | `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/foo.plist` | `./service.sh start` |
| `systemctl restart foo` | `launchctl kickstart -k gui/$UID/foo`  | `./service.sh restart` |
| `systemctl stop foo`    | `launchctl bootout gui/$UID/foo`       | `./service.sh stop` |
| `systemctl status foo`  | `launchctl print gui/$UID/foo`         | `./service.sh status` |
| `systemctl disable foo` | `launchctl disable gui/$UID/foo` + bootout | `./service.sh disable` |
| `systemctl enable foo`  | `launchctl enable gui/$UID/foo` + bootstrap | `./service.sh enable` |
| `journalctl -u foo`     | `tail -f ~/Library/Logs/foo.log`       | — |

> Note: `launchctl kill SIGTERM` doesn't actually stop a service whose plist
> has `KeepAlive=true` (yours do) — launchd just respawns it. Use `bootout`
> (or `./service.sh stop`).

Caddy is a **system** daemon (it binds privileged ports), so its label
domain is `system/com.webterm.caddy` and every command needs `sudo`. Pass
`--include-caddy` to `service.sh` to handle it too.

Override the prefix with `LABEL_PREFIX=org.example ./install.sh`.

## Adding a service

`~/.config/webterm-kit/services.json` is the only file you edit by hand. Each entry
becomes a card on the dashboard; if you give it a `proxy_to`, install.sh adds a
Caddy `reverse_proxy` block so it lives under your hostname.

```json
{
  "services": [
    {
      "name": "jellyfin",
      "category": "media",
      "icon": "🎬",
      "url": "/jellyfin/",
      "proxy_to": "127.0.0.1:8096"
    },
    {
      "name": "github",
      "category": "services",
      "icon": "🐙",
      "url": "https://github.com"
    }
  ]
}
```

Re-run `./install.sh` to wire it in. See `services.example.json` for the full
schema.

## Verifying it works

```bash
./test/smoke.sh                              # ~5s, no browser deps
./test/smoke.sh --host localhost:8080        # against ./run.sh portable mode
TAILNET_HOST=mymac.local ./test/smoke.sh     # against a different installed host
./test/run-all.sh                            # smoke + Playwright SPA tests
```

`smoke.sh` hits every Caddy route and every `/api/*` endpoint with `curl`,
including a POST/DELETE round-trip on `/api/services`. It's the fastest way
to confirm a fresh install actually works end-to-end.

For end-user behavior the curl suite can't reach (look-and-feel, fonts,
copy/paste, modifier keys), see **`test/TEST-PLAN.md`** — it walks every
case by ID, includes a 5-minute manual checklist for the terminal cases
that automation can't reproduce, and has an append-only walk log of past
runs and bugs found.

## Source layout

| | |
|---|---|
| `run.sh` | portable: backgrounded supervisor (or `-it` for foreground) |
| `stop.sh` | stop the backgrounded `run.sh` supervisor |
| `install.sh` | installed: launchd services + system Caddy daemon |
| `service.sh` | manage installed services (start / stop / disable / enable) |
| `uninstall.sh` | reverses `install.sh` |
| `chooser/main.go` | Bubble Tea TUI session picker |
| `dashboard/main.go` | Go HTTP service (no toolchain) |
| `dashboard/static/index.html` | vanilla-JS SPA, embedded into the binary at build |
| `templates/*.tmpl` | rendered into `generated/` by `install.sh` |
| `test/TEST-PLAN.md` | end-user-keyed test plan + walk log |
| `test/smoke.sh` | curl-driven regression tests (Tier 1) |
| `test/browser/` | Playwright SPA tests (Tier 2) |
| `test/browser/scenarios.md` | manual exploratory scenarios (Tier 3) |
| `test/screenshots/` | visual evidence from past walks |
| `CLAUDE.md` | architecture deep-dive for AI coding assistants |
| `docs/DESIGN.md` | the v3 UI brief |
| `docs/PROJECT.md` | project status / roadmap |
| `docs/CODEWIKI.md` | code-level reference |

## Why not cmux / wetty / VS Code Tunnels?

- **cmux** — desktop GUI, only useful when you're at the Mac.
- **wetty** — works, but no per-tab session chooser and no launchd recipe.
- **VS Code Tunnels** — great for editing, awkward for shell work.
- **shell-in-a-box** — unmaintained.

webterm-kit is the smallest amount of glue I could find to get a
browser-accessible multiplexer that feels native, behaves itself across
reboots, and lets each tab live in its own world.

## License

MIT. Use it, fork it, ship better defaults.
