package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type sessionItem struct {
	name     string
	attached int
}

func (s sessionItem) Title() string {
	if s.attached > 0 {
		return fmt.Sprintf("%s  (attached: %d)", s.name, s.attached)
	}
	return s.name
}
func (s sessionItem) Description() string { return "" }
func (s sessionItem) FilterValue() string { return s.name }

type viewState int

const (
	viewList viewState = iota
	viewNew
)

type model struct {
	state  viewState
	list   list.Model
	input  textinput.Model
	choice string
	notice string
}

func loadItems() []list.Item {
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

func newModel(notice string) model {
	delegate := list.NewDefaultDelegate()
	delegate.ShowDescription = false
	delegate.SetSpacing(0)

	l := list.New(loadItems(), delegate, 60, 20)
	l.Title = "webterm — pick a tmux session"
	l.SetShowStatusBar(false)
	l.SetShowHelp(false)
	l.SetFilteringEnabled(true)
	extra := func() []key.Binding {
		return []key.Binding{
			key.NewBinding(key.WithKeys("n"), key.WithHelp("n", "new")),
			key.NewBinding(key.WithKeys("s"), key.WithHelp("s", "shell")),
			key.NewBinding(key.WithKeys("r"), key.WithHelp("r", "refresh")),
			key.NewBinding(key.WithKeys("q"), key.WithHelp("q", "quit")),
		}
	}
	l.AdditionalShortHelpKeys = extra
	l.AdditionalFullHelpKeys = extra

	ti := textinput.New()
	ti.Placeholder = "session name"
	ti.CharLimit = 64
	ti.Width = 32

	return model{state: viewList, list: l, input: ti, notice: notice}
}

func (m model) Init() tea.Cmd { return nil }

const topReserve = 3 // notice line + help line + blank

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.list.SetSize(msg.Width, msg.Height-topReserve)
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
			case "n":
				m.state = viewNew
				m.input.SetValue("")
				m.input.Focus()
				return m, textinput.Blink
			case "r":
				m.list.SetItems(loadItems())
				m.notice = ""
				return m, nil
			case "enter":
				if it, ok := m.list.SelectedItem().(sessionItem); ok {
					m.choice = "ATTACH:" + it.name
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
	if m.state == viewList {
		var cmd tea.Cmd
		m.list, cmd = m.list.Update(msg)
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
	helpLine := m.list.Help.View(m.list)
	return noticeLine + "\n" + helpLine + "\n\n" + m.list.View()
}

func runChild(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()
	return cmd.Run()
}

func main() {
	notice := ""
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
		}
	}
}
