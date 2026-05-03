package main

import (
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

//go:embed static
var staticFS embed.FS

type Pane struct {
	Window  int    `json:"window"`
	Pane    int    `json:"pane"`
	Command string `json:"command"`
	Title   string `json:"title"`
}

type Session struct {
	Name     string `json:"name"`
	Attached int    `json:"attached"`
	Windows  int    `json:"windows"`
	Panes    []Pane `json:"panes"`
}

type Playbook struct {
	Name       string `json:"name"`
	Running    bool   `json:"running"`
	LastActive int64  `json:"lastActive"` // unix seconds, 0 if unknown
	URL        string `json:"url"`        // path under the Caddy host
}

type StatusEntry struct {
	Playbook   string `json:"playbook"`
	Running    bool   `json:"running"`
	LastActive int64  `json:"lastActive"`
	PID        int    `json:"pid"` // tmux session PID, 0 if not running
}

func listSessions() []Session {
	// Field separator is the two-byte literal "\t" (raw string, not "\t" which
	// is a real tab). tmux's -F output passes this through; if we sent a real
	// tab it'd be replaced with "_" by tmux's non-printable sanitization.
	cmd := exec.Command("tmux", "list-sessions",
		"-F", `#{session_name}\t#{session_attached}\t#{session_windows}`)
	out, err := cmd.Output()
	if err != nil {
		stderr := ""
		if exitErr, ok := err.(*exec.ExitError); ok {
			stderr = strings.TrimSpace(string(exitErr.Stderr))
		}
		log.Printf("tmux list-sessions failed: %v (stderr: %q)", err, stderr)
		return []Session{}
	}
	byName := map[string]*Session{}
	var order []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		parts := strings.Split(line, `\t`)
		if len(parts) < 3 {
			continue
		}
		var att, wins int
		fmt.Sscanf(parts[1], "%d", &att)
		fmt.Sscanf(parts[2], "%d", &wins)
		s := &Session{Name: parts[0], Attached: att, Windows: wins, Panes: []Pane{}}
		byName[parts[0]] = s
		order = append(order, parts[0])
	}

	out, err = exec.Command("tmux", "list-panes", "-a",
		"-F", `#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_current_command}\t#{pane_title}`).Output()
	if err == nil {
		for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			if line == "" {
				continue
			}
			parts := strings.Split(line, `\t`)
			if len(parts) < 5 {
				continue
			}
			s := byName[parts[0]]
			if s == nil {
				continue
			}
			var w, p int
			fmt.Sscanf(parts[1], "%d", &w)
			fmt.Sscanf(parts[2], "%d", &p)
			s.Panes = append(s.Panes, Pane{Window: w, Pane: p, Command: parts[3], Title: parts[4]})
		}
	}

	result := make([]Session, 0, len(order))
	for _, n := range order {
		result = append(result, *byName[n])
	}
	return result
}

// runningSessions returns the set of tmux session names that exist right now.
func runningSessions() map[string]bool {
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

// listPlaybooks scans playbooksDir for subdirs containing a CLAUDE.md.
// Sorted: running first, then by lastActive desc.
func listPlaybooks(playbooksDir string) []Playbook {
	if playbooksDir == "" {
		return []Playbook{}
	}
	entries, err := os.ReadDir(playbooksDir)
	if err != nil {
		return []Playbook{}
	}
	running := runningSessions()
	var pbs []Playbook
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		claudeMd := filepath.Join(playbooksDir, e.Name(), "CLAUDE.md")
		if _, err := os.Stat(claudeMd); err != nil {
			continue
		}
		pb := Playbook{Name: e.Name(), Running: running["claude-"+e.Name()], URL: "/playbook/" + e.Name() + "/"}
		// Prefer sessions/ mtime as a proxy for "last activity"; fall back to
		// the playbook directory's own mtime so something is always shown.
		if info, err := os.Stat(filepath.Join(playbooksDir, e.Name(), "sessions")); err == nil {
			pb.LastActive = info.ModTime().Unix()
		} else if info, err := os.Stat(filepath.Join(playbooksDir, e.Name())); err == nil {
			pb.LastActive = info.ModTime().Unix()
		}
		pbs = append(pbs, pb)
	}
	sort.Slice(pbs, func(i, j int) bool {
		if pbs[i].Running != pbs[j].Running {
			return pbs[i].Running
		}
		return pbs[i].LastActive > pbs[j].LastActive
	})
	if pbs == nil {
		return []Playbook{}
	}
	return pbs
}

// statusEntries combines playbook info with tmux session PIDs for /api/status.
// Cheap to compute (two tmux shellouts), suitable for a phone widget polling
// every few seconds.
func statusEntries(playbooksDir string) []StatusEntry {
	pbs := listPlaybooks(playbooksDir)
	pids := sessionPIDs()
	out := make([]StatusEntry, 0, len(pbs))
	for _, pb := range pbs {
		out = append(out, StatusEntry{
			Playbook:   pb.Name,
			Running:    pb.Running,
			LastActive: pb.LastActive,
			PID:        pids["claude-"+pb.Name],
		})
	}
	return out
}

// sessionPIDs returns map[session_name] -> session_group_pid. tmux exposes the
// group/server pid via #{pid} on the session.
func sessionPIDs() map[string]int {
	out, err := exec.Command("tmux", "list-sessions", "-F", `#{session_name} #{pid}`).Output()
	if err != nil {
		return map[string]int{}
	}
	pids := map[string]int{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		var pid int
		fmt.Sscanf(f[1], "%d", &pid)
		pids[f[0]] = pid
	}
	return pids
}

func main() {
	bind := flag.String("bind", "127.0.0.1", "bind address")
	port := flag.Int("port", 8021, "port")
	certFile := flag.String("cert", "", "TLS cert file (omit for plain HTTP — Caddy in front terminates TLS)")
	keyFile := flag.String("key", "", "TLS key file")
	chooserURL := flag.String("chooser-url", "", "base URL of the chooser ttyd, e.g. https://host/chooser")
	playbooksDir := flag.String("playbooks-dir", "", "path to playbooks root (default $HOME/.claude-playbooks)")
	flag.Parse()

	if *playbooksDir == "" {
		if env := os.Getenv("PLAYBOOKS_DIR"); env != "" {
			*playbooksDir = env
		} else if home, err := os.UserHomeDir(); err == nil {
			*playbooksDir = filepath.Join(home, ".claude-playbooks")
		}
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/api/sessions", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		json.NewEncoder(w).Encode(map[string]any{
			"sessions":   listSessions(),
			"playbooks":  listPlaybooks(*playbooksDir),
			"chooserUrl": *chooserURL,
		})
	})

	mux.HandleFunc("/api/status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		json.NewEncoder(w).Encode(map[string]any{
			"now":     time.Now().Unix(),
			"entries": statusEntries(*playbooksDir),
		})
	})

	staticRoot, err := fs.Sub(staticFS, "static")
	if err != nil {
		log.Fatal(err)
	}
	mux.Handle("/", http.FileServer(http.FS(staticRoot)))

	addr := fmt.Sprintf("%s:%d", *bind, *port)
	scheme := "http"
	if *certFile != "" && *keyFile != "" {
		scheme = "https"
	}
	log.Printf("dashboard listening on %s://%s (playbooks=%s)", scheme, addr, *playbooksDir)
	if scheme == "https" {
		log.Fatal(http.ListenAndServeTLS(addr, *certFile, *keyFile, mux))
	}
	log.Fatal(http.ListenAndServe(addr, mux))
}
