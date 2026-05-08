# webterm-kit

Reach your Mac's terminal — `tmux` sessions, [Claude Code](https://claude.com/claude-code)
playbooks, and any HTTP service you point at — from any device on your Tailnet,
through a browser. No GUI app, no public internet exposure.

```
   any device on Tailnet
            │
            ▼
   ┌────────────────────────────┐
   │  https://mymac.tailXX.ts.net/                  ← dashboard  │
   │  https://mymac.tailXX.ts.net/chooser/          ← TUI picker │
   │  https://mymac.tailXX.ts.net/tmux/<name>/      ← attach     │
   │  https://mymac.tailXX.ts.net/playbook/<name>/  ← Claude     │
   └─────────────────┬──────────────────────────────────────────┘
                     │ Caddy on :443  (TLS via Tailscale cert)
   ┌─────────────────┴────────────────────────────────────┐
   ▼                          ▼                          ▼
   ttyd (chooser)      ttyd × N (one per playbook)   Go dashboard
   127.0.0.1:8020      127.0.0.1:8030+               127.0.0.1:8021
                       (each wraps tmux + claude)
```

Everything binds `127.0.0.1`. **Caddy on `:443` is the only internet-facing
process**, and it terminates TLS with the cert your Tailnet already gives you.

## What you get

- **Browser-accessible terminals** over your Tailnet, HTTPS only.
- **One URL per thing**, no port numbers to remember:
  - `/` — dashboard (launcher with tabs for terminals, services, storage, media)
  - `/chooser/` — Bubble Tea TUI session picker
  - `/tmux/<name>/` — attach (or create) tmux session `<name>`
  - `/playbook/<name>/` — that Claude playbook in its own tmux-wrapped ttyd
  - `/<your-service>/` — anything you put in `~/.webterm-kit/services.json`
- **launchd-managed**, so it survives reboots and crashes.
- **Auto-discovery** of `~/.claude-playbooks/*/CLAUDE.md` — drop a folder,
  re-run `./install.sh`, get a new URL.

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
./run.sh                            # HTTP on localhost:8080
./run.sh --tls                      # HTTPS on :8443 (needs Tailscale cert)
./run.sh --port 9000 --host my.lan  # any host/port you want
```

`./run.sh` builds the binaries, renders a dev Caddyfile, starts every backend
in the background, and runs Caddy in the foreground. Ctrl-C kills everything.
Logs land in `./logs/<service>.log`.

If a port is already in use (e.g. installed services are running), `run.sh`
refuses to start with a clear message. Run `./uninstall.sh` first.

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
- editing `~/.webterm-kit/services.json`

Caddy runs with `--watch`, so re-rendering the Caddyfile is enough — no Caddy
restart needed.

## Uninstall

```bash
./uninstall.sh           # remove user services + generated files
./uninstall.sh --purge   # also remove Caddy daemon and ~/.webterm-kit
```

`--purge` will prompt for sudo (to remove the system Caddy daemon) and will
**not** touch `~/.claude-playbooks/` or `~/.tailscale-certs/`.

## Manage services

`launchctl` is to launchd what `systemctl` is to systemd. User services are
labeled `com.webterm.<port>` (e.g. `com.webterm.8020` is the chooser):

| systemd | launchd |
|---|---|
| `systemctl start foo`    | `launchctl kickstart gui/$UID/foo`     |
| `systemctl restart foo`  | `launchctl kickstart -k gui/$UID/foo`  |
| `systemctl stop foo`     | `launchctl kill SIGTERM gui/$UID/foo`  |
| `systemctl status foo`   | `launchctl print gui/$UID/foo`         |
| `systemctl disable foo`  | `launchctl bootout gui/$UID/foo`       |
| `journalctl -u foo`      | `tail -f ~/Library/Logs/foo.log`       |

Caddy is a **system** daemon (it binds privileged ports), so substitute
`system/com.webterm.caddy` and prepend `sudo`.

Override the prefix with `LABEL_PREFIX=org.example ./install.sh`.

## Adding a service

`~/.webterm-kit/services.json` is the only file you edit by hand. Each entry
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
./test/smoke.sh                          # ~5s, no browser deps
TAILNET_HOST=mymac.local ./test/smoke.sh # against a different host
./test/run-all.sh                        # smoke + Playwright SPA tests
```

`smoke.sh` hits every Caddy route and every `/api/*` endpoint with `curl`,
including a POST/DELETE round-trip on `/api/services`. It's the fastest way to
confirm a fresh install actually works end-to-end.

## Source layout

| | |
|---|---|
| `run.sh` | portable: foreground process tree, Ctrl-C to stop |
| `install.sh` | installed: launchd services + system Caddy daemon |
| `uninstall.sh` | reverses `install.sh` |
| `chooser/main.go` | Bubble Tea TUI session picker |
| `dashboard/main.go` | Go HTTP service (no toolchain) |
| `dashboard/static/index.html` | vanilla-JS SPA, embedded into the binary at build |
| `templates/*.tmpl` | rendered into `generated/` by `install.sh` |
| `test/smoke.sh` | curl-driven regression tests |
| `test/browser/` | Playwright SPA tests (Tier 2) |
| `CLAUDE.md` | architecture deep-dive for AI coding assistants |
| `DESIGN.md` | the v3 UI brief |
| `CODEWIKI.md` | code reference, generated |

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
