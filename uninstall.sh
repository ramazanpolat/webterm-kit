#!/usr/bin/env bash
# webterm-kit uninstaller.
# Reverses install.sh: boots out launchd services and deletes generated files.
#
# Flags:
#   --help    print this and exit
#   --purge   also remove the Caddy system daemon (needs sudo) and
#             ~/.config/webterm-kit/ (the services config). Does NOT touch
#             ~/.claude-playbooks/ or ~/.tailscale-certs/.
#   --yes     skip confirmation prompts
set -euo pipefail

PURGE=false
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    --purge) PURGE=true ;;
    --yes|-y) ASSUME_YES=true ;;
    *) printf "unknown flag: %s\n" "$arg" >&2; exit 2 ;;
  esac
done

ROOT=$(cd "$(dirname "$0")" && pwd)
UID_VAL=$(id -u)
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
PREFIX="${LABEL_PREFIX:-com.webterm}"

c_red()    { printf "\033[31m%s\033[0m" "$1"; }
c_green()  { printf "\033[32m%s\033[0m" "$1"; }
c_yellow() { printf "\033[33m%s\033[0m" "$1"; }

say()  { printf "%s %s\n" "$(c_green '==>')" "$*"; }
warn() { printf "%s %s\n" "$(c_yellow '!!')" "$*" >&2; }

confirm() {
  $ASSUME_YES && return 0
  local prompt=$1 default=${2:-N} yn
  read -rp "$prompt " yn
  yn=${yn:-$default}
  [[ "$yn" =~ ^[Yy] ]]
}

# --- user-level launchd services ---
shopt -s nullglob
plists=("$LAUNCHD_DIR/$PREFIX".*.plist)
# Exclude the Caddy plist source (stays in generated/, not LaunchAgents) — but
# the system Caddy daemon plist could legitimately have the same prefix if the
# user copied it from generated/. We never touch /Library/LaunchDaemons/ here
# unless --purge is set.

if (( ${#plists[@]} == 0 )); then
  say "no user services with prefix '$PREFIX' in $LAUNCHD_DIR"
else
  say "removing user services with prefix '$PREFIX'"
  for plist in "${plists[@]}"; do
    label=$(basename "$plist" .plist)
    printf "    bootout %s\n" "$label"
    launchctl bootout "gui/$UID_VAL/$label" 2>/dev/null || true
    rm -f "$plist"
  done
fi

# --- generated files + binaries ---
if [[ -d "$ROOT/generated" ]]; then
  say "removing $ROOT/generated"
  rm -rf "$ROOT/generated"
fi
[[ -f "$ROOT/chooser/chooser"     ]] && rm -f "$ROOT/chooser/chooser"
[[ -f "$ROOT/dashboard/dashboard" ]] && rm -f "$ROOT/dashboard/dashboard"

# --- orphan ttyd / dashboard processes ---
# launchctl bootout sends SIGTERM and waits, but a stuck child (e.g. a hung
# tmux attach) can leave a ttyd process behind. Clean any that match our ports.
orphan_pids=$(pgrep -f "ttyd .* -b /(chooser|playbook)/" 2>/dev/null || true)
if [[ -n "$orphan_pids" ]]; then
  warn "found orphan ttyd processes — killing: $orphan_pids"
  kill $orphan_pids 2>/dev/null || true
fi

# --- machine profile (always removed; it's tiny and re-created by install.sh) ---
host_short=$(hostname -s)
profile_file="$HOME/.claude-profile/machines/$host_short.md"
if [[ -f "$profile_file" ]]; then
  say "removing machine profile $profile_file"
  rm -f "$profile_file"
fi

# --- purge: caddy daemon + services config ---
if $PURGE; then
  caddy_label="$PREFIX.caddy"
  caddy_plist="/Library/LaunchDaemons/$caddy_label.plist"

  if launchctl print "system/$caddy_label" >/dev/null 2>&1; then
    if confirm "Remove the Caddy system daemon ($caddy_label)? Needs sudo. [y/N]:" N; then
      say "removing Caddy daemon (will prompt for sudo)"
      sudo launchctl bootout "system/$caddy_label" 2>/dev/null || true
      sudo rm -f "$caddy_plist"
      say "Caddy daemon removed"
    fi
  elif [[ -f "$caddy_plist" ]]; then
    warn "found stray $caddy_plist (daemon not running) — removing"
    sudo rm -f "$caddy_plist"
  fi

  services_dir="${XDG_CONFIG_HOME:-$HOME/.config}/webterm-kit"
  if [[ -d "$services_dir" ]]; then
    if confirm "Remove $services_dir (services config)? [y/N]:" N; then
      rm -rf "$services_dir"
      say "removed $services_dir"
    fi
  fi
fi

# --- summary ---
echo
say "user-level cleanup done."
if ! $PURGE; then
  echo
  printf "Things that stayed (run with --purge to also remove):\n"
  printf "  Caddy system daemon (if installed): /Library/LaunchDaemons/%s.caddy.plist\n" "$PREFIX"
  printf "  Services config:                    %s/webterm-kit/\n" "${XDG_CONFIG_HOME:-$HOME/.config}"
  echo
  printf "Things that are NEVER touched (yours, not ours):\n"
  printf "  Playbooks:                          %s/.claude-playbooks/\n" "$HOME"
  printf "  TLS certs:                          %s/.tailscale-certs/\n" "$HOME"
  printf "  Logs:                               %s/Library/Logs/%s.*.log\n" "$HOME" "$PREFIX"
fi
