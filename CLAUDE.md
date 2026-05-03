# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

macOS-only kit that exposes terminal sessions over a Tailnet via `ttyd` + `tmux`, plus two peer session pickers — a Bubble Tea TUI and a tiny Go HTTPS dashboard with a vanilla-JS SPA. There is no application server in the traditional sense — `install.sh` is the entry point and renders templates into `generated/` and `~/Library/LaunchAgents/`, which `launchd` then runs.

## Common commands

```bash
# Install / re-install (idempotent — re-run after editing install.sh or templates)
./install.sh

# Tear down launchd services + remove generated scripts/plists
./uninstall.sh

# Build the Go binaries (install.sh does this automatically)
cd chooser && go build -o chooser .
cd dashboard && go build -o dashboard .

# Run the chooser standalone (needs tmux running). With no args, shows picker.
# With a session name, attach-or-create that session and exit on detach:
./chooser/chooser
./chooser/chooser mysession

# Run the dashboard standalone (HTTP for local testing, no certs)
./dashboard/dashboard --port 8021 --bind 127.0.0.1 --chooser-url http://localhost:8020
```

The installer reads three values from env or prompts: `TAILNET_HOST`, `BIND_IP`, `LABEL_PREFIX` (default `com.webterm`). Pre-set them in env to skip prompts. `DASHBOARD_PORT` (default `8021`) can be set to empty to skip the dashboard.

## launchd service management

Labels are `<LABEL_PREFIX>.<port>` (e.g. `com.webterm.8020`). `systemctl`-style cheatsheet:

| action | command |
|---|---|
| start | `launchctl kickstart gui/$UID/<label>` |
| restart | `launchctl kickstart -k gui/$UID/<label>` |
| stop | `launchctl kill SIGTERM gui/$UID/<label>` |
| status | `launchctl print gui/$UID/<label>` |
| disable | `launchctl bootout gui/$UID/<label>` |
| logs | `tail -f ~/Library/Logs/<label>.log` |

## Architecture

Two service families, both glued by `install.sh`:

### ttyd-backed services (the SERVICES array)

1. **Service definition** — `SERVICES=(...)` array in `install.sh`. Each entry is `name:port:command`. `chooser` and `tmux` are unconditional; `zellij` and `claude` are appended only if those binaries exist on `PATH`. **Adding/removing a ttyd-backed service means editing this array and re-running `install.sh`.**

2. **Template rendering** — for each service, `install.sh` `sed`s placeholders into:
   - `templates/ttyd.sh.tmpl` → `generated/ttyd-<name>.sh` (the script `ttyd` runs, with TLS flags + `-a` for URL-arg passthrough + the per-service command)
   - `templates/launchd.plist.tmpl` → `~/Library/LaunchAgents/<label>.plist`

   Then `launchctl bootout` + `bootstrap` reloads. Editing templates and re-running `install.sh` is the supported workflow — do not hand-edit files in `generated/`.

3. **TUI chooser** — `chooser/main.go` is a single-file Bubble Tea app that shells out to `tmux list-sessions` / `tmux attach` / `tmux new`. It loops (re-presents the list) after a child tmux exits, so it's the long-lived process `ttyd` keeps alive on the chooser port. **Auto-attach mode**: if `argv[1]` is non-empty (set via ttyd `-a` from a URL like `?arg=mysession`), it runs `tmux new -A -s <name>` directly and exits on detach, skipping the picker. On failure it falls through to the picker with a notice.

### Standalone dashboard (separate code path)

`dashboard/main.go` is a Go HTTPS server (no ttyd in front) that:

- Serves `dashboard/static/index.html` via `embed.FS` — vanilla JS, no toolchain.
- Exposes `/api/sessions` which shells `tmux list-sessions` + `tmux list-panes -a` and returns JSON: sessions with attached count, window count, and a flat pane list.
- Returns the configured `chooserUrl` alongside, so the SPA can build redirect links of the form `<chooserUrl>/?arg=<sessionName>`.

The SPA has no terminal of its own — clicking a session card or submitting the "new session" form just navigates to the chooser ttyd URL with `?arg=<name>`, which ttyd forwards to the chooser binary as argv. **The dashboard is a launcher, not a multiplexer.**

`install.sh` handles the dashboard *outside* the SERVICES loop because it doesn't run behind ttyd: it builds the binary, renders `templates/dashboard.sh.tmpl` → `generated/dashboard.sh`, and reuses `templates/launchd.plist.tmpl` for the plist.

## TLS

Everything serves on the Tailscale-issued cert at `~/.tailscale-certs/<TAILNET_HOST>.{crt,key}`. ttyd uses `-S -C cert -K key`; the dashboard reads the same files via `--cert` / `--key` flags. The installer offers to run `tailscale cert <host>` if the files are missing. Certs auto-renew via Tailscale; nothing in this repo manages renewal.

## Things that look like bugs but aren't

- `chooser/go.mod` lists Bubble Tea deps as `// indirect`. They're used directly from `main.go`; `go mod tidy` will reclassify them but it's cosmetic.
- `dashboard/` has no `go.sum` — it's stdlib-only.
- `generated/`, `chooser/chooser`, `dashboard/dashboard` are gitignored.
- The chooser's `loadItems()` returns `nil` on any tmux error (e.g. no server running). The list will appear empty; press `n` to create the first session.
- The dashboard's `/api/sessions` returns an empty list (not an error) when the tmux server isn't running.
- `templates/ttyd.sh.tmpl` includes `-a` globally. For non-chooser services this means an attacker on the Tailnet *could* sneak extra argv through `?arg=`, but they can already reach a shell — the threat model is "who's on your Tailnet," not "what HTTP they send." Don't worry about it unless you know why you should.

## Subtle traps

- **launchd ≠ shell environment.** Services bootstrapped via `launchctl bootstrap gui/$UID/...` get a private `$TMPDIR` (different from the user's interactive `/var/folders/...`). tmux's default socket lives at `$TMPDIR/tmux-$UID/default`, so without intervention each launchd service would talk to its own tmux server — not the one your shell uses. Fix lives in `templates/launchd.plist.tmpl` (`<key>TMPDIR</key>`) and `install.sh` (`USER_TMPDIR=...`). If you add a new service that needs the user's tmux, this must be set.
- **tmux `-F` and tabs.** Pass field separators in `-F` format strings as the two-byte literal `\t` (raw Go string `` `\t` ``), *not* as a real tab character. Real non-printable bytes get sanitized to `_` in tmux's format output; the literal `\t` two-byte sequence is passed through verbatim and is then split on by the consumer. Same applies to other non-printable separators. This is what the dashboard's `listSessions` does; the chooser uses spaces and is unaffected.
