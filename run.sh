#!/usr/bin/env bash
# webterm-kit portable runner. macOS or Linux. No launchd, no sudo, no install.
# Run from inside the cloned repo: ./run.sh
#
# Starts every backend (chooser, dashboard, per-playbook ttyds) and Caddy.
# By default it detaches into the background; stop with ./stop.sh.
# Ports match install.sh (8020/8021/8030+), so portable and installed modes
# are mutually exclusive on the same machine.
#
# Flags:
#   --help          print this and exit
#   -it,--interactive  run in the foreground (Ctrl-C stops it)
#   --tls           HTTPS on :8443 using the Tailscale cert (defaults to HTTP on :8080)
#   --port N        override the Caddy front-door port (default 8080, or 8443 with --tls)
#   --host HOST     hostname for URLs (default: localhost, or tailnet host with --tls)
#   --no-build      skip `go build` (use existing binaries)
set -euo pipefail

USE_TLS=false
FRONT_PORT=""
HOST=""
NO_BUILD=false
INTERACTIVE=false
while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -it|--interactive) INTERACTIVE=true ;;
    --tls)      USE_TLS=true ;;
    --port)     FRONT_PORT="$2"; shift ;;
    --host)     HOST="$2"; shift ;;
    --no-build) NO_BUILD=true ;;
    *) printf "unknown flag: %s\n" "$1" >&2; exit 2 ;;
  esac
  shift
done

ROOT=$(cd "$(dirname "$0")" && pwd)
GENERATED_DIR="$ROOT/generated"
LOG_DIR="$ROOT/logs"
CADDYFILE="$GENERATED_DIR/Caddyfile.dev"

# Backend ports (env-overridable for testing or when a wedged macOS launchd
# socket holds the default port — `lsof` won't show it but `netstat` does).
CHOOSER_PORT="${CHOOSER_PORT:-8020}"
DASHBOARD_PORT="${DASHBOARD_PORT:-8021}"
PLAYBOOK_PORT_BASE="${PLAYBOOK_PORT_BASE:-8030}"
ADMIN_PORT="${ADMIN_PORT:-2020}"   # Caddy admin (different from installed Caddy's :2019)

# macOptionIsMeta: see install.sh for the full explanation. Default false so
# non-US layouts (Turkish-Q, German, French, etc.) can type characters that
# require Option as a modifier — Option+Q for @ on Turkish-Q, etc.
MAC_OPTION_IS_META="${MAC_OPTION_IS_META:-false}"

c_red()    { printf "\033[31m%s\033[0m" "$1"; }
c_green()  { printf "\033[32m%s\033[0m" "$1"; }
c_yellow() { printf "\033[33m%s\033[0m" "$1"; }
c_dim()    { printf "\033[2m%s\033[0m" "$1"; }
say()  { printf "%s %s\n" "$(c_green '==>')" "$*"; }
warn() { printf "%s %s\n" "$(c_yellow '!!')" "$*" >&2; }
die()  { printf "%s %s\n" "$(c_red 'XX')" "$*" >&2; exit 1; }

# --- prereqs (same as install.sh, minus launchctl) ---
declare -a MISSING=()
for cmd in ttyd tmux go caddy python3; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if (( ${#MISSING[@]} > 0 )); then
  die "missing: ${MISSING[*]} (try: brew install ${MISSING[*]})"
fi

# --- defaults that depend on flags ---
if $USE_TLS; then
  FRONT_PORT="${FRONT_PORT:-8443}"
  default_host=""
  if command -v tailscale >/dev/null; then
    default_host=$(tailscale status --self --json 2>/dev/null | python3 -c '
import json, sys
try: print(json.load(sys.stdin).get("Self", {}).get("DNSName", "").rstrip("."))
except Exception: pass
' 2>/dev/null) || true
  fi
  HOST="${HOST:-${default_host:-localhost}}"
  CERT_PATH="$HOME/.tailscale-certs/$HOST.crt"
  KEY_PATH="$HOME/.tailscale-certs/$HOST.key"
  if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
    die "TLS cert not found at $CERT_PATH — either run 'tailscale cert $HOST' or drop without --tls"
  fi
  SCHEME=https
else
  FRONT_PORT="${FRONT_PORT:-8080}"
  HOST="${HOST:-localhost}"
  SCHEME=http
fi

# --- port helpers ---
# Backend ports (chooser/dashboard/playbooks) auto-shift if their preferred
# port is taken, since Caddy is the front door and end users only see the
# host URL. The Caddy front door + admin ports DO die on collision — they're
# user-specified and shifting them silently would change the URL.
port_in_use() {
  local p=$1
  lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  # Capture netstat output, then grep — avoids the `set -o pipefail` +
  # `grep -q` trap where grep matches early, closes its stdin, netstat dies
  # of SIGPIPE (exit 141), pipefail surfaces 141 instead of grep's 0, and
  # the `&& return 0` never fires.
  local ns
  ns=$(netstat -an 2>/dev/null) || true
  printf '%s\n' "$ns" | grep -qE "\.${p}[[:space:]]+.*LISTEN" && return 0
  return 1
}
USED_PORTS=" "
add_port()    { USED_PORTS="$USED_PORTS$1 "; }
already_used(){ [[ "$USED_PORTS" == *" $1 "* ]]; }
pick_port() {
  # Separate `local` lines: `local a=X b=$((a+1))` evaluates `a` from the
  # OUTER scope on bash 3.2, the same way `start_bg`'s log path bit us.
  local start=$1
  local p=$1
  local max=$((start + 100))
  while (( p < max )); do
    if ! already_used "$p" && ! port_in_use "$p"; then echo "$p"; return 0; fi
    p=$((p + 1))
  done
  return 1
}

# --- pick free chooser/dashboard ports ---
CHOOSER_PORT_DEFAULT="$CHOOSER_PORT"
DASHBOARD_PORT_DEFAULT="$DASHBOARD_PORT"
CHOOSER_PORT=$(pick_port "$CHOOSER_PORT")     || die "no free port near $CHOOSER_PORT_DEFAULT"
add_port "$CHOOSER_PORT"
DASHBOARD_PORT=$(pick_port "$DASHBOARD_PORT") || die "no free port near $DASHBOARD_PORT_DEFAULT"
add_port "$DASHBOARD_PORT"
[[ "$CHOOSER_PORT"   != "$CHOOSER_PORT_DEFAULT"   ]] && warn "chooser port shifted: $CHOOSER_PORT_DEFAULT → $CHOOSER_PORT"
[[ "$DASHBOARD_PORT" != "$DASHBOARD_PORT_DEFAULT" ]] && warn "dashboard port shifted: $DASHBOARD_PORT_DEFAULT → $DASHBOARD_PORT"

# --- the front door + admin still hard-fail (user-specified) ---
for pair in "$FRONT_PORT:Caddy front door" "$ADMIN_PORT:Caddy admin"; do
  p="${pair%%:*}"; what="${pair#*:}"
  if port_in_use "$p"; then
    die "port $p is in use ($what). Pass --port N to use a different one; if launchd services are running, ./uninstall.sh first; if a socket is wedged, reboot."
  fi
done

# --- discover playbooks ---
PLAYBOOKS_DIR="${PLAYBOOKS_DIR:-$HOME/.claude-playbooks}"
SERVICES_DIR="${SERVICES_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/webterm-kit}"
SERVICES_FILE="$SERVICES_DIR/services.json"
PLAYBOOKS=()
if [[ -d "$PLAYBOOKS_DIR" ]]; then
  for d in "$PLAYBOOKS_DIR"/*/; do
    name=$(basename "$d")
    [[ -f "$d/CLAUDE.md" ]] || continue
    PLAYBOOKS+=("$name")
  done
fi

# --- pick a free port per playbook ---
declare -a PLAYBOOK_PORTS=()
for pb in "${PLAYBOOKS[@]}"; do
  pp=$(pick_port "$PLAYBOOK_PORT_BASE") || die "no free port near $PLAYBOOK_PORT_BASE for playbook $pb"
  PLAYBOOK_PORTS+=("$pp")
  add_port "$pp"
done

# --- seed services.json if missing (matches install.sh) ---
if [[ ! -f "$SERVICES_FILE" ]]; then
  mkdir -p "$SERVICES_DIR"
  cat > "$SERVICES_FILE" <<'EOF'
{
  "$schema": "see services.example.json in the webterm-kit repo for the schema",
  "services": []
}
EOF
fi

# --- build binaries ---
mkdir -p "$GENERATED_DIR" "$LOG_DIR"
if ! $NO_BUILD; then
  say "building chooser binary"
  (cd "$ROOT/chooser" && go build -o chooser .)
  say "building dashboard binary"
  (cd "$ROOT/dashboard" && go build -o dashboard .)
fi

# --- render dev Caddyfile (HTTP or HTTPS, no TLS redir, no log rotation) ---
# We keep the BEGIN/END sentinels so the dashboard's "add service" UI can
# rewrite that block at runtime, same as in installed mode.
playbook_routes=""
i=0
for pb in "${PLAYBOOKS[@]}"; do
  port="${PLAYBOOK_PORTS[$i]}"
  i=$((i+1))
  playbook_routes+="	# Playbook: $pb"$'\n'
  playbook_routes+="	handle /playbook/$pb/* {"$'\n'
  playbook_routes+="		reverse_proxy 127.0.0.1:$port"$'\n'
  playbook_routes+="	}"$'\n\n'
done

# Service blocks from services.json (same parser as install.sh).
service_inner=$(python3 - <<EOF
import json, sys
try:
    data = json.load(open("$SERVICES_FILE"))
except Exception:
    sys.exit(0)
out = []
for s in data.get("services", []):
    proxy = s.get("proxy_to", "")
    path = s.get("url", "")
    if not proxy or not path or not path.startswith("/"):
        continue
    if not path.endswith("/"):
        path += "/"
    out.append(f"\t# Service: {s.get('name','?')}")
    out.append(f"\thandle {path}* {{")
    out.append(f"\t\treverse_proxy {proxy}")
    out.append(f"\t}}")
    out.append("")
print("\n".join(out))
EOF
)

if $USE_TLS; then
  site_block="${SCHEME}://${HOST}:${FRONT_PORT} {
	tls $CERT_PATH $KEY_PATH"
else
  # Bare `:PORT` matches ANY Host header on that port — so reaching the box
  # via localhost, the LAN IP, or the tailnet hostname all work. Listing
  # specific hosts (`http://localhost:PORT, http://127.0.0.1:PORT`) made
  # tailnet requests fall through to Caddy's default empty 200, which looked
  # like a blank page.
  site_block=":${FRONT_PORT} {"
fi

cat > "$CADDYFILE" <<EOF
# Generated by run.sh (portable mode). Edit run.sh, not this file.
{
	auto_https off
	admin localhost:$ADMIN_PORT
}

$site_block

	redir /chooser /chooser/ 301
	handle /chooser/* {
		reverse_proxy 127.0.0.1:$CHOOSER_PORT
	}

	@tmux_named path_regexp tmux_named ^/tmux/([^/]+)/?$
	handle @tmux_named {
		header Location "/chooser/?arg={re.tmux_named.1}"
		respond "" 302
	}

$playbook_routes	# === BEGIN: webterm-kit auto-generated services ===
$service_inner
	# === END: webterm-kit auto-generated services ===

	handle {
		reverse_proxy 127.0.0.1:$DASHBOARD_PORT
	}

	encode gzip
}
EOF

caddy validate --config "$CADDYFILE" >/dev/null 2>&1 \
  || die "rendered Caddyfile failed validation: caddy validate --config $CADDYFILE"

# Pre-format so Caddy doesn't log "Caddyfile input is not formatted; run
# 'caddy fmt --overwrite' to fix inconsistencies" on every start. The heredoc
# above mixes spaces and tabs deliberately (heredocs strip leading tabs only
# for `<<-`), so just let caddy fmt normalize it.
caddy fmt --overwrite "$CADDYFILE" >/dev/null 2>&1 || true

# --- ttyd flags (mirrors templates/ttyd.sh.tmpl) ---
TTYD_FLAGS=(
  -i 127.0.0.1 -W -a
  -t fontSize=20
  -t 'fontFamily=Menlo, "JetBrains Mono", "SF Mono", Monaco, "Apple Color Emoji", "Apple Symbols", "Hiragino Sans", "Symbola", monospace'
  -t rendererType=dom
  -t cursorBlink=true
  -t cursorStyle=bar
  -t "macOptionIsMeta=$MAC_OPTION_IS_META"
  -t scrollback=10000
  -t disableLeaveAlert=true
  -t 'theme={"background": "#0b0b0f"}'
)

# --- process management ---
PIDFILE="$GENERATED_DIR/run.pid"
declare -a PIDS=()
cleanup() {
  echo
  say "shutting down..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  # Give children 2s to exit cleanly, then SIGKILL anything left.
  sleep 0.5
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  rm -f "$PIDFILE"
  say "stopped."
}

start_bg() {
  # Two separate `local` statements: when both are on one line, $name in the
  # second assignment expands using the OUTER scope (bash binds local names
  # left-to-right but expands all values up front), so $logfile would reuse
  # whatever `name` was set to before start_bg was called.
  local name=$1
  local logfile="$LOG_DIR/$name.log"
  shift
  "$@" >"$logfile" 2>&1 &
  local pid=$!
  PIDS+=("$pid")
  printf "    %-22s pid=%-6s log=%s\n" "$name" "$pid" "$logfile"
}

# Wait up to ~3s for every backend to actually bind — a process can fork off
# successfully but exit immediately with "address already in use" if a wedged
# socket beat us to the port. Without this the whole tree boots, Caddy reports
# success, and the user only finds out via 502 errors.
wait_for_listen() {
  local port=$1 deadline=$((SECONDS + 3))
  while (( SECONDS < deadline )); do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# supervise() = the actual run loop. Spawns every backend, runs Caddy as a
# child, waits on it. The trap cleans up children + the PID file on exit.
# Called either directly (foreground / --interactive) or in a backgrounded
# subshell (default), so a single body covers both modes.
supervise() {
  # The dispatcher below installs the trap and writes $PIDFILE — different in
  # foreground vs background mode (because $$ in a subshell is the *outer*
  # shell's PID and macOS bash 3.2 has no $BASHPID).

  # --- start ttyds ---
  say "starting backends (logs in $LOG_DIR/)"
  start_bg "chooser:$CHOOSER_PORT" \
    ttyd "${TTYD_FLAGS[@]}" -p "$CHOOSER_PORT" -b /chooser/ "$ROOT/chooser/chooser"

  local i=0 pb pb_dir pb_wrapper port
  for pb in "${PLAYBOOKS[@]}"; do
    port="${PLAYBOOK_PORTS[$i]}"
    i=$((i+1))
    pb_dir="$PLAYBOOKS_DIR/$pb"
    pb_wrapper="$GENERATED_DIR/claude-$pb.sh"
    cat > "$pb_wrapper" <<EOF
#!/usr/bin/env bash
export CLAUDE_CONFIG_DIR="$pb_dir"
exec tmux new -A -s "claude-$pb" "claude"
EOF
    chmod +x "$pb_wrapper"
    start_bg "playbook:$pb:$port" \
      ttyd "${TTYD_FLAGS[@]}" -p "$port" -b "/playbook/$pb/" "$pb_wrapper"
  done

  # --- start dashboard ---
  local chooser_url="${SCHEME}://${HOST}:${FRONT_PORT}/chooser/"
  start_bg "dashboard:$DASHBOARD_PORT" \
    "$ROOT/dashboard/dashboard" \
    --bind=127.0.0.1 --port="$DASHBOARD_PORT" \
    --chooser-url="$chooser_url" \
    --playbooks-dir="$PLAYBOOKS_DIR" \
    --services-file="$SERVICES_FILE" \
    --caddyfile="$CADDYFILE"

  # --- verify each backend bound ---
  declare -a UNBOUND=()
  wait_for_listen "$CHOOSER_PORT"   || UNBOUND+=("chooser:$CHOOSER_PORT")
  wait_for_listen "$DASHBOARD_PORT" || UNBOUND+=("dashboard:$DASHBOARD_PORT")
  i=0
  for pb in "${PLAYBOOKS[@]}"; do
    port="${PLAYBOOK_PORTS[$i]}"
    i=$((i+1))
    wait_for_listen "$port" || UNBOUND+=("playbook:$pb:$port")
  done
  if (( ${#UNBOUND[@]} > 0 )); then
    warn "backends failed to bind: ${UNBOUND[*]}"
    warn "see logs in $LOG_DIR/ for the bind error. Caddy will return 502 for these routes."
  fi

  # --- Caddy ---
  # NOT `exec` — that would replace the shell, killing the trap and leaking
  # children. Run Caddy as a child, wait on it, let the trap clean up.
  # Redirect Caddy's per-instance state (autosave.json, instance.uuid, locks/)
  # into ./generated/caddy/ so portable mode stays self-contained. Without
  # this Caddy writes to $XDG_DATA_HOME/caddy (~/Library/Application Support/
  # Caddy on macOS), often root-owned from a previous installed-mode run.
  mkdir -p "$GENERATED_DIR/caddy"
  XDG_DATA_HOME="$GENERATED_DIR" XDG_CONFIG_HOME="$GENERATED_DIR" \
    caddy run --config "$CADDYFILE" --adapter caddyfile &
  local CADDY_PID=$!
  PIDS+=("$CADDY_PID")
  wait "$CADDY_PID"
}

# --- print the URL summary (visible whether we go foreground or background) ---
echo
say "ready: ${SCHEME}://${HOST}:${FRONT_PORT}/"
printf "    %-15s ${SCHEME}://${HOST}:${FRONT_PORT}/\n"             "dashboard"
printf "    %-15s ${SCHEME}://${HOST}:${FRONT_PORT}/chooser/\n"     "chooser"
for pb in "${PLAYBOOKS[@]}"; do
  printf "    %-15s ${SCHEME}://${HOST}:${FRONT_PORT}/playbook/%s/\n" "playbook:$pb" "$pb"
done
echo

# Refuse to start if a previous instance is still running. Detected via
# generated/run.pid containing a live PID.
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  die "already running (pid $(cat "$PIDFILE")). Stop it first: ./stop.sh"
fi
rm -f "$PIDFILE"

if $INTERACTIVE; then
  echo $$ > "$PIDFILE"        # foreground: this script IS the supervisor
  trap cleanup EXIT INT TERM  # trap belongs to this shell
  c_dim "press Ctrl-C to stop everything."
  echo
  supervise
else
  # Background: fork a subshell to be the supervisor. Trap goes inside the
  # subshell so it fires when the subshell exits (e.g. via ./stop.sh sending
  # SIGTERM), NOT when the parent run.sh shell exits a few lines below.
  ( trap cleanup EXIT INT TERM; supervise ) </dev/null >>"$LOG_DIR/run.log" 2>&1 &
  super_pid=$!
  disown "$super_pid" 2>/dev/null || true
  echo "$super_pid" > "$PIDFILE"
  # Give the subshell a moment to start; if it crashes early, surface that.
  sleep 0.5
  if ! kill -0 "$super_pid" 2>/dev/null; then
    rm -f "$PIDFILE"
    die "supervisor exited immediately — see $LOG_DIR/run.log"
  fi
  c_dim "running in background (pid $super_pid). stop with: ./stop.sh"
  echo
  c_dim "for foreground mode use: ./run.sh -it"
  echo
fi
