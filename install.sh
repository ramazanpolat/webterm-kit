#!/usr/bin/env bash
# webterm-kit installer. macOS only.
# Run from inside the cloned repo: ./install.sh
#
# What it does:
#   - Auto-discovers playbooks under ~/.claude-playbooks/ (each becomes one
#     ttyd-backed Claude session, tmux-wrapped for resilience).
#   - Caddy on :443 fronts everything with path routing — no port to remember.
#   - Writes ~/.claude-profile/machines/<host>.md so playbooks can @import host info.
#
# Flags:
#   --help     print this and exit
#   --dry-run  show what would happen, touch nothing (no go build, no
#              launchctl, no plist writes)
#   --yes      skip the "Proceed?" confirmation
set -euo pipefail

DRY_RUN=false
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    --dry-run) DRY_RUN=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    *) printf "unknown flag: %s\n" "$arg" >&2; exit 2 ;;
  esac
done

ROOT=$(cd "$(dirname "$0")" && pwd)
USER_HOME=$HOME
UID_VAL=$(id -u)
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
GENERATED_DIR="$ROOT/generated"
CADDYFILE_PATH="$GENERATED_DIR/Caddyfile"

# tmux puts its socket under $TMPDIR/tmux-$UID/. macOS launchd hands each service
# a private TMPDIR, so without this our services would talk to a different tmux
# server than the user's interactive shell. Capture the shell's TMPDIR (or fall
# back to the per-user macOS temp dir) and inject it into the plist.
USER_TMPDIR="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp/)}"

c_red()   { printf "\033[31m%s\033[0m" "$1"; }
c_green() { printf "\033[32m%s\033[0m" "$1"; }
c_yellow(){ printf "\033[33m%s\033[0m" "$1"; }
c_dim()   { printf "\033[2m%s\033[0m" "$1"; }

say()  { printf "%s %s\n" "$(c_green '==>')" "$*"; }
warn() { printf "%s %s\n" "$(c_yellow '!!')" "$*" >&2; }
die()  { printf "%s %s\n" "$(c_red 'XX')" "$*" >&2; exit 1; }

# --- prereqs ---
[[ "$(uname -s)" == "Darwin" ]] || die "this kit is macOS-only (uses launchd)"

# All hard requirements. Each maps to a brew package (or "system" if it ships
# with macOS). The script collects ALL missing prereqs before exiting so the
# user can fix everything in one go instead of one-error-at-a-time.
declare -a MISSING=()
require() {
  local cmd=$1 hint=$2
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd: $hint")
}
require ttyd     "brew install ttyd"
require tmux     "brew install tmux"
require go       "brew install go"
require caddy    "brew install caddy"
require python3  "comes with Xcode CLT — try: xcode-select --install"
require launchctl "(should ship with macOS — something is very wrong)"
require plutil    "(should ship with macOS — something is very wrong)"

if (( ${#MISSING[@]} > 0 )); then
  c_red "Missing prerequisites:"; echo
  for m in "${MISSING[@]}"; do printf "  - %s\n" "$m"; done
  echo
  die "install the listed tools and re-run ./install.sh"
fi

# --- discover or prompt ---
default_host=""
default_ip=""
if command -v tailscale >/dev/null; then
  # Parse DNSName via python3 (newer tailscale's JSON includes whitespace after
  # the colon, which broke the previous grep -oE regex). Trailing dot stripped.
  default_host=$(tailscale status --self --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    n = d.get("Self", {}).get("DNSName", "")
    print(n.rstrip("."))
except Exception:
    pass
' 2>/dev/null) || true
  default_ip=$(tailscale ip -4 2>/dev/null | head -1) || true
fi

prompt() {
  local var=$1 label=$2 default=$3 val
  if [[ -n "${!var:-}" ]]; then
    return
  fi
  # --yes accepts whatever default is offered; no default means we still must
  # prompt (no sane fallback) — honor that and let the user see the question.
  if $ASSUME_YES && [[ -n "$default" ]]; then
    printf -v "$var" '%s' "$default"
    return
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
prompt BIND_IP       "Bind IP for Caddy (your tailnet IP)"             "$default_ip"
prompt LABEL_PREFIX  "launchd label prefix"                            "com.webterm"
PLAYBOOKS_DIR="${PLAYBOOKS_DIR:-$HOME/.claude-playbooks}"
SERVICES_DIR="${SERVICES_DIR:-$HOME/.webterm-kit}"
SERVICES_FILE="$SERVICES_DIR/services.json"

[[ -n "$TAILNET_HOST" ]] || die "TAILNET_HOST is required"
[[ -n "$BIND_IP"     ]] || die "BIND_IP is required"

CERT_PATH="$HOME/.tailscale-certs/$TAILNET_HOST.crt"
KEY_PATH="$HOME/.tailscale-certs/$TAILNET_HOST.key"

if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
  warn "TLS cert not found at $CERT_PATH"
  if $DRY_RUN; then
    warn "dry-run: skipping cert acquisition; you'll need a cert before running for real"
  elif command -v tailscale >/dev/null; then
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

# --- ports ---
# Fixed system services keep their ports for backward compat. Playbooks get
# 8030+. None of these are user-facing — Caddy on :443 is the only public port.
# (The standalone tmux ttyd from v2.0 was dropped in v2.1: /tmux/ now redirects
# to the chooser, which can pick or create any session.)
CHOOSER_PORT=8020
DASHBOARD_PORT="${DASHBOARD_PORT:-8021}"
PLAYBOOK_PORT_BASE=8030

# macOptionIsMeta: when true, xterm.js converts Option+letter into Meta sequences
# (Readline shortcuts like Option+B / Option+F). Great for US keyboards, but on
# layouts that need Option for special chars (Turkish-Q uses Option+Q for @,
# German uses Option for {, French/Spanish/Polish/Czech for various symbols),
# enabling this BREAKS those characters because xterm.js eats Option before the
# OS layout layer can produce the symbol. Default false so all keyboards work;
# set MAC_OPTION_IS_META=true if you're on a US keyboard and want Option-as-Meta.
MAC_OPTION_IS_META="${MAC_OPTION_IS_META:-false}"

# Playbooks live under /playbook/<name>/ so they can't collide with top-level
# routes. We still forbid '/' in playbook names just to keep paths well-formed.

# --- discover playbooks ---
PLAYBOOKS=()
if [[ -d "$PLAYBOOKS_DIR" ]]; then
  for d in "$PLAYBOOKS_DIR"/*/; do
    name=$(basename "$d")
    [[ -f "$d/CLAUDE.md" ]] || continue
    [[ "$name" == *"/"* ]] && die "playbook name '$name' contains '/' — invalid"
    PLAYBOOKS+=("$name")
  done
fi

# --- seed services.json if missing ---
# Empty by default; user adds services with `proxy_to` + `url` + `category` and
# re-runs install.sh. The dashboard reads this file at runtime; install.sh
# reads it to generate Caddy reverse_proxy blocks for any service with proxy_to.
if [[ ! -f "$SERVICES_FILE" ]]; then
  if $DRY_RUN; then
    say "would create empty services file at $SERVICES_FILE"
  else
    mkdir -p "$SERVICES_DIR"
    cat > "$SERVICES_FILE" <<'EOF'
{
  "$schema": "see services.example.json in the webterm-kit repo for the schema",
  "services": []
}
EOF
    say "created empty services file at $SERVICES_FILE"
  fi
fi

# --- show what we'll do ---
say "system services:"
printf "    %-12s 127.0.0.1:%s  -> https://%s/chooser/  (and /tmux/)\n" "chooser"   "$CHOOSER_PORT"   "$TAILNET_HOST"
printf "    %-12s 127.0.0.1:%s  -> https://%s/\n"                       "dashboard" "$DASHBOARD_PORT" "$TAILNET_HOST"

if (( ${#PLAYBOOKS[@]} > 0 )); then
  say "playbooks discovered in $PLAYBOOKS_DIR:"
  i=0
  for pb in "${PLAYBOOKS[@]}"; do
    port=$((PLAYBOOK_PORT_BASE + i))
    printf "    %-12s 127.0.0.1:%s  -> https://%s/playbook/%s/\n" "$pb" "$port" "$TAILNET_HOST" "$pb"
    i=$((i + 1))
  done
else
  warn "no playbooks found in $PLAYBOOKS_DIR (each subdir needs a CLAUDE.md)"
fi

if $DRY_RUN; then
  warn "dry-run mode: no files will be written and no services will be touched"
fi

if ! $ASSUME_YES; then
  read -rp "Proceed? [Y/n]: " yn
  [[ "$yn" =~ ^[Nn] ]] && exit 0
fi

if $DRY_RUN; then
  say "dry-run complete. Re-run without --dry-run to apply."
  exit 0
fi

# --- build binaries ---
say "building chooser binary"
(cd "$ROOT/chooser" && go build -o chooser .)
say "building dashboard binary"
(cd "$ROOT/dashboard" && go build -o dashboard .)

# --- helpers ---
mkdir -p "$GENERATED_DIR" "$LAUNCHD_DIR" "$HOME/Library/Logs"

# Render one ttyd service: writes generated/ttyd-<name>.sh + plist, bootstraps launchd.
# Args: name port base_path command-string
render_ttyd_service() {
  local name="$1" port="$2" base_path="$3" cmd="$4"
  local label="$LABEL_PREFIX.$port"
  local script="$GENERATED_DIR/ttyd-$name.sh"
  local plist="$LAUNCHD_DIR/$label.plist"

  # __CMD__ is intentionally NOT quoted in the template so word-splitting works
  # on the rendered exec line. Keep cmd a single shell-safe string.
  sed -e "s|__PORT__|$port|g" \
      -e "s|__BASE_PATH__|$base_path|g" \
      -e "s|__CMD__|$cmd|g" \
      -e "s|__MAC_OPTION_IS_META__|$MAC_OPTION_IS_META|g" \
      "$ROOT/templates/ttyd.sh.tmpl" > "$script"
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
  say "$label installed"
}

# --- system ttyd services (chooser only; /tmux/ is a Caddy alias for /chooser/) ---
render_ttyd_service "chooser" "$CHOOSER_PORT" "/chooser/" "$ROOT/chooser/chooser"

# --- per-playbook ttyd services ---
# Each playbook gets its own ttyd, its own port, its own tmux session named
# claude-<playbook>. CLAUDE_CONFIG_DIR is exported by the wrapper script BEFORE
# tmux creates the session, so reattach picks up the right config.
i=0
PLAYBOOK_PORTS=()
for pb in "${PLAYBOOKS[@]}"; do
  port=$((PLAYBOOK_PORT_BASE + i))
  PLAYBOOK_PORTS+=("$port")
  i=$((i + 1))

  pb_dir="$PLAYBOOKS_DIR/$pb"
  pb_wrapper="$GENERATED_DIR/claude-$pb.sh"
  cat > "$pb_wrapper" <<EOF
#!/usr/bin/env bash
# Generated. Wraps Claude for playbook '$pb' in a persistent tmux session.
# Set CLAUDE_CONFIG_DIR before tmux so reattach inherits it.
export CLAUDE_CONFIG_DIR="$pb_dir"
exec tmux new -A -s "claude-$pb" "claude"
EOF
  chmod +x "$pb_wrapper"

  render_ttyd_service "$pb" "$port" "/playbook/$pb/" "$pb_wrapper"
done

# --- dashboard service (Go HTTP, fronted by Caddy) ---
# Trailing slash matters: Caddy's `/chooser/*` handler matches /chooser/ and
# /chooser/foo but NOT bare /chooser, which falls through to the dashboard
# catch-all and re-serves the SPA (looks like the link is broken).
chooser_url="https://$TAILNET_HOST/chooser/"
label="$LABEL_PREFIX.$DASHBOARD_PORT"
script="$GENERATED_DIR/dashboard.sh"
plist="$LAUNCHD_DIR/$label.plist"

sed -e "s|__DASHBOARD_BIN__|$ROOT/dashboard/dashboard|g" \
    -e "s|__PORT__|$DASHBOARD_PORT|g" \
    -e "s|__CHOOSER_URL__|$chooser_url|g" \
    -e "s|__PLAYBOOKS_DIR__|$PLAYBOOKS_DIR|g" \
    -e "s|__SERVICES_FILE__|$SERVICES_FILE|g" \
    -e "s|__CADDYFILE__|$CADDYFILE_PATH|g" \
    -e "s|__TAILNET_HOST__|$TAILNET_HOST|g" \
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
say "$label installed (dashboard)"

# --- render Caddyfile ---
say "rendering Caddyfile"
playbook_routes=""
i=0
for pb in "${PLAYBOOKS[@]}"; do
  port="${PLAYBOOK_PORTS[$i]}"
  i=$((i + 1))
  playbook_routes+="	# Playbook: $pb"$'\n'
  playbook_routes+="	handle /playbook/$pb/* {"$'\n'
  playbook_routes+="		reverse_proxy 127.0.0.1:$port"$'\n'
  playbook_routes+="	}"$'\n\n'
done

# --- service routes (from services.json) ---
# Each service with both `proxy_to` and `url` (a path starting with /) gets a
# Caddy reverse_proxy block. Services with only `url` (e.g. external links) are
# launcher-cards-only — no Caddy entry. Uses python3 (ships with macOS) to
# parse the JSON; we'd add a jq prereq if Python ever stops being a given.
#
# The whole block is wrapped in BEGIN/END sentinel comments so the dashboard
# can rewrite just this region when the user adds a service via /api/services
# (POST). install.sh always emits the sentinels, even with zero services.
service_inner=""
if [[ -f "$SERVICES_FILE" ]] && command -v python3 >/dev/null; then
  service_inner=$(python3 - <<EOF
import json, sys
try:
    data = json.load(open("$SERVICES_FILE"))
except Exception as e:
    print(f"# WARN: services.json failed to parse: {e}", file=sys.stderr)
    sys.exit(0)
out = []
for s in data.get("services", []):
    name = s.get("name", "?")
    proxy = s.get("proxy_to", "")
    path = s.get("url", "")
    if not proxy or not path or not path.startswith("/"):
        continue
    if not path.endswith("/"):
        path += "/"
    out.append(f"\t# Service: {name}")
    out.append(f"\thandle {path}* {{")
    out.append(f"\t\treverse_proxy {proxy}")
    out.append(f"\t}}")
    out.append("")
print("\n".join(out))
EOF
)
fi
service_routes="# === BEGIN: webterm-kit auto-generated services ==="$'\n'
# `$(python3 ...)` strips trailing newlines, which can jam the last service's
# closing `}` against the END marker on the same line ("}# === END ===") and
# break Caddy's tokenizer. Re-add the trailing newline if non-empty.
if [[ -n "$service_inner" ]]; then
  service_routes+="$service_inner"$'\n'
fi
service_routes+="# === END: webterm-kit auto-generated services ==="$'\n'
playbook_routes+="$service_routes"$'\n'

# Multi-line replacement: write the rendered routes block to a temp file, then
# sed's `r` reads it in at the sentinel line and `d` drops the sentinel itself.
# (BSD awk on macOS won't accept newlines inside `-v` variables, so we use sed.)
routes_tmp="$GENERATED_DIR/.caddy-routes.tmp"
printf '%s' "$playbook_routes" > "$routes_tmp"
sed -e "/__PLAYBOOK_ROUTES__/r $routes_tmp" -e "/__PLAYBOOK_ROUTES__/d" "$ROOT/templates/Caddyfile.tmpl" \
  | sed -e "s|__TAILNET_HOST__|$TAILNET_HOST|g" \
        -e "s|__BIND_IP__|$BIND_IP|g" \
        -e "s|__CERT__|$CERT_PATH|g" \
        -e "s|__KEY__|$KEY_PATH|g" \
        -e "s|__CHOOSER_PORT__|$CHOOSER_PORT|g" \
        -e "s|__DASHBOARD_PORT__|$DASHBOARD_PORT|g" \
        -e "s|__USER_HOME__|$USER_HOME|g" \
        -e "s|__LABEL_PREFIX__|$LABEL_PREFIX|g" \
  > "$CADDYFILE_PATH"
rm -f "$routes_tmp"

if caddy validate --config "$CADDYFILE_PATH" >/dev/null 2>&1; then
  say "Caddyfile validates"
else
  warn "Caddyfile failed caddy validate — see: caddy validate --config $CADDYFILE_PATH"
fi

# --- caddy launchd helper (system daemon, needs sudo to install) ---
caddy_label="$LABEL_PREFIX.caddy"
caddy_plist_src="$GENERATED_DIR/$caddy_label.plist"
caddy_bin=$(command -v caddy 2>/dev/null || echo "/opt/homebrew/bin/caddy")
sed -e "s|__LABEL__|$caddy_label|g" \
    -e "s|__CADDY_BIN__|$caddy_bin|g" \
    -e "s|__CADDYFILE__|$CADDYFILE_PATH|g" \
    -e "s|__USER_HOME__|$USER_HOME|g" \
    "$ROOT/templates/caddy.plist.tmpl" > "$caddy_plist_src"
plutil -lint "$caddy_plist_src" >/dev/null

# --- machine profile ---
profile_dir="$HOME/.claude-profile/machines"
mkdir -p "$profile_dir"
host_short=$(hostname -s)
profile_file="$profile_dir/$host_short.md"
os_ver=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
arch=$(uname -m)
cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
mem_gb=$(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024))
disk=$(df -h / | awk 'NR==2 {print $2 " total, " $4 " free"}')
local_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "")

cat > "$profile_file" <<EOF
# $host_short

> Generated by webterm-kit installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ"). Re-run to update.

## Identity
- **hostname**: $host_short
- **tailnet host**: $TAILNET_HOST
- **tailnet IP**: $BIND_IP
- **local IP**: ${local_ip:-unknown}

## Hardware
- **arch**: $arch
- **CPU**: $cpu
- **memory**: ${mem_gb} GB
- **disk (/) **: $disk

## OS
- **macOS**: $os_ver

## webterm-kit
- **install root**: $ROOT
- **playbooks dir**: $PLAYBOOKS_DIR
- **dashboard URL**: https://$TAILNET_HOST/
- **playbooks served**: $(IFS=,; echo "${PLAYBOOKS[*]:-none}")
EOF
say "wrote machine profile to $profile_file"

# --- caddy daemon bootstrap ---
# Caddy needs to bind :80/:443 — that requires root, which means a system
# LaunchDaemon under /Library/LaunchDaemons/ rather than a user LaunchAgent.
# We offer to do it for the user (one sudo prompt, idempotent: bootout-then-
# bootstrap). They can decline and run the printed commands themselves.
caddy_system_plist="/Library/LaunchDaemons/$caddy_label.plist"
caddy_running=false
if launchctl print "system/$caddy_label" >/dev/null 2>&1; then
  caddy_running=true
fi

echo
if $caddy_running; then
  say "Caddy daemon already bootstrapped — kicking it to pick up the new Caddyfile"
  if sudo launchctl kickstart -k "system/$caddy_label" 2>/dev/null; then
    say "Caddy reloaded"
  else
    warn "couldn't kick Caddy — try: sudo launchctl kickstart -k system/$caddy_label"
  fi
else
  say "Caddy daemon is not yet bootstrapped (it needs sudo to bind :80/:443)"
  bootstrap_caddy=false
  if $ASSUME_YES; then
    bootstrap_caddy=true
  else
    read -rp "Bootstrap the Caddy system daemon now? [Y/n]: " yn
    [[ ! "$yn" =~ ^[Nn] ]] && bootstrap_caddy=true
  fi
  if $bootstrap_caddy; then
    say "installing $caddy_system_plist (will prompt for sudo)"
    if sudo cp "$caddy_plist_src" "$caddy_system_plist" \
        && sudo chown root:wheel "$caddy_system_plist" \
        && sudo launchctl bootstrap system "$caddy_system_plist"; then
      say "Caddy daemon bootstrapped — :80/:443 are live"
    else
      warn "Caddy bootstrap failed; commands to retry by hand:"
      printf "  sudo cp '%s' '%s'\n" "$caddy_plist_src" "$caddy_system_plist"
      printf "  sudo chown root:wheel '%s'\n" "$caddy_system_plist"
      printf "  sudo launchctl bootstrap system '%s'\n" "$caddy_system_plist"
    fi
  else
    say "to bootstrap Caddy later, run:"
    printf "  sudo cp '%s' '%s'\n" "$caddy_plist_src" "$caddy_system_plist"
    printf "  sudo chown root:wheel '%s'\n" "$caddy_system_plist"
    printf "  sudo launchctl bootstrap system '%s'\n" "$caddy_system_plist"
  fi
fi

# --- summary ---
echo
say "install complete. URLs:"
printf "  https://%s/                  dashboard (start here)\n"                  "$TAILNET_HOST"
printf "  https://%s/chooser/          TUI picker (sessions + playbooks)\n"       "$TAILNET_HOST"
printf "  https://%s/tmux/<name>/      attach-or-create tmux session <name>\n"    "$TAILNET_HOST"
for pb in "${PLAYBOOKS[@]}"; do
  printf "  https://%s/playbook/%s/  → playbook %s\n" "$TAILNET_HOST" "$pb" "$pb"
done
echo
c_dim "smoke test:  TAILNET_HOST=$TAILNET_HOST $ROOT/test/smoke.sh"; echo
c_dim "user logs:   tail -f ~/Library/Logs/$LABEL_PREFIX.<port>.log"; echo
c_dim "manage:      launchctl {print|kickstart|kill|bootout} gui/$UID_VAL/<label>"; echo
echo
