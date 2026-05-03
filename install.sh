#!/usr/bin/env bash
# webterm-kit installer. macOS only.
# Run from inside the cloned repo: ./install.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
USER_HOME=$HOME
UID_VAL=$(id -u)
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
GENERATED_DIR="$ROOT/generated"

# tmux puts its socket under $TMPDIR/tmux-$UID/. macOS launchd hands each service
# a private TMPDIR, so without this our services would talk to a different tmux
# server than the user's interactive shell. Capture the shell's TMPDIR (or fall
# back to the per-user macOS temp dir) and inject it into the plist.
USER_TMPDIR="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp/)}"

c_red()   { printf "\033[31m%s\033[0m" "$1"; }
c_green() { printf "\033[32m%s\033[0m" "$1"; }
c_dim()   { printf "\033[2m%s\033[0m" "$1"; }

say()  { printf "%s %s\n" "$(c_green '==>')" "$*"; }
warn() { printf "%s %s\n" "$(c_red '!!')" "$*" >&2; }
die()  { warn "$*"; exit 1; }

# --- prereqs ---
check_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing: $1 (try: brew install $1)"; }
check_cmd ttyd
check_cmd tmux
check_cmd go
check_cmd launchctl
[[ "$(uname -s)" == "Darwin" ]] || die "this kit is macOS-only (uses launchd)"

# --- discover or prompt ---
default_host=""
default_ip=""
if command -v tailscale >/dev/null; then
  default_host=$(tailscale status --self --json 2>/dev/null | grep -oE '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//') || true
  default_ip=$(tailscale ip -4 2>/dev/null | head -1) || true
fi

prompt() {
  local var=$1 label=$2 default=$3 val
  if [[ -n "${!var:-}" ]]; then
    return  # already set in env
  fi
  if [[ -n "$default" ]]; then
    read -rp "$label [$default]: " val
    val=${val:-$default}
  else
    read -rp "$label: " val
  fi
  printf -v "$var" '%s' "$val"
}

prompt TAILNET_HOST  "Tailnet hostname (e.g. mymac.tailXXXX.ts.net)"  "$default_host"
prompt BIND_IP       "Bind IP for ttyd (your tailnet IP)"             "$default_ip"
prompt LABEL_PREFIX  "launchd label prefix"                            "com.webterm"

[[ -n "$TAILNET_HOST" ]] || die "TAILNET_HOST is required"
[[ -n "$BIND_IP"     ]] || die "BIND_IP is required"

CERT_PATH="$HOME/.tailscale-certs/$TAILNET_HOST.crt"
KEY_PATH="$HOME/.tailscale-certs/$TAILNET_HOST.key"

if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
  warn "TLS cert not found at $CERT_PATH"
  if command -v tailscale >/dev/null; then
    read -rp "Run 'tailscale cert $TAILNET_HOST' now? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy] ]]; then
      mkdir -p "$HOME/.tailscale-certs"
      (cd "$HOME/.tailscale-certs" && tailscale cert "$TAILNET_HOST")
    else
      die "cannot continue without cert"
    fi
  else
    die "install tailscale or place cert at $CERT_PATH and key at $KEY_PATH"
  fi
fi

# --- pick services ---
# Each entry: name:port:command
SERVICES=(
  "chooser:8020:$ROOT/chooser/chooser"
  "tmux:8022:tmux new -A -s main"
)
command -v zellij >/dev/null && SERVICES+=("zellij:8023:zellij attach --create main")
command -v claude >/dev/null && SERVICES+=("claude:8024:tmux new -A -s claude claude")

# Dashboard: standalone HTTPS Go service (not behind ttyd). Empty string disables.
DASHBOARD_PORT="${DASHBOARD_PORT:-8021}"

say "services to install:"
for svc in "${SERVICES[@]}"; do
  IFS=: read -r name port cmd <<< "$svc"
  printf "    %-8s port %s  %s\n" "$name" "$port" "$(c_dim "$cmd")"
done
if [[ -n "$DASHBOARD_PORT" ]]; then
  printf "    %-8s port %s  %s\n" "dashboard" "$DASHBOARD_PORT" "$(c_dim "$ROOT/dashboard/dashboard (HTTPS, native Go)")"
fi
read -rp "Proceed? [Y/n]: " yn
[[ "$yn" =~ ^[Nn] ]] && exit 0

# --- build binaries ---
say "building chooser binary"
(cd "$ROOT/chooser" && go build -o chooser .)
if [[ -n "$DASHBOARD_PORT" ]]; then
  say "building dashboard binary"
  (cd "$ROOT/dashboard" && go build -o dashboard .)
fi

# --- generate scripts + plists, bootstrap services ---
mkdir -p "$GENERATED_DIR" "$LAUNCHD_DIR" "$HOME/Library/Logs"

for svc in "${SERVICES[@]}"; do
  IFS=: read -r name port cmd <<< "$svc"
  label="$LABEL_PREFIX.$port"
  script="$GENERATED_DIR/ttyd-$name.sh"
  plist="$LAUNCHD_DIR/$label.plist"

  sed -e "s|__BIND_IP__|$BIND_IP|g" \
      -e "s|__PORT__|$port|g" \
      -e "s|__CERT__|$CERT_PATH|g" \
      -e "s|__KEY__|$KEY_PATH|g" \
      -e "s|__CMD__|$cmd|g" \
      "$ROOT/templates/ttyd.sh.tmpl" > "$script"
  chmod +x "$script"

  sed -e "s|__LABEL__|$label|g" \
      -e "s|__SCRIPT__|$script|g" \
      -e "s|__INSTALL_DIR__|$ROOT|g" \
      -e "s|__USER_HOME__|$USER_HOME|g" \
      -e "s|__TMPDIR__|$USER_TMPDIR|g" \
      "$ROOT/templates/launchd.plist.tmpl" > "$plist"

  plutil -lint "$plist" >/dev/null

  # idempotent bootstrap
  launchctl bootout "gui/$UID_VAL/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_VAL" "$plist"
  say "$label installed (script: $script)"
done

# --- dashboard service (standalone Go HTTPS, not behind ttyd) ---
if [[ -n "$DASHBOARD_PORT" ]]; then
  # Find the chooser port so the dashboard can redirect ?arg=<session> there.
  chooser_port=""
  for svc in "${SERVICES[@]}"; do
    IFS=: read -r n p _ <<< "$svc"
    if [[ "$n" == "chooser" ]]; then chooser_port=$p; break; fi
  done
  : "${chooser_port:=8020}"

  label="$LABEL_PREFIX.$DASHBOARD_PORT"
  script="$GENERATED_DIR/dashboard.sh"
  plist="$LAUNCHD_DIR/$label.plist"

  sed -e "s|__DASHBOARD_BIN__|$ROOT/dashboard/dashboard|g" \
      -e "s|__BIND_IP__|$BIND_IP|g" \
      -e "s|__PORT__|$DASHBOARD_PORT|g" \
      -e "s|__CERT__|$CERT_PATH|g" \
      -e "s|__KEY__|$KEY_PATH|g" \
      -e "s|__CHOOSER_URL__|https://$TAILNET_HOST:$chooser_port|g" \
      "$ROOT/templates/dashboard.sh.tmpl" > "$script"
  chmod +x "$script"

  sed -e "s|__LABEL__|$label|g" \
      -e "s|__SCRIPT__|$script|g" \
      -e "s|__INSTALL_DIR__|$ROOT|g" \
      -e "s|__USER_HOME__|$USER_HOME|g" \
      -e "s|__TMPDIR__|$USER_TMPDIR|g" \
      "$ROOT/templates/launchd.plist.tmpl" > "$plist"
  plutil -lint "$plist" >/dev/null

  launchctl bootout "gui/$UID_VAL/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_VAL" "$plist"
  say "$label installed (script: $script)"
fi

# --- summary ---
echo
say "all set. open these URLs in any device on your tailnet:"
for svc in "${SERVICES[@]}"; do
  IFS=: read -r name port _ <<< "$svc"
  printf "    %-9s https://%s:%s/\n" "$name" "$TAILNET_HOST" "$port"
done
if [[ -n "$DASHBOARD_PORT" ]]; then
  printf "    %-9s https://%s:%s/   (GUI session picker)\n" "dashboard" "$TAILNET_HOST" "$DASHBOARD_PORT"
fi
echo
c_dim "manage with: launchctl print|kickstart|kill|bootout gui/$UID_VAL/<label>"
echo
c_dim "logs: tail -f ~/Library/Logs/$LABEL_PREFIX.<port>.log"
echo
