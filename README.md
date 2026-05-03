# webterm-kit

Reach your Mac's terminal from any device on your Tailnet — `tmux`, `zellij`, or
[Claude Code](https://claude.com/claude-code) — through a browser. No GUI app, no
public internet exposure, just `ttyd` + `tmux` + Tailscale + a Bubble Tea session
chooser, all wired up by `launchd` so they survive reboots and crashes.

```
                ┌─────────────────────────────────────┐
   any device   │  https://mymac.tailXXXX.ts.net:8020 │ ← TUI chooser (Bubble Tea)
   on Tailnet   │  https://mymac.tailXXXX.ts.net:8021 │ ← GUI dashboard (sessions+panes)
                │  https://mymac.tailXXXX.ts.net:8022 │ ← tmux 'main'
                │  https://mymac.tailXXXX.ts.net:8023 │ ← zellij  (if installed)
                │  https://mymac.tailXXXX.ts.net:8024 │ ← claude  (if installed)
                └─────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
   ttyd → tmux/zellij/claude          Go HTTPS service
   (managed by launchd)               (dashboard, /api/sessions)
```

## What you get

- **Browser-accessible terminal** over your Tailnet (HTTPS via Tailscale-issued certs).
- **Two session pickers, same backend**:
  - **TUI chooser** (Go + Bubble Tea) for keyboard-first attach/create.
  - **GUI dashboard** (Go HTTPS + tiny vanilla SPA) listing every session and its
    panes. Click a card to redirect into the chooser with that session pre-attached.
    No terminals are rendered in the GUI — it's a launcher, not a multiplexer.
- **launchd services** with `KeepAlive` and `RunAtLoad` so everything starts
  at login and respawns if it crashes.
- **Hard-reload-resistant Unicode**: ships with a sane `fontFamily` chain so em
  dashes, box-drawing, and warning glyphs render in the browser.

## Requirements

- macOS (uses `launchd`)
- [Tailscale](https://tailscale.com/) — installed and logged in
- [`ttyd`](https://github.com/tsl0922/ttyd) — `brew install ttyd`
- [`tmux`](https://github.com/tmux/tmux) — `brew install tmux`
- [Go](https://go.dev/) 1.22+ — `brew install go` (only needed at install time, to build the chooser)
- Optional: `zellij` (`brew install zellij`), `claude` (the CLI)

## Install

```bash
git clone https://github.com/ramazanpolat/webterm-kit.git
cd webterm-kit
./install.sh
```

The installer will:

1. Detect your tailnet hostname and IP (you can override).
2. Issue a TLS cert via `tailscale cert` if one isn't present.
3. Build the Go chooser and dashboard binaries.
4. Generate per-port `ttyd` shell scripts and `launchd` plists, plus a standalone
   plist for the dashboard HTTPS service.
5. `launchctl bootstrap` each service so it starts immediately and at every login.

When it finishes you'll see the URLs to open. The dashboard and TUI chooser are
the ones worth bookmarking — both let every tab pick its own session.

## Manage services

`launchctl` is to launchd what `systemctl` is to systemd:

| systemd | launchd |
|---|---|
| `systemctl start foo`    | `launchctl kickstart gui/$UID/foo`     |
| `systemctl restart foo`  | `launchctl kickstart -k gui/$UID/foo`  |
| `systemctl stop foo`     | `launchctl kill SIGTERM gui/$UID/foo`  |
| `systemctl status foo`   | `launchctl print gui/$UID/foo`         |
| `systemctl disable foo`  | `launchctl bootout gui/$UID/foo`       |
| `journalctl -u foo`      | `tail -f ~/Library/Logs/foo.log`       |

Labels are `com.webterm.<port>` by default (override with `LABEL_PREFIX` env var
when running `install.sh`).

## Uninstall

```bash
./uninstall.sh
```

Boots out the launchd services and removes generated scripts/plists. Logs and
the cloned repo stay where they are.

## Customizing

The ttyd-backed services installed by default are defined as a list in
`install.sh` (`SERVICES=(...)`). Drop a port, change a command, or add new
services there; re-run `./install.sh` and the change takes effect (it's
idempotent). The standalone dashboard is configured separately via the
`DASHBOARD_PORT` variable in `install.sh` (set it to empty to skip).

To use different ttyd flags (font, theme, key bindings), edit
`templates/ttyd.sh.tmpl`. xterm.js options go after `-t`. The template
includes `-a` so URL `?arg=<session>` is appended to the spawned command —
this is what lets the dashboard deep-link into the chooser.

Source layout:

- `chooser/main.go` — Bubble Tea TUI, ~200 lines. Auto-attaches when given a
  session name as `argv[1]`; otherwise shows the picker.
- `dashboard/main.go` + `dashboard/static/index.html` — Go HTTPS service that
  shells `tmux list-sessions`/`list-panes` for `/api/sessions` and embeds a
  vanilla-JS SPA. No frontend toolchain.

## Why not cmux / wetty / shell-in-a-box / VS Code Tunnels?

- **cmux** — beautiful but a desktop GUI, so only useful when you're at the Mac.
- **wetty** — works, but no per-tab session chooser and no ergonomic launchd recipe.
- **VS Code Tunnels** — great for editing, awkward for ad-hoc shell work.
- **shell-in-a-box** — unmaintained.

This is the smallest amount of glue I could find to get a browser-accessible
multiplexer that feels native, behaves itself across reboots, and lets each
tab live in its own world.

## License

MIT. Use it, fork it, ship better defaults.
