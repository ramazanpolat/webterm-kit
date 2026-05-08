#!/usr/bin/env bash
# webterm-kit portable runner. macOS or Linux. No launchd, no sudo, no install.
# Run from inside the cloned repo: ./run.sh
#
# Starts every backend (chooser, dashboard, per-playbook ttyds) and Caddy in
# the foreground. Ctrl-C kills them all. Ports match install.sh (8020/8021/
# 8030+), so this and the launchd-installed flavor are mutually exclusive on
# the same machine — run.sh refuses to start if a port is already in use.
#
# Flags:
#   --help          print this and exit
#   --tls           HTTPS on :8443 using the Tailscale cert (defaults to HTTP on :8080)
#   --port N        override the Caddy front-door port (default 8080, or 8443 with --tls)
#   --host HOST     hostname for URLs (default: localhost, or tailnet host with --tls)
#   --no-build      skip `go build` (use existing binaries)
set -euo pipefail

USE_TLS=false
FRONT_PORT=""
HOST=""
NO_BUILD=false
while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
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

# --- port collision check ---
# `lsof -i:<port>` exits 0 if anything's listening. We check chooser/dashboard,
# the front door, and the admin port. Playbook ports are checked lazily as we
# enumerate them.
check_port() {
  local p=$1 what=$2
  # Two checks because they catch different states:
  #  - lsof finds a process bound to the port
  #  - netstat sees LISTEN even when the socket is held by launchd:1 (a
  #    phantom-socket state that survives bootout on macOS until reboot)
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 \
      || netstat -an 2>/dev/null | grep -qE "\.${p}[[:space:]]+.*LISTEN"; then
    die "port $p is in use ($what). If launchd services are running, ./uninstall.sh first; if a socket is wedged, reboot."
  fi
}
check_port "$CHOOSER_PORT"   chooser
check_port "$DASHBOARD_PORT" dashboard
check_port "$FRONT_PORT"     "Caddy front door"
check_port "$ADMIN_PORT"     "Caddy admin"

# --- discover playbooks ---
PLAYBOOKS_DIR="${PLAYBOOKS_DIR:-$HOME/.claude-playbooks}"
SERVICES_DIR="${SERVICES_DIR:-$HOME/.webterm-kit}"
SERVICES_FILE="$SERVICES_DIR/services.json"
PLAYBOOKS=()
if [[ -d "$PLAYBOOKS_DIR" ]]; then
  for d in "$PLAYBOOKS_DIR"/*/; do
    name=$(basename "$d")
    [[ -f "$d/CLAUDE.md" ]] || continue
    PLAYBOOKS+=("$name")
  done
fi
i=0
for pb in "${PLAYBOOKS[@]}"; do
  check_port $((PLAYBOOK_PORT_BASE + i)) "playbook $pb"
  i=$((i+1))
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
  port=$((PLAYBOOK_PORT_BASE + i))
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
  site_block="http://${HOST}:${FRONT_PORT}, http://127.0.0.1:${FRONT_PORT} {"
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
declare -a PIDS=()
cleanup() {
  echo
  say "shutting down…"
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
  say "stopped."
}
trap cleanup EXIT INT TERM

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

# --- start ttyds ---
say "starting backends (logs in $LOG_DIR/)"
start_bg "chooser:$CHOOSER_PORT" \
  ttyd "${TTYD_FLAGS[@]}" -p "$CHOOSER_PORT" -b /chooser/ "$ROOT/chooser/chooser"

i=0
for pb in "${PLAYBOOKS[@]}"; do
  port=$((PLAYBOOK_PORT_BASE + i))
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
chooser_url="${SCHEME}://${HOST}:${FRONT_PORT}/chooser/"
start_bg "dashboard:$DASHBOARD_PORT" \
  "$ROOT/dashboard/dashboard" \
  --bind=127.0.0.1 --port="$DASHBOARD_PORT" \
  --chooser-url="$chooser_url" \
  --playbooks-dir="$PLAYBOOKS_DIR" \
  --services-file="$SERVICES_FILE" \
  --caddyfile="$CADDYFILE"

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

declare -a UNBOUND=()
wait_for_listen "$CHOOSER_PORT"   || UNBOUND+=("chooser:$CHOOSER_PORT")
wait_for_listen "$DASHBOARD_PORT" || UNBOUND+=("dashboard:$DASHBOARD_PORT")
i=0
for pb in "${PLAYBOOKS[@]}"; do
  port=$((PLAYBOOK_PORT_BASE + i))
  i=$((i+1))
  wait_for_listen "$port" || UNBOUND+=("playbook:$pb:$port")
done

if (( ${#UNBOUND[@]} > 0 )); then
  warn "backends failed to bind: ${UNBOUND[*]}"
  warn "see logs in $LOG_DIR/ for the bind error. Caddy will return 502 for these routes."
fi

echo
say "ready: ${SCHEME}://${HOST}:${FRONT_PORT}/"
printf "    %-15s ${SCHEME}://${HOST}:${FRONT_PORT}/\n"             "dashboard"
printf "    %-15s ${SCHEME}://${HOST}:${FRONT_PORT}/chooser/\n"     "chooser"
for pb in "${PLAYBOOKS[@]}"; do
  printf "    %-15s ${SCHEME}://${HOST}:${FRONT_PORT}/playbook/%s/\n" "playbook:$pb" "$pb"
done
echo
c_dim "press Ctrl-C to stop everything."
echo

# --- Caddy in the foreground (Ctrl-C delivers SIGINT here, then trap fires) ---
# --adapter caddyfile is implicit when the file matches the canonical name; we
# pass it explicitly so the .dev suffix doesn't confuse the adapter.
#
# NOTE: NOT `exec` — exec would replace the shell with Caddy, which means the
# EXIT trap never fires and all the backgrounded ttyds + dashboard survive
# Ctrl-C as orphans. Run Caddy as a child, wait on it, let the trap clean up.
caddy run --config "$CADDYFILE" --adapter caddyfile &
CADDY_PID=$!
PIDS+=("$CADDY_PID")
wait "$CADDY_PID"
