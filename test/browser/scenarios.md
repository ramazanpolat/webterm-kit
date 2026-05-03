# Exploratory test scenarios

These are the things the automated suites can't cover — real-terminal
interactions, cross-tab behaviors, font rendering. A human walks through
them after a non-trivial change. An AI agent (browser-use, Claude Code
driving Playwright, etc.) can also walk them.

Each scenario starts with what to do, expected result, and a note on
what kind of bug it would catch if it broke.

---

## A. Terminal lifecycle

### A1. Auto-attached session ends cleanly
Visit `https://<host>/chooser/?arg=pw-scratch`.

You get a fresh shell (the named tmux session is created on first visit).
Type `echo hello`. See output. Press **Ctrl-D** to exit the shell.

**Expected**: yellow `session 'pw-scratch' ended.` message, dim `close
this tab, or refresh to start a fresh session.` line, no "Press Enter to
Reconnect" prompt.

If pressing Enter brings the session back: chooser auto-respawn
regression (parking logic broken).

### A2. Refresh recreates a fresh session
After A1, hit refresh. **Expected**: brand-new shell prompt, no scrollback
from before.

### A3. Network drop preserves running work
Open `/chooser/?arg=pw-scratch`. Run `vim`. Drop your wifi for ~10s and
reconnect. **Expected**: Page reloads (or auto-reconnects), you're back
in vim with the same buffer. (tmux session survives because it's
detached behind ttyd's PTY.)

---

## B. Font + Unicode rendering

### B1. Claude's UI symbols render
Open any playbook (`/playbook/<name>/`). Wait for Claude's banner.

**Expected**: see `⏺`, `✻`, `※` and any box-drawing chars rendered
correctly. **Bug if** they appear as `_` (font fallback or locale issue).

### B2. Turkish input
In a session, type `ışŞığĞ` (Turkish chars). **Expected**: characters
display correctly. Bug = locale or font.

---

## C. Service add → use → remove

### C1. Add a non-existent service
Discover tab → find a row with port that doesn't matter (e.g., a
short-lived dev server you spun up) → `+ add` → name `c1-test`,
category `services`, path `/c1-test/`. Save.

**Expected**: Card appears in services tab, discover row turns green
"✓ exposed". **Bug if** card appears but Caddy still 404s — Caddyfile
wasn't reloaded.

### C2. Visit the proxied service
Click the new card or visit `https://<host>/c1-test/`.

**Expected** (best case): the underlying service responds normally.
**Acceptable** (path-prefix issue): blank page because the service uses
absolute paths — switch to "external link" mode for that service.

### C3. Cleanup
`curl -X DELETE 'https://<host>/api/services?name=c1-test'`

**Expected**: 204, card disappears from services tab on next refresh,
discover row goes back to addable.

---

## D. Cross-tab navigation

### D1. Hash-based deep links
Open `https://<host>/#services` directly in the browser address bar.
**Expected**: services tab is active immediately, no flash of webterm.

### D2. Number key shortcuts
While focus is anywhere except an input, press `1`-`5`. Each tab
activates. Click an `<input>` (e.g. the open-session form), press a
number — focus stays in the input, value gets the digit.

### D3. Page mode for `/playbook/` and `/tmux/`
Visit `https://<host>/playbook/`. **Expected**: dashboard SPA loads,
playbooks-only section visible, no tmux sessions section, "open or
create" form hidden. `https://<host>/tmux/` → mirror behavior.

---

## E. Stat bar

### E1. Stress the CPU
Run `yes > /dev/null` in a terminal. Watch the dashboard's `cpu` stat
within 5 seconds.

**Expected**: value rises into amber (>60%) or red (>85%) zone, color
changes accordingly.

### E2. Disk free shows correctly
Compare `df -h /` in a real terminal vs the dashboard's `disk N free`.

**Expected**: roughly matching numbers.

---

## How an AI agent should run these

Hand these scenarios to a browser-driving agent (browser-use, or Claude
Code with Playwright access):

> "Walk through scenarios.md. For each, note: PASS, FAIL with
> screenshot, or AMBIGUOUS with description. Don't make changes."

Each scenario is small enough to verify in a few clicks. The PASS/FAIL
list is what makes "go check if what we implemented is working" tractable.
