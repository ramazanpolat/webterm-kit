# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

macOS-only kit that exposes terminal sessions and Claude playbooks over a Tailnet via `ttyd` + `tmux`, fronted by **Caddy on :443** for path-based routing. Two peer session pickers — a Bubble Tea TUI and a tiny Go HTTP dashboard with a vanilla-JS SPA. There is no application server in the traditional sense — `install.sh` is the entry point and renders templates into `generated/` and `~/Library/LaunchAgents/`, which `launchd` then runs. Caddy is bootstrapped separately as a system daemon (needs sudo to bind :80/:443).

**v2 architecture:** every backend (chooser, dashboard, per-playbook ttyds) binds 127.0.0.1 with plain HTTP. Caddy on :443 is the only internet-facing process. URLs are namespaced and path-routed — no port numbers in user-visible URLs:

| URL | what |
|---|---|
| `/` | dashboard (everything) |
| `/chooser/` | TUI session picker (Bubble Tea) |
| `/tmux/` | alias for `/chooser/` |
| `/tmux/<name>/` | 302 → `/chooser/?arg=<name>` (attach-or-create) |
| `/playbook/` | 302 → `/#playbooks` (jumps to dashboard section) |
| `/playbook/<name>/` | that playbook's tmux-wrapped Claude (one ttyd per) |
| `/api/*` | dashboard JSON |

## Common commands

```bash
# Install / re-install (idempotent — re-run after editing install.sh, templates,
# or after adding/removing playbooks under ~/.claude-playbooks/).
./install.sh

# Tear down launchd services + remove generated scripts/plists.
# Caddy daemon must be removed manually (system-level, sudo required) — see uninstall.sh output.
./uninstall.sh

# Build the Go binaries (install.sh does this automatically)
cd chooser && go build -o chooser .
cd dashboard && go build -o dashboard .

# Run the chooser standalone (needs tmux running). With no args, shows picker.
# With a session name, attach-or-create that session and exit on detach:
./chooser/chooser
./chooser/chooser mysession

# Run the dashboard standalone (HTTP for local testing, no certs needed):
./dashboard/dashboard --port 8021 --bind 127.0.0.1 \
  --chooser-url http://localhost:8020 \
  --playbooks-dir ~/.claude-playbooks
```

The installer reads from env or prompts: `TAILNET_HOST`, `BIND_IP`, `LABEL_PREFIX` (default `com.webterm`). Pre-set them in env to skip prompts. `DASHBOARD_PORT` (default `8021`), `PLAYBOOKS_DIR` (default `~/.claude-playbooks`) are also overridable.

## launchd service management

User services are labeled `<LABEL_PREFIX>.<port>` (e.g. `com.webterm.8020`). `systemctl`-style cheatsheet:

| action | command |
|---|---|
| start | `launchctl kickstart gui/$UID/<label>` |
| restart | `launchctl kickstart -k gui/$UID/<label>` |
| stop | `launchctl kill SIGTERM gui/$UID/<label>` |
| status | `launchctl print gui/$UID/<label>` |
| disable | `launchctl bootout gui/$UID/<label>` |
| logs | `tail -f ~/Library/Logs/<label>.log` |

Caddy is a **system** daemon, not user — substitute `system/<label>` (no UID) and prepend `sudo`.

## Architecture

Three layers, all glued by `install.sh`:

### 1. Backend services — every backend binds 127.0.0.1

Per-service `generated/ttyd-<name>.sh` is the script that ttyd execs. ttyd uses `--base-path /<name>/` so WebSocket URLs resolve correctly behind Caddy.

- **chooser** (port 8020) — `chooser/main.go` Bubble Tea TUI. Two views: tmux sessions + Claude playbooks. Press `p` to toggle. **Auto-attach mode**: argv[1] (set via ttyd `-a` from `?arg=name`) runs `tmux new -A -s <name>` directly and exits on detach. Used by both `/chooser/` and `/tmux/<name>/` (the latter via Caddy redirect).
- **per-playbook ttyds** (8030+) — one per `~/.claude-playbooks/*/CLAUDE.md`. Each runs `generated/claude-<playbook>.sh` which exports `CLAUDE_CONFIG_DIR` then `exec tmux new -A -s claude-<playbook> claude`. The env is set BEFORE tmux creates the session — critical for reattach to inherit the right config dir. ttyd's `--base-path /playbook/<name>/` matches the Caddy route.
- **dashboard** (port 8021 by default) — `dashboard/main.go`, plain HTTP, embeds the SPA. Endpoints: `/api/sessions` (sessions + playbooks + chooserUrl), `/api/status` (compact `[{playbook, running, lastActive, pid}]` for widgets).

**Removed in v2.1:** the standalone `tmux` ttyd (port 8022) running `tmux new -A -s main` — `/tmux/` is now a Caddy alias for `/chooser/`, so the dedicated ttyd was redundant. install.sh boots out the v2.0 service if it finds one.

### 2. Caddy — TLS terminator + path router on :443

`templates/Caddyfile.tmpl` rendered to `generated/Caddyfile`. Routes (top of file shows the full table):
- `/chooser/*` → chooser ttyd
- `@tmux_named` (regex `^/tmux/([^/]+)/?$`) → 302 to `/chooser/?arg={1}`
- `@tmux_root` (`/tmux` or `/tmux/`) → 302 to `/chooser/`
- `/playbook/<name>/*` → that playbook's ttyd (one block per, generated)
- `@playbook_root` (`/playbook` or `/playbook/`) → 302 to `/#playbooks`
- `handle {}` (catch-all, last) → dashboard

Because playbooks are namespaced under `/playbook/`, no playbook name can collide with a top-level route — the only restriction is no `/` in playbook names. install.sh checks this.

Caddy uses the Tailscale-issued cert via `tls <cert> <key>`. `auto_https off` so Caddy doesn't try Let's Encrypt. The plist (`templates/caddy.plist.tmpl`) installs to `/Library/LaunchDaemons/` (system) — needs sudo. install.sh prints the exact `sudo cp` + `sudo launchctl bootstrap system` commands; it does NOT run them.

**Auto-reload on Caddyfile change.** The plist runs `caddy run --config <file> --watch`. Re-running `install.sh` (which re-renders the Caddyfile) is enough to make Caddy pick up new playbooks, port changes, etc. — no Caddy restart needed. Caddy debounces, validates, and keeps the old config running if the new one fails validation, so partial writes during render are safe.

### 3. SPA — read-only launcher (no terminal in-page)

`dashboard/static/index.html` — vanilla JS, no toolchain. Renders two sections:
- **Claude playbooks** — cards link to `/<playbook>/` directly (each playbook has its own ttyd).
- **tmux sessions** — cards link to `<chooserUrl>/?arg=<sessionName>` which the chooser ttyd forwards as argv to the chooser binary.

The dashboard is a launcher, not a multiplexer.

### Playbook discovery

`install.sh` enumerates `~/.claude-playbooks/*/` and includes any subdir that contains a `CLAUDE.md`. Re-running `install.sh` after `claude-playbooks new <name>` is the supported workflow — idempotent. The chooser TUI and the dashboard SPA both rescan on every refresh, so they pick up new playbooks without restart.

## TLS

The Tailscale-issued cert at `~/.tailscale-certs/<TAILNET_HOST>.{crt,key}` is consumed only by Caddy now. ttyd and the dashboard no longer terminate TLS (Caddy does it for them). The installer offers to run `tailscale cert <host>` if the files are missing. Certs auto-renew via Tailscale; Caddy reads them on each request — restart Caddy after renewal: `sudo launchctl kickstart -k system/<LABEL_PREFIX>.caddy`.

## Things that look like bugs but aren't

- `chooser/go.mod` lists Bubble Tea deps as `// indirect`. They're used directly from `main.go`; `go mod tidy` will reclassify them but it's cosmetic.
- `dashboard/` has no `go.sum` — it's stdlib-only.
- `generated/`, `chooser/chooser`, `dashboard/dashboard` are gitignored.
- The chooser's `loadSessions()` returns `nil` on any tmux error (e.g. no server running). The list will appear empty; press `n` to create the first session.
- `loadPlaybooks()` returns `nil` if `~/.claude-playbooks/` is missing or unreadable. Same UX — empty list.
- The dashboard's `/api/sessions` returns empty `sessions` (not an error) when tmux isn't running. `playbooks` is independent — still populated.
- `templates/ttyd.sh.tmpl` includes `-a` globally. For non-chooser ttyds this means an attacker on the Tailnet *could* sneak extra argv via `?arg=`, but they can already reach a shell — the threat model is "who's on your Tailnet," not "what HTTP they send." Don't worry about it unless you know why you should.

## Subtle traps

- **launchd ≠ shell environment.** Services bootstrapped via `launchctl bootstrap gui/$UID/...` get a private `$TMPDIR` (different from the user's interactive `/var/folders/...`). tmux's default socket lives at `$TMPDIR/tmux-$UID/default`, so without intervention each launchd service would talk to its own tmux server — not the one your shell uses. Fix lives in `templates/launchd.plist.tmpl` (`<key>TMPDIR</key>`) and `install.sh` (`USER_TMPDIR=...`). If you add a new service that needs the user's tmux, this must be set.
- **tmux `-F` and tabs.** Pass field separators in `-F` format strings as the two-byte literal `\t` (raw Go string `` `\t` ``), *not* as a real tab character. Real non-printable bytes get sanitized to `_` in tmux's format output; the literal `\t` two-byte sequence is passed through verbatim and is then split on by the consumer. Same applies to other non-printable separators. This is what the dashboard's `listSessions` does; the chooser uses spaces and is unaffected.
- **`CLAUDE_CONFIG_DIR` and tmux reattach.** Env vars are captured by tmux at session creation. If you `tmux attach` to a pre-existing `claude-<playbook>` session, your shell's `CLAUDE_CONFIG_DIR` is irrelevant — what matters is what was set when the session was first created. The per-playbook wrapper script (`generated/claude-<playbook>.sh`) exports it before `exec tmux new -A`, which is the only correct order.
- **Caddy on :80/:443 needs root.** macOS user-level launchd cannot bind <1024. The Caddy plist therefore lives in `/Library/LaunchDaemons/` and is bootstrapped via `sudo launchctl bootstrap system`. install.sh generates the plist but never installs it — that's an explicit sudo step the user runs.
- **BSD awk and embedded newlines.** Multi-line template substitution uses `sed -e "/SENTINEL/r tmpfile" -e "/SENTINEL/d"` — `awk -v` rejects newlines in variable values on macOS. If you reach for awk for templating, you'll discover this.
