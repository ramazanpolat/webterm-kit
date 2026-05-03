package main

import (
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os/exec"
	"strings"
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

func main() {
	bind := flag.String("bind", "127.0.0.1", "bind address")
	port := flag.Int("port", 8021, "port")
	certFile := flag.String("cert", "", "TLS cert file (omit for plain HTTP)")
	keyFile := flag.String("key", "", "TLS key file")
	chooserURL := flag.String("chooser-url", "", "base URL of the chooser ttyd, e.g. https://host:8020")
	flag.Parse()

	mux := http.NewServeMux()

	mux.HandleFunc("/api/sessions", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		json.NewEncoder(w).Encode(map[string]any{
			"sessions":   listSessions(),
			"chooserUrl": *chooserURL,
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
	log.Printf("dashboard listening on %s://%s", scheme, addr)
	if scheme == "https" {
		log.Fatal(http.ListenAndServeTLS(addr, *certFile, *keyFile, mux))
	}
	log.Fatal(http.ListenAndServe(addr, mux))
}
