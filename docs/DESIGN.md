# DESIGN brief

For whoever is doing the next-generation UI redesign — human designer or
AI agent. Pairs with `PROJECT.md` (what this is), `CODEWIKI.md` (what
exists today). **Do not try to mimic the current UI.** This brief
describes the *destination*, not the present.

---

## North star (one paragraph)

> **A personal command center for one developer's entire AI-augmented
> workspace.** One URL on a tailnet, opening to a dense, scannable,
> phone-friendly dashboard that surfaces every active agent, every
> running service, every remote machine, and every recent action — with
> the controls to spawn, send-message, deploy, restart, or kill any of
> them. Terminal-aesthetic but not a terminal. The pane of glass for
> "what is my AI doing for me right now, and how do I steer it."

If the existing UI is a launcher, this is **mission control**.

---

## Who uses it

A single power user (the maintainer). Heavy Claude Code user. Runs many
playbooks in parallel (each is a Claude session with its own memory + tool
set). Lives in tmux. Has one Mac mini as a server, may add more machines
later (homelab trajectory). Phone-first when away from desk; desktop when
seated. Strong opinions: dark, monospace, keyboard-driven, density over
whitespace, "show me everything that matters at a glance."

Not building for: teams, customers, anonymous users. Tailnet is the
auth boundary; everyone who reaches this URL is the owner.

---

## Information architecture — top-level tabs

Designer can re-cluster, rename, drop, or merge. These are the *concepts*,
not the final tab strip.

| tab | mission | rough source data |
|---|---|---|
| **Overview** | One-glance status: what's alive, what's spending tokens, what needs attention | aggregates from every other tab |
| **DEV** | The developer surface: terminals, Claude playbooks, opencode sessions, repos | tmux, `~/.claude-playbooks/*`, git, ttyd |
| **Deploy** | Inventory of remote targets (SSH, Docker, Proxmox, k8s, etc.) + what's deployed where + deploy actions | a new config file (does not exist yet) |
| **Storage** | File browsers, backups, drive health | filebrowser-style apps, df, `tailscale serve` files |
| **Media** | Personal media library (jellyfin, photos) | external services |
| **History** | Timeline: what was done, when, on which project — visual focus indicators | git log across repos, Claude conversation timestamps, system activity |
| **Memory** | Unified view of "what does the AI know about me and my projects" | each playbook's memory/, CLAUDE.md files, services.json |
| **Settings** | Config, machine profile, API keys (placeholder), tab visibility | services.json, env, future settings.json |

**Tabs to consider dropping or combining:**
- "Project" was tentative — could be a slice within DEV (filter by repo)
- "Storage" + "Media" might be one "Files" tab depending on density
- Keep it ≤ 7 top-level tabs for the phone strip; nest if more

---

## Per-tab content sketches (designer is free to redesign each)

### Overview
- **Now**: what agents are running, last action timestamp, ~tokens this hour
- **Hosts**: per-machine cpu/ram/disk/load chips (this Mac + future)
- **Recent activity** strip: last 24h timeline, color-coded by project
- **Attention** queue: agent waiting for input, deployment failed, host down, low disk
- **Quick actions**: open last session, send-message to running agent, deploy

### DEV
- Sections: **Playbooks** (each Claude config dir as a card), **Sessions**
  (tmux sessions, including non-Claude ones), **Tools** (opencode running,
  CLI launchers, "open shell here").
- Per-playbook card: name, current status (idle / waiting / tool-using),
  last tool call, conversation length, tokens-used-this-session, "send
  message" inline form, "open" link.
- Per-session card: name, attached count, recent commands.
- Bonus: a "fork from here" affordance on each card to clone a session
  for an experiment.

### Deploy
- **Targets**: list of remote hosts. Each is `{name, kind, address,
  credentials_ref}` where kind ∈ `{ssh, docker-host, proxmox, k8s,
  fly.io, raw}`. Per-target chip: green/red dot for reachability, last
  check, what's deployed.
- **Deployments**: list of `{source_repo, target, recipe}`. Recipe is
  "how to deploy" — a script ref (`./install.sh`), a docker compose
  file, a proxmox VM template, a k8s manifest.
- **Actions per row**: deploy now, redeploy (re-run recipe), view logs,
  open shell on target.
- Note: this is *not* trying to compete with Fly.io / Render / etc.
  It's an **inventory + cron-like trigger surface** for things you
  already deploy by hand.

### Storage
- File browsers (whatever you've deployed: filebrowser, FilePizza, ZFS
  status, etc.)
- Backup status if any (rsync, restic snapshots, time machine state)
- Disk usage per mount across hosts

### Media
- Cards for jellyfin / plex / immich / etc.
- "On now" if any media is currently playing

### History
- **Timeline view**, default = last 7 days. Each row = one project /
  playbook / repo. Cells colored by activity intensity (commits + Claude
  turns + manual edits).
- **Focus chart**: where did my time go this week? Stacked area or bar
  per project.
- Click a cell → drill into that day for that project (Claude turns,
  commits, files touched).
- Sources to aggregate: `git log --all` across `~/DEV/*`, each playbook's
  `history.jsonl` timestamps, optionally `lsappinfo`/`hidutil` idle data.

### Memory
- **Per-context view**: each playbook's memory dir, project CLAUDE.md
  files, ~/.claude-profile/machines/, services.json
- Searchable across all
- Maybe inline-editable for memory files
- Diff view: "what changed in memory in the last week"

### Settings
- The machine profile + paths
- Tab visibility (hide tabs you don't use)
- Per-playbook config quick view (allowed_tools, etc.)
- API key placeholders for integrations (don't build the auth, just
  the slot)

---

## Visual language — three honest directions

Pick one. They're real options, not equally good.

### Option A — "btop in a browser"
Maximum density. Everything is a small chip / sparkline / mini-table.
Monospace primary throughout. Looks like watching a build server. Best
for desktop, harder on phone. Reference vibe: btop, glances, fly.io's
status pages.

### Option B — "Linear-meets-terminal"
Calmer. Clear typographic hierarchy. Cards with breathing room. Sans-serif
for body, monospace for data. Subtle status dots, no sparklines unless
asked. Mobile-first. Reference vibe: Linear settings pages, Vercel
dashboard, Cloudflare's calmer screens.

### Option C — "TUI-on-the-web"
Lean explicitly into the terminal aesthetic: tab strip rendered like
shell prompt segments, list views like `ls -la` output, no rounded
corners, hairline borders only, ASCII-art accents where they help.
Reference vibe: gum-styled tools, charm.sh's promotional shots, neofetch.

The maintainer's stated preference is **dark + monospace + dense + terminal-y**
(B with leans toward C is probably the sweet spot). But take the brief
and make a real recommendation — don't average them.

---

## Hard constraints (non-negotiable)

- **Single HTML file**, embedded into the Go dashboard binary via
  `go:embed`. No build step. No npm at runtime. Vanilla JS, no
  framework. **CSS in the same file.** (Designer can use any tools to
  CREATE the markup; the *delivered* artifact must be one file.)
- **Dark by default.** Light mode optional but not required.
- **Mobile + desktop** — at minimum 360px wide → 1920px wide. The phone
  case is heavily used.
- **Accessible to keyboard.** Tab strip switchable by number keys,
  cards focusable with Tab, Enter activates.
- **Same-origin only.** No external font/CSS/JS CDNs (single user might
  be on flaky connection, also keeps Tailnet self-sufficient).
- **Auto-refresh sections** on tab regaining focus (don't make the user
  reload).
- **Server-side data shape**: read what's documented in `CODEWIKI.md`'s
  API table. New tabs need new endpoints — design with the contract in
  mind, propose the new endpoint shape.

## Soft constraints (push back if you have a reason)

- Tab count ≤ 7 for the phone strip; if you need more, group with a
  drop-down "more" menu rather than horizontal scroll.
- One status semantic across the app: green = good, amber = attention,
  red = broken, gray = inactive/idle. Apply consistently.
- Time formatting: relative (`2m ago`) for recent, absolute for >24h.
- File-path / URL display: monospace, ellipsis on overflow, but a hover
  tooltip with the full thing.

---

## Don't-touch list (interactions to preserve)

These work and would be loud regressions if you removed them:

- Number keys 1-N jump tabs (suppressed when input focused)
- URL hash deep-links (`#dev`, `#deploy`, `#history`)
- Card click navigates to the underlying URL in a new tab or same tab
  per kind (terminals: same-tab; external services: new tab)
- The chooser TUI URL `/chooser/?arg=NAME` continues to work (it's a
  TUI, not redesigned in this pass)
- Per-playbook URL `/playbook/<name>/` continues to work
- API endpoints in `CODEWIKI.md` keep their shapes — extend, don't
  break

---

## Open questions for the designer

- **Should Overview show miniaturized versions of every other tab, or
  curated highlights?** Mini-versions = consistency, curated = signal.
- **History tab visualization: timeline matrix or stacked area?** Or
  "git log style" with avatars per project?
- **Deploy: how to represent "in flight"?** Spinner, build-log streaming
  inline, separate logs view?
- **Mobile bottom nav vs top tabs?** Bottom is more iOS-app-like and
  thumb-friendly; top is more desktop-consistent.
- **Card vs list density toggle?** Power-user feature. Or just pick one
  and commit?
- **Single-page-app vs server-rendered partials?** Currently SPA. Could
  go HTMX-style for simpler iteration. Designer picks.

---

## Scope phasing

If everything-at-once is too much (it probably is):

**Phase 1** (re-skin + restructure):
- Overview, DEV, Storage, Media, Settings
- All tabs that already have backend data
- New visual language applied consistently

**Phase 2** (new surfaces):
- History (needs new aggregation backend, no API exists yet)
- Memory (needs new data layer)
- Deploy (needs entire new config file + runner)

Don't try to ship phase 2 with phase 1; the data isn't there.

---

## References worth a look

- **For density without ugliness**: btop, glances, htop's pretty siblings
- **For card-based dashboards**: Vercel project view, Linear's "My Issues"
- **For deploy/inventory feel**: Fly.io's app dashboard, Coolify's project
  view, Komodo (formerly Monitor) for Docker
- **For timeline visualizations**: GitHub contribution graph, GitLab's
  activity feed, Wakatime's per-project breakdown
- **For terminal-aesthetic web UIs**: charm.sh's site, gum demos,
  starship.rs prompts (visual reference, not interactive)
- **Anti-references** (what to avoid): cPanel's everything, Webmin's
  1998 vibe, Heimdall's overly-decorative cards

---

## Deliverables expected from the designer

1. **Three sketches** for the chosen visual direction at three viewport
   widths: 360px, 1024px, 1920px. Pick Overview + DEV + one other tab.
2. **A component inventory**: tab strip, header, card variants, status
   dot, button, form input, table, empty state, error banner — what's
   each look like, what are their states.
3. **A typographic + color spec** with concrete values (font stack,
   sizes, color hex codes, spacing scale).
4. **One full-page mockup** of the Overview tab, the densest one, to
   stress-test the system.
5. **Implementation note** describing what's hard about delivering this
   in vanilla JS / no framework, with proposed simplifications if any.

---

## What success looks like

- Maintainer opens it on phone, immediately sees: 2 agents running, 1
  needs input, today's commits, Mac mini at 30% CPU. One tap to act on
  any of those.
- Adding a new playbook makes it appear automatically in DEV without
  any other change.
- Adding a new deploy target via Settings makes it appear in Deploy
  with a "test connection" indicator immediately.
- Page loads in <1s on a phone over LTE.
- Nothing on screen is decorative — every pixel says or does something.
