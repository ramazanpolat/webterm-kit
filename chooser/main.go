package main

import (
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// decodeArg URL-decodes the auto-attach argument so the SPA can safely
// percent-encode session names that contain slashes (or other URL-tricky
// chars). Idempotent for already-clean names: "main" → "main",
// "claude%2Fwebterm-kit%2Freview" → "claude/webterm-kit/review".
func decodeArg(s string) string {
	if d, err := url.QueryUnescape(s); err == nil {
		return d
	}
	return s
}

// playbooksDir resolves the playbooks root, honoring PLAYBOOKS_DIR env override
// (matches install.sh). Returns "" if neither env nor $HOME is usable.
func playbooksDir() string {
	if d := os.Getenv("PLAYBOOKS_DIR"); d != "" {
		return d
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".claude-playbooks")
}

// --- session list items ---

type sessionItem struct {
	name     string
	attached int
}

func (s sessionItem) Title() string {
	tag := lipgloss.NewStyle().Foreground(lipgloss.Color("245")).Render("[tmux]")
	if s.attached > 0 {
		return fmt.Sprintf("%s %s  %s", tag, s.name,
			lipgloss.NewStyle().Foreground(lipgloss.Color("46")).Render(
				fmt.Sprintf("attached×%d", s.attached)))
	}
	return fmt.Sprintf("%s %s", tag, s.name)
}
func (s sessionItem) Description() string { return "" }
func (s sessionItem) FilterValue() string { return s.name }

// --- playbook list items ---

type playbookItem struct {
	name       string
	running    bool
	lastActive time.Time
}

func (p playbookItem) Title() string {
	tag := lipgloss.NewStyle().Foreground(lipgloss.Color("63")).Render("[playbook]")
	status := lipgloss.NewStyle().Foreground(lipgloss.Color("245")).Render("idle")
	if p.running {
		status = lipgloss.NewStyle().Foreground(lipgloss.Color("46")).Render("running")
	}
	when := ""
	if !p.lastActive.IsZero() {
		when = "  " + lipgloss.NewStyle().Faint(true).Render(humanAgo(p.lastActive))
	}
	return fmt.Sprintf("%s %s  %s%s", tag, p.name, status, when)
}
func (p playbookItem) Description() string { return "" }
func (p playbookItem) FilterValue() string { return p.name }

func humanAgo(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}

// --- views ---

type viewState int

const (
	viewList viewState = iota
	viewNew
	viewPlaybooks
)

type model struct {
	state         viewState
	list          list.Model // sessions
	playbookList  list.Model
	input         textinput.Model
	choice        string
	notice        string
}

// loadSessions queries tmux for current sessions.
func loadSessions() []list.Item {
	out, err := exec.Command("tmux", "list-sessions",
		"-F", "#{session_name} #{session_attached}").Output()
	if err != nil {
		return nil
	}
	var items []list.Item
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		var att int
		fmt.Sscanf(f[1], "%d", &att)
		items = append(items, sessionItem{name: f[0], attached: att})
	}
	return items
}

// loadPlaybooks scans the playbooks dir for subdirs that contain a CLAUDE.md.
// "Running" means the tmux session named claude-<playbook> exists.
// "lastActive" comes from the sessions/ subdir's mtime (Claude writes there);
// falls back to the playbook dir's own mtime.
func loadPlaybooks() []list.Item {
	dir := playbooksDir()
	if dir == "" {
		return nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	running := tmuxRunningSet()
	var items []playbookItem
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		claudeMd := filepath.Join(dir, e.Name(), "CLAUDE.md")
		if _, err := os.Stat(claudeMd); err != nil {
			continue
		}
		pi := playbookItem{name: e.Name(), running: running["claude-"+e.Name()]}
		if info, err := os.Stat(filepath.Join(dir, e.Name(), "sessions")); err == nil {
			pi.lastActive = info.ModTime()
		} else if info, err := os.Stat(filepath.Join(dir, e.Name())); err == nil {
			pi.lastActive = info.ModTime()
		}
		items = append(items, pi)
	}
	sort.Slice(items, func(i, j int) bool {
		// running first, then most-recently active
		if items[i].running != items[j].running {
			return items[i].running
		}
		return items[i].lastActive.After(items[j].lastActive)
	})
	out := make([]list.Item, len(items))
	for i, it := range items {
		out[i] = it
	}
	return out
}

func tmuxRunningSet() map[string]bool {
	out, err := exec.Command("tmux", "list-sessions", "-F", "#{session_name}").Output()
	if err != nil {
		return map[string]bool{}
	}
	set := map[string]bool{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		set[line] = true
	}
	return set
}

func newModel(notice string) model {
	delegate := list.NewDefaultDelegate()
	delegate.ShowDescription = false
	delegate.SetSpacing(0)

	sessionsList := list.New(loadSessions(), delegate, 60, 20)
	sessionsList.Title = "webterm — tmux sessions"
	sessionsList.SetShowStatusBar(false)
	sessionsList.SetShowHelp(false)
	sessionsList.SetFilteringEnabled(true)
	sessionExtra := func() []key.Binding {
		return []key.Binding{
			key.NewBinding(key.WithKeys("n"), key.WithHelp("n", "new")),
			key.NewBinding(key.WithKeys("p"), key.WithHelp("p", "playbooks")),
			key.NewBinding(key.WithKeys("s"), key.WithHelp("s", "shell")),
			key.NewBinding(key.WithKeys("r"), key.WithHelp("r", "refresh")),
			key.NewBinding(key.WithKeys("q"), key.WithHelp("q", "quit")),
		}
	}
	sessionsList.AdditionalShortHelpKeys = sessionExtra
	sessionsList.AdditionalFullHelpKeys = sessionExtra

	playbookList := list.New(loadPlaybooks(), delegate, 60, 20)
	playbookList.Title = "webterm — Claude playbooks"
	playbookList.SetShowStatusBar(false)
	playbookList.SetShowHelp(false)
	playbookList.SetFilteringEnabled(true)
	playbookExtra := func() []key.Binding {
		return []key.Binding{
			key.NewBinding(key.WithKeys("enter"), key.WithHelp("⏎", "attach/start")),
			key.NewBinding(key.WithKeys("k"), key.WithHelp("k", "kill")),
			key.NewBinding(key.WithKeys("p"), key.WithHelp("p", "sessions")),
			key.NewBinding(key.WithKeys("r"), key.WithHelp("r", "refresh")),
			key.NewBinding(key.WithKeys("q"), key.WithHelp("q", "quit")),
		}
	}
	playbookList.AdditionalShortHelpKeys = playbookExtra
	playbookList.AdditionalFullHelpKeys = playbookExtra

	ti := textinput.New()
	ti.Placeholder = "session name"
	ti.CharLimit = 64
	ti.Width = 32

	return model{state: viewList, list: sessionsList, playbookList: playbookList, input: ti, notice: notice}
}

func (m model) Init() tea.Cmd { return nil }

const topReserve = 3 // notice line + help line + blank

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.list.SetSize(msg.Width, msg.Height-topReserve)
		m.playbookList.SetSize(msg.Width, msg.Height-topReserve)
		return m, nil
	case tea.KeyMsg:
		switch m.state {
		case viewList:
			if m.list.FilterState() == list.Filtering {
				break
			}
			switch msg.String() {
			case "q", "ctrl+c":
				m.choice = "QUIT"
				return m, tea.Quit
			case "s":
				m.choice = "SHELL"
				return m, tea.Quit
			case "p":
				m.state = viewPlaybooks
				m.playbookList.SetItems(loadPlaybooks())
				m.notice = ""
				return m, nil
			case "n":
				m.state = viewNew
				m.input.SetValue("")
				m.input.Focus()
				return m, textinput.Blink
			case "r":
				m.list.SetItems(loadSessions())
				m.notice = ""
				return m, nil
			case "enter":
				if it, ok := m.list.SelectedItem().(sessionItem); ok {
					m.choice = "ATTACH:" + it.name
					return m, tea.Quit
				}
			}
		case viewPlaybooks:
			if m.playbookList.FilterState() == list.Filtering {
				break
			}
			switch msg.String() {
			case "q", "ctrl+c":
				m.choice = "QUIT"
				return m, tea.Quit
			case "p":
				m.state = viewList
				m.list.SetItems(loadSessions())
				m.notice = ""
				return m, nil
			case "r":
				m.playbookList.SetItems(loadPlaybooks())
				m.notice = ""
				return m, nil
			case "k":
				if it, ok := m.playbookList.SelectedItem().(playbookItem); ok {
					m.choice = "KILL_PLAYBOOK:" + it.name
					return m, tea.Quit
				}
			case "enter":
				if it, ok := m.playbookList.SelectedItem().(playbookItem); ok {
					m.choice = "ATTACH_PLAYBOOK:" + it.name
					return m, tea.Quit
				}
			}
		case viewNew:
			switch msg.String() {
			case "esc":
				m.state = viewList
				return m, nil
			case "ctrl+c":
				m.choice = "QUIT"
				return m, tea.Quit
			case "enter":
				name := strings.TrimSpace(m.input.Value())
				if name != "" {
					m.choice = "NEW:" + name
					return m, tea.Quit
				}
				return m, nil
			}
			var cmd tea.Cmd
			m.input, cmd = m.input.Update(msg)
			return m, cmd
		}
	}
	switch m.state {
	case viewList:
		var cmd tea.Cmd
		m.list, cmd = m.list.Update(msg)
		return m, cmd
	case viewPlaybooks:
		var cmd tea.Cmd
		m.playbookList, cmd = m.playbookList.Update(msg)
		return m, cmd
	}
	return m, nil
}

var (
	boxStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			Padding(1, 3).
			BorderForeground(lipgloss.Color("63"))

	faint = lipgloss.NewStyle().Faint(true)

	noticeStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("203")).
			Bold(true)
)

func (m model) View() string {
	if m.state == viewNew {
		return "\n" + boxStyle.Render(
			"new tmux session\n\n"+m.input.View()+"\n\n"+
				faint.Render("[enter] create   [esc] cancel"),
		)
	}

	var noticeLine string
	if m.notice != "" {
		noticeLine = noticeStyle.Render("⚠ " + m.notice)
	} else {
		noticeLine = " "
	}

	switch m.state {
	case viewPlaybooks:
		helpLine := m.playbookList.Help.View(m.playbookList)
		return noticeLine + "\n" + helpLine + "\n\n" + m.playbookList.View()
	default:
		helpLine := m.list.Help.View(m.list)
		return noticeLine + "\n" + helpLine + "\n\n" + m.list.View()
	}
}

func runChild(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()
	return cmd.Run()
}

// runChildEnv is like runChild but lets the caller append env vars (KEY=VAL).
func runChildEnv(extraEnv []string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = append(os.Environ(), extraEnv...)
	return cmd.Run()
}

func attachOrStartPlaybook(name string) error {
	dir := filepath.Join(playbooksDir(), name)
	session := "claude-" + name
	// CLAUDE_CONFIG_DIR must be set BEFORE tmux creates the session for new
	// sessions; existing sessions ignore this (env was captured at creation).
	return runChildEnv(
		[]string{"CLAUDE_CONFIG_DIR=" + dir},
		"tmux", "new", "-A", "-s", session, "claude",
	)
}

func main() {
	notice := ""
	// Auto-attach mode: if argv[1] is set (via ttyd -a / URL ?arg=name),
	// attach-or-create that tmux session and skip the picker. URL-decode the
	// arg so session names with slashes etc. survive the round trip through
	// ttyd's URL-arg machinery (which we can't make accept literal slashes).
	if len(os.Args) > 1 && os.Args[1] != "" {
		name := decodeArg(os.Args[1])
		if err := runChild("tmux", "new", "-A", "-s", name); err == nil {
			// tmux exited cleanly — user Ctrl-D'd or the session was killed.
			// Block here instead of returning. If we returned, ttyd would see
			// the chooser exit and offer "Press Enter to Reconnect", and the
			// reconnect would silently `tmux new -A` a fresh session with the
			// same name — which looks to the user like the killed session
			// "came back". Blocking parks the WebSocket: the user closes the
			// tab to give up, or refreshes to deliberately start over.
			fmt.Print("\r\n\r\n")
			fmt.Printf("\033[33msession '%s' ended.\033[0m\r\n", name)
			fmt.Print("\033[2mclose this tab, or refresh to start a fresh session.\033[0m\r\n")
			select {} // block until ttyd sends SIGTERM (tab closed)
		}
		notice = fmt.Sprintf("could not attach/create %q — pick another", name)
	}
	for {
		p := tea.NewProgram(newModel(notice), tea.WithAltScreen())
		final, err := p.Run()
		if err != nil {
			fmt.Fprintln(os.Stderr, "chooser:", err)
			os.Exit(1)
		}
		notice = ""
		m, _ := final.(model)
		switch {
		case m.choice == "" || m.choice == "QUIT":
			return
		case m.choice == "SHELL":
			sh := os.Getenv("SHELL")
			if sh == "" {
				sh = "/bin/bash"
			}
			runChild(sh, "-l")
		case strings.HasPrefix(m.choice, "ATTACH:"):
			name := strings.TrimPrefix(m.choice, "ATTACH:")
			if err := runChild("tmux", "attach", "-t", name); err != nil {
				notice = fmt.Sprintf("could not attach to %q — session may be gone (refreshed)", name)
			}
		case strings.HasPrefix(m.choice, "NEW:"):
			name := strings.TrimPrefix(m.choice, "NEW:")
			if err := runChild("tmux", "new", "-s", name); err != nil {
				notice = fmt.Sprintf("could not create %q: %v", name, err)
			}
		case strings.HasPrefix(m.choice, "ATTACH_PLAYBOOK:"):
			name := strings.TrimPrefix(m.choice, "ATTACH_PLAYBOOK:")
			if err := attachOrStartPlaybook(name); err != nil {
				notice = fmt.Sprintf("could not attach playbook %q: %v", name, err)
			}
		case strings.HasPrefix(m.choice, "KILL_PLAYBOOK:"):
			name := strings.TrimPrefix(m.choice, "KILL_PLAYBOOK:")
			if err := exec.Command("tmux", "kill-session", "-t", "claude-"+name).Run(); err != nil {
				notice = fmt.Sprintf("could not kill playbook %q (maybe not running)", name)
			} else {
				notice = fmt.Sprintf("killed playbook %q", name)
			}
		}
	}
}
