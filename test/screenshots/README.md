# Screenshots

Visual evidence captured during `TEST-PLAN.md` walks. File names map
back to test-case IDs.

| file | case | what it shows |
|---|---|---|
| `L1-dashboard-webterm.png` | L1 | initial paint: title, tabs, system stat bar, playbook + service cards |
| `L4-tab-1-webterm.png` | L4.1 | webterm tab active after pressing `1` |
| `L4-tab-2-services.png` | L4.2 | services tab active after pressing `2` |
| `L4-tab-3-storage.png` | L4.3 | storage tab — empty state ("no storage services configured") |
| `L4-tab-4-media.png` | L4.4 | media tab — empty state |
| `L4-tab-5-discover.png` | L4.5 | discover tab — listening services on the host |
| `T1-chooser-fresh.png` | T1 | freshly-opened chooser ttyd, monospace 20px |
| `T1-T2-terminal-unicode.png` | T2 | em-dash, box-drawing, ⏺ ✻ ※ @ rendered |
| `T11-scrollback.png` | T11 | terminal after `seq 1 100`, scrolled back |
| `S6-playbook-claude.png` | S6 | `/playbook/kommander-dev/` running Claude inside `claude-kommander-dev` tmux session |

Re-take after a non-trivial change. The browser-harness commands are in
`TEST-PLAN.md` "How to run" — basically `browser-harness -c
"capture_screenshot('test/screenshots/<id>-<name>.png')"`.
