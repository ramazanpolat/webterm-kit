package main

import (
	"crypto/tls"
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
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

// Service is a user-defined entry in services.json. The dashboard renders one
// card per service under the matching `Category` tab. If `ProxyTo` is set, the
// installer also generates a Caddy reverse_proxy block for the service's URL
// path so it lives under the same hostname.
type Service struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Category    string `json:"category,omitempty"` // tab name: "services" (default), "storage", "media", ...
	Icon        string `json:"icon,omitempty"`     // emoji or single char
	URL         string `json:"url,omitempty"`      // public URL/path the card links to
	ProxyTo     string `json:"proxy_to,omitempty"` // backend like 127.0.0.1:8096 (used by install.sh)
}

// Process is a single listening TCP service discovered via lsof on the host.
// We surface them in the "discover" tab so the user can add unknown services
// (e.g. `opencode --web`) to the dashboard with one click.
type Process struct {
	PID        int    `json:"pid"`
	Command    string `json:"command"`              // short binary name from lsof
	Cmdline    string `json:"cmdline"`              // full command line from `ps`
	User       string `json:"user"`
	Bind       string `json:"bind"`                 // 127.0.0.1, *, ::1, etc.
	Port       int    `json:"port"`
	Kind       string `json:"kind"`                 // "kit" if it's our own infra, "exposed" if already in services.json, "" otherwise
	ServiceURL string `json:"serviceUrl,omitempty"` // path under Caddy if Kind == "exposed"
	Protocol   string `json:"protocol"`             // "http" / "https" / "unknown" — from probeProtocol()
}

// protoCache memoizes protocol probes so /api/processes polls don't reopen
// hundreds of TCP connections per minute. TTL is short enough that a service
// switching its protocol gets noticed within a minute.
var (
	protoCacheMu sync.Mutex
	protoCache   = map[string]protoEntry{}
)

type protoEntry struct {
	protocol string
	fetched  time.Time
}

const protoCacheTTL = 60 * time.Second
const probeTimeout = 200 * time.Millisecond

// detectProtocol tries the cache, then probes if stale or missing. Safe to
// call concurrently from many goroutines.
func detectProtocol(pid int, bind string, port int) string {
	key := fmt.Sprintf("%d:%d", pid, port)
	protoCacheMu.Lock()
	if e, ok := protoCache[key]; ok && time.Since(e.fetched) < protoCacheTTL {
		protoCacheMu.Unlock()
		return e.protocol
	}
	protoCacheMu.Unlock()
	p := probeProtocol(bind, port)
	protoCacheMu.Lock()
	protoCache[key] = protoEntry{protocol: p, fetched: time.Now()}
	protoCacheMu.Unlock()
	return p
}

// probeProtocol opens a connection and tries to identify the protocol.
// Strategy: send a plain-HTTP GET; if the response begins with "HTTP/" it's
// HTTP. Otherwise attempt a TLS handshake — success → HTTPS. Anything else →
// unknown (could be a database, ssh, raw TCP, gRPC-only, etc.).
//
// The dial uses 127.0.0.1 when the listener is bound to "*" / "0.0.0.0" /
// IPv6 wildcards, so we never poke an external interface.
func probeProtocol(bind string, port int) string {
	host := bind
	switch host {
	case "*", "0.0.0.0", "::", "[::]":
		host = "127.0.0.1"
	}
	addr := net.JoinHostPort(host, fmt.Sprintf("%d", port))

	// 1) Plain-HTTP probe.
	if isPlainHTTP(addr, host) {
		return "http"
	}
	// 2) TLS handshake. If the peer can complete one, call it https.
	dialer := &net.Dialer{Timeout: probeTimeout}
	tlsConn, err := tls.DialWithDialer(dialer, "tcp", addr, &tls.Config{InsecureSkipVerify: true})
	if err == nil {
		_ = tlsConn.Close()
		return "https"
	}
	return "unknown"
}

func isPlainHTTP(addr, host string) bool {
	conn, err := net.DialTimeout("tcp", addr, probeTimeout)
	if err != nil {
		return false
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(probeTimeout * 3))
	req := fmt.Sprintf("GET / HTTP/1.0\r\nHost: %s\r\nUser-Agent: webterm-kit-probe/1\r\nConnection: close\r\n\r\n", host)
	if _, err := conn.Write([]byte(req)); err != nil {
		return false
	}
	buf := make([]byte, 8)
	n, _ := conn.Read(buf)
	return n >= 5 && strings.HasPrefix(string(buf[:n]), "HTTP/")
}

// listProcesses runs `lsof -nP -iTCP -sTCP:LISTEN` and parses each row into
// a Process. For each PID it then runs `ps -o command=` once to get the full
// command line (lsof only gives us the basename). Annotates ownership against
// the loaded services list so the SPA can dim already-exposed rows.
func listProcesses(services []Service) []Process {
	out, err := exec.Command("lsof", "-nP", "-iTCP", "-sTCP:LISTEN").Output()
	if err != nil {
		return []Process{}
	}
	// Build a port→service map for the "exposed" annotation. We match on the
	// service's ProxyTo port (last colon-separated chunk).
	exposedByPort := map[int]Service{}
	for _, s := range services {
		if s.ProxyTo == "" {
			continue
		}
		if i := strings.LastIndex(s.ProxyTo, ":"); i > 0 {
			var p int
			fmt.Sscanf(s.ProxyTo[i+1:], "%d", &p)
			if p > 0 {
				exposedByPort[p] = s
			}
		}
	}

	// Cache cmdline lookups to avoid running `ps` twice for the same PID
	// (lsof can list a process more than once with different FDs).
	cmdCache := map[int]string{}
	getCmdline := func(pid int) string {
		if v, ok := cmdCache[pid]; ok {
			return v
		}
		o, err := exec.Command("ps", "-o", "command=", "-p", fmt.Sprint(pid)).Output()
		if err != nil {
			cmdCache[pid] = ""
			return ""
		}
		v := strings.TrimSpace(string(o))
		cmdCache[pid] = v
		return v
	}

	var procs []Process
	seen := map[string]bool{} // dedupe by pid:port
	for i, line := range strings.Split(string(out), "\n") {
		if i == 0 || line == "" {
			continue
		}
		f := strings.Fields(line)
		if len(f) < 9 {
			continue
		}
		// Layout: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME [(LISTEN)]
		var pid int
		fmt.Sscanf(f[1], "%d", &pid)
		// NAME column (always second-to-last when "(LISTEN)" trails) looks like
		// "127.0.0.1:8020" or "*:443" or "[::1]:8021".
		nameCol := f[len(f)-2]
		colon := strings.LastIndex(nameCol, ":")
		if colon < 0 {
			continue
		}
		bind := strings.Trim(nameCol[:colon], "[]")
		var port int
		fmt.Sscanf(nameCol[colon+1:], "%d", &port)
		if port == 0 {
			continue
		}
		key := fmt.Sprintf("%d:%d", pid, port)
		if seen[key] {
			continue
		}
		seen[key] = true

		p := Process{
			PID:     pid,
			Command: f[0],
			User:    f[2],
			Bind:    bind,
			Port:    port,
			Cmdline: getCmdline(pid),
		}
		// Annotate kind. webterm-kit-owned binaries: ttyd, our chooser, our
		// dashboard, caddy run with our config. Heuristic — close enough.
		switch {
		case p.Command == "ttyd",
			strings.Contains(p.Cmdline, "webterm-kit"),
			strings.Contains(p.Cmdline, "/chooser/chooser"),
			strings.Contains(p.Cmdline, "/dashboard/dashboard"):
			p.Kind = "kit"
		}
		if svc, ok := exposedByPort[port]; ok {
			p.Kind = "exposed"
			p.ServiceURL = svc.URL
		}
		procs = append(procs, p)
	}
	// Stable sort: kit/exposed rows last, "addable" rows first; then by port asc.
	sort.SliceStable(procs, func(i, j int) bool {
		ki, kj := rank(procs[i].Kind), rank(procs[j].Kind)
		if ki != kj {
			return ki < kj
		}
		return procs[i].Port < procs[j].Port
	})
	if procs == nil {
		return []Process{}
	}

	// Probe each process for HTTP / HTTPS in parallel. Cached for 60s so
	// frequent /api/processes polls don't reopen a TCP connection per row.
	// Skip the dashboard's own port (it's obviously us, and we'd dead-lock
	// since the probe would queue behind the very handler that called it).
	var wg sync.WaitGroup
	for i := range procs {
		wg.Add(1)
		go func(p *Process) {
			defer wg.Done()
			p.Protocol = detectProtocol(p.PID, p.Bind, p.Port)
		}(&procs[i])
	}
	wg.Wait()
	return procs
}

func rank(kind string) int {
	switch kind {
	case "":
		return 0 // addable
	case "exposed":
		return 1
	case "kit":
		return 2
	}
	return 3
}

// saveServices writes the services list back to disk atomically.
func saveServices(path string, services []Service) error {
	wrapper := map[string]any{"services": services}
	data, err := json.MarshalIndent(wrapper, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// regenerateCaddyfileServices rewrites just the dashboard-managed block of the
// Caddyfile (between the BEGIN/END sentinels installed by install.sh). Caddy
// --watch picks up the change and reloads automatically.
func regenerateCaddyfileServices(caddyfilePath string, services []Service) error {
	const startMarker = "# === BEGIN: webterm-kit auto-generated services ==="
	const endMarker = "# === END: webterm-kit auto-generated services ==="
	data, err := os.ReadFile(caddyfilePath)
	if err != nil {
		return err
	}
	s := string(data)
	startIdx := strings.Index(s, startMarker)
	endIdx := strings.Index(s, endMarker)
	if startIdx < 0 || endIdx < 0 {
		return fmt.Errorf("Caddyfile sentinels not found at %s — re-run install.sh", caddyfilePath)
	}
	var b strings.Builder
	b.WriteString(startMarker + "\n")
	for _, sv := range services {
		if sv.ProxyTo == "" || !strings.HasPrefix(sv.URL, "/") {
			continue
		}
		path := sv.URL
		if !strings.HasSuffix(path, "/") {
			path += "/"
		}
		fmt.Fprintf(&b, "\t# Service: %s\n", sv.Name)
		fmt.Fprintf(&b, "\thandle %s* {\n", path)
		fmt.Fprintf(&b, "\t\treverse_proxy %s\n", sv.ProxyTo)
		fmt.Fprintf(&b, "\t}\n\n")
	}
	b.WriteString(endMarker)
	out := s[:startIdx] + b.String() + s[endIdx+len(endMarker):]
	if err := os.WriteFile(caddyfilePath, []byte(out), 0644); err != nil {
		return err
	}
	// Trigger Caddy reload via its admin API. --watch turned out to be
	// unreliable on macOS (no event for either rename or in-place edit) —
	// admin-API reload is deterministic and fast (~50ms).
	cmd := exec.Command("caddy", "reload", "--config", caddyfilePath)
	if out, err := cmd.CombinedOutput(); err != nil {
		// Don't fail the request if reload fails — the file is updated; the
		// user can manually `caddy reload` or restart Caddy. Just log.
		log.Printf("caddy reload failed (services file written though): %v: %s", err, string(out))
	}
	return nil
}

// loadServices reads the services file. Missing file → empty list (the user
// just hasn't added any services yet — not an error).
func loadServices(path string) []Service {
	if path == "" {
		return []Service{}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("services file %q: %v", path, err)
		}
		return []Service{}
	}
	var wrapper struct {
		Services []Service `json:"services"`
	}
	if err := json.Unmarshal(data, &wrapper); err != nil {
		log.Printf("services file %q: invalid JSON: %v", path, err)
		return []Service{}
	}
	for i := range wrapper.Services {
		if wrapper.Services[i].Category == "" {
			wrapper.Services[i].Category = "services"
		}
	}
	return wrapper.Services
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

// SystemStats is a cheap snapshot of host vitals shown in the dashboard
// header bar. Refreshed at most every 3 seconds (cached) regardless of how
// often the SPA polls. All fields default to zero/empty if their probe fails
// — never fatal, never log spam.
type SystemStats struct {
	CPUPercent  float64 `json:"cpuPct"`
	RAMUsedGB   float64 `json:"ramUsedGB"`
	RAMTotalGB  float64 `json:"ramTotalGB"`
	DiskFreeGB  float64 `json:"diskFreeGB"`
	DiskTotalGB float64 `json:"diskTotalGB"`
	Load1       float64 `json:"load1"`
	UptimeSec   int64   `json:"uptimeSec"`
	// Identity bits for the shell-prompt-style brand line. Don't change once
	// the dashboard starts so they're effectively constant; included here so
	// the SPA can build "user@host:~" without an extra round trip.
	User string `json:"user"`
	Host string `json:"host"`
	Home string `json:"home"`
}

var (
	statsCacheMu      sync.Mutex
	statsCache        SystemStats
	statsCacheFetched time.Time
)

func systemStats() SystemStats {
	statsCacheMu.Lock()
	defer statsCacheMu.Unlock()
	if !statsCacheFetched.IsZero() && time.Since(statsCacheFetched) < 3*time.Second {
		return statsCache
	}
	var s SystemStats
	s.CPUPercent, s.RAMUsedGB, s.RAMTotalGB = topStats()
	s.DiskFreeGB, s.DiskTotalGB = dfStats("/")
	s.Load1 = loadAvg()
	s.UptimeSec = uptimeSec()
	s.User = osUser()
	s.Host = shortHost()
	s.Home = os.Getenv("HOME")
	statsCache = s
	statsCacheFetched = time.Now()
	return s
}

func osUser() string {
	if u := os.Getenv("USER"); u != "" {
		return u
	}
	if u := os.Getenv("LOGNAME"); u != "" {
		return u
	}
	return ""
}

func shortHost() string {
	h, err := os.Hostname()
	if err != nil {
		return ""
	}
	// Strip trailing `.local`, `.lan`, etc. and any FQDN suffix — we want the
	// short label so it matches what the user expects to see.
	if i := strings.IndexByte(h, '.'); i > 0 {
		h = h[:i]
	}
	return h
}

// topStats parses one `top -l 1 -n 0 -s 0` invocation for both CPU% and
// RAM. Bundling lets us pay the ~200ms top startup cost once instead of
// twice.
func topStats() (cpuPct, ramUsedGB, ramTotalGB float64) {
	out, err := exec.Command("top", "-l", "1", "-n", "0", "-s", "0").Output()
	if err != nil {
		return
	}
	s := string(out)
	if m := regexp.MustCompile(`CPU usage:\s+([\d.]+)% user,\s+([\d.]+)% sys`).FindStringSubmatch(s); len(m) >= 3 {
		var user, sys float64
		fmt.Sscanf(m[1], "%f", &user)
		fmt.Sscanf(m[2], "%f", &sys)
		cpuPct = user + sys
	}
	// Lines look like: "PhysMem: 12G used (1825M wired, 4147M compressor), 3814M unused."
	if m := regexp.MustCompile(`PhysMem:\s+([\d.]+)([KMG])\s+used.*?([\d.]+)([KMG])\s+unused`).FindStringSubmatch(s); len(m) >= 5 {
		usedB := parseSize(m[1], m[2])
		unusedB := parseSize(m[3], m[4])
		ramUsedGB = usedB / (1024 * 1024 * 1024)
		ramTotalGB = (usedB + unusedB) / (1024 * 1024 * 1024)
	}
	return
}

func parseSize(numStr, unit string) float64 {
	var n float64
	fmt.Sscanf(numStr, "%f", &n)
	switch unit {
	case "G":
		n *= 1024 * 1024 * 1024
	case "M":
		n *= 1024 * 1024
	case "K":
		n *= 1024
	}
	return n
}

func dfStats(path string) (freeGB, totalGB float64) {
	out, err := exec.Command("df", "-k", path).Output()
	if err != nil {
		return
	}
	lines := strings.Split(string(out), "\n")
	if len(lines) < 2 {
		return
	}
	f := strings.Fields(lines[1])
	if len(f) < 4 {
		return
	}
	var total, avail int64
	fmt.Sscanf(f[1], "%d", &total)
	fmt.Sscanf(f[3], "%d", &avail)
	totalGB = float64(total) / (1024 * 1024)
	freeGB = float64(avail) / (1024 * 1024)
	return
}

func loadAvg() float64 {
	out, err := exec.Command("sysctl", "-n", "vm.loadavg").Output()
	if err != nil {
		return 0
	}
	// Output: "{ 1.40 1.50 1.60 }"
	s := strings.Trim(strings.TrimSpace(string(out)), "{ }")
	f := strings.Fields(s)
	if len(f) < 1 {
		return 0
	}
	var v float64
	fmt.Sscanf(f[0], "%f", &v)
	return v
}

func uptimeSec() int64 {
	out, err := exec.Command("sysctl", "-n", "kern.boottime").Output()
	if err != nil {
		return 0
	}
	// Output: "{ sec = 1234567890, usec = 0 } Wed May  3 ..."
	m := regexp.MustCompile(`sec\s*=\s*(\d+)`).FindStringSubmatch(string(out))
	if len(m) < 2 {
		return 0
	}
	var sec int64
	fmt.Sscanf(m[1], "%d", &sec)
	return time.Now().Unix() - sec
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
	servicesFile := flag.String("services-file", "", "path to services.json (default $HOME/.webterm-kit/services.json)")
	caddyfilePath := flag.String("caddyfile", "", "path to the running Caddyfile, so the dashboard can rewrite the services block when adding new entries")
	flag.Parse()

	if *playbooksDir == "" {
		if env := os.Getenv("PLAYBOOKS_DIR"); env != "" {
			*playbooksDir = env
		} else if home, err := os.UserHomeDir(); err == nil {
			*playbooksDir = filepath.Join(home, ".claude-playbooks")
		}
	}
	if *servicesFile == "" {
		if env := os.Getenv("SERVICES_FILE"); env != "" {
			*servicesFile = env
		} else if home, err := os.UserHomeDir(); err == nil {
			*servicesFile = filepath.Join(home, ".webterm-kit", "services.json")
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

	mux.HandleFunc("/api/services", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		switch r.Method {
		case http.MethodGet:
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]any{
				"services": loadServices(*servicesFile),
			})
		case http.MethodPost:
			var newSvc Service
			if err := json.NewDecoder(r.Body).Decode(&newSvc); err != nil {
				http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
				return
			}
			newSvc.Name = strings.TrimSpace(newSvc.Name)
			if newSvc.Name == "" || newSvc.URL == "" {
				http.Error(w, "name and url are required", http.StatusBadRequest)
				return
			}
			if newSvc.Category == "" {
				newSvc.Category = "services"
			}
			services := loadServices(*servicesFile)
			for _, s := range services {
				if s.Name == newSvc.Name {
					http.Error(w, "service name already exists", http.StatusConflict)
					return
				}
			}
			services = append(services, newSvc)
			if err := saveServices(*servicesFile, services); err != nil {
				http.Error(w, "save failed: "+err.Error(), http.StatusInternalServerError)
				return
			}
			if *caddyfilePath != "" {
				if err := regenerateCaddyfileServices(*caddyfilePath, services); err != nil {
					// Service is saved but Caddy didn't get the route — surface the
					// problem instead of silently 200-ing.
					http.Error(w, "service saved but Caddyfile update failed: "+err.Error(), http.StatusInternalServerError)
					return
				}
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusCreated)
			json.NewEncoder(w).Encode(newSvc)
		case http.MethodDelete:
			name := strings.TrimSpace(r.URL.Query().Get("name"))
			if name == "" {
				http.Error(w, "?name= required", http.StatusBadRequest)
				return
			}
			services := loadServices(*servicesFile)
			kept := make([]Service, 0, len(services))
			found := false
			for _, s := range services {
				if s.Name == name {
					found = true
					continue
				}
				kept = append(kept, s)
			}
			if !found {
				http.Error(w, "no such service", http.StatusNotFound)
				return
			}
			if err := saveServices(*servicesFile, kept); err != nil {
				http.Error(w, "save failed: "+err.Error(), http.StatusInternalServerError)
				return
			}
			if *caddyfilePath != "" {
				_ = regenerateCaddyfileServices(*caddyfilePath, kept)
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})

	mux.HandleFunc("/api/processes", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		json.NewEncoder(w).Encode(map[string]any{
			"processes": listProcesses(loadServices(*servicesFile)),
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

	mux.HandleFunc("/api/system", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		json.NewEncoder(w).Encode(systemStats())
	})

	staticRoot, err := fs.Sub(staticFS, "static")
	if err != nil {
		log.Fatal(err)
	}

	// Serve the same index.html at /, /playbook(/), and /tmux(/). The SPA reads
	// window.location.pathname and hides the irrelevant section. This way the
	// user gets a dedicated list view at /playbook/ and /tmux/ without us
	// duplicating templates server-side.
	indexBytes, err := fs.ReadFile(staticRoot, "index.html")
	if err != nil {
		log.Fatal(err)
	}
	serveIndex := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.Write(indexBytes)
	}
	mux.HandleFunc("/playbook", serveIndex)
	mux.HandleFunc("/playbook/", serveIndex)
	mux.HandleFunc("/tmux", serveIndex)
	mux.HandleFunc("/tmux/", serveIndex)
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
