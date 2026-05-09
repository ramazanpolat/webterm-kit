#!/usr/bin/env bash
# Manage the launchd-installed webterm-kit services. Wraps `launchctl` with
# systemd-style verbs so you don't have to remember bootstrap/bootout/kickstart.
#
# Operates on every label matching ${LABEL_PREFIX}.* (default com.webterm.*).
# Pass --label <name> to operate on just one.
#
# Usage:
#   ./service.sh status              # what's running, what isn't
#   ./service.sh stop                # SIGTERM + bootout — gone until next login
#   ./service.sh start               # bootstrap from ~/Library/LaunchAgents/
#   ./service.sh restart             # kickstart -k (force restart)
#   ./service.sh disable             # bootout + persistently disable (won't start on reboot)
#   ./service.sh enable              # enable + bootstrap (will start now and on reboot)
#
# Differences from launchd jargon:
#   - `stop`    = bootout. The plist stays on disk, so the next login brings
#                  the service back. Equivalent to `systemctl stop` on a
#                  KeepAlive=true unit.
#   - `disable` = bootout + `launchctl disable`. The disabled flag is persistent;
#                  the service won't start on reboot until you `enable` it.
#                  Closer to `systemctl disable` than `launchctl bootout`.
#
# This script does NOT touch the system Caddy daemon (com.webterm.caddy) by
# default — it's a different domain and needs sudo. Pass --include-caddy to
# include it (you'll be prompted for sudo).
set -euo pipefail

PREFIX="${LABEL_PREFIX:-com.webterm}"
UID_VAL=$(id -u)
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
INCLUDE_CADDY=false
ONE_LABEL=""

c_red()    { printf "\033[31m%s\033[0m" "$1"; }
c_green()  { printf "\033[32m%s\033[0m" "$1"; }
c_yellow() { printf "\033[33m%s\033[0m" "$1"; }
c_dim()    { printf "\033[2m%s\033[0m" "$1"; }
say()  { printf "%s %s\n" "$(c_green '==>')" "$*"; }
warn() { printf "%s %s\n" "$(c_yellow '!!')" "$*" >&2; }
die()  { printf "%s %s\n" "$(c_red 'XX')" "$*" >&2; exit 1; }

print_help() {
  sed -n '2,21p' "$0" | sed 's/^# \?//'
}

# --- parse args ---
ACTION=""
while (( $# > 0 )); do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --label)   ONE_LABEL="$2"; shift ;;
    --include-caddy) INCLUDE_CADDY=true ;;
    status|start|stop|restart|enable|disable)
      [[ -n "$ACTION" ]] && die "multiple actions given (had: $ACTION, got: $1)"
      ACTION="$1"
      ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
  shift
done
[[ -z "$ACTION" ]] && { print_help; exit 0; }

# --- resolve target labels ---
shopt -s nullglob
declare -a LABELS=()
if [[ -n "$ONE_LABEL" ]]; then
  LABELS=("$ONE_LABEL")
else
  for plist in "$LAUNCHD_DIR/$PREFIX".*.plist; do
    LABELS+=("$(basename "$plist" .plist)")
  done
fi

if (( ${#LABELS[@]} == 0 )); then
  warn "no plists matching '$PREFIX.*' in $LAUNCHD_DIR — nothing installed yet?"
  warn "run ./install.sh first."
  exit 1
fi

# --- helpers ---
is_running() {
  launchctl print "gui/$UID_VAL/$1" >/dev/null 2>&1
}
is_disabled() {
  # `launchctl print-disabled` lists disabled services in a domain. Cheap-ish.
  launchctl print-disabled "gui/$UID_VAL" 2>/dev/null | grep -qE "\"$1\" => disabled"
}
caddy_running() {
  launchctl print "system/$PREFIX.caddy" >/dev/null 2>&1
}

# --- actions ---
case "$ACTION" in
  status)
    printf "%-26s %-9s %-9s %s\n" LABEL RUNNING DISABLED PID
    for label in "${LABELS[@]}"; do
      pid=""
      if is_running "$label"; then
        pid=$(launchctl print "gui/$UID_VAL/$label" 2>/dev/null \
              | awk '/^\tpid =/ {print $3; exit}')
        running="$(c_green yes)"
      else
        running="$(c_red 'no ')"
      fi
      if is_disabled "$label"; then
        disabled="$(c_yellow yes)"
      else
        disabled="$(c_dim 'no ')"
      fi
      printf "%-26s %-9b %-9b %s\n" "$label" "$running" "$disabled" "${pid:--}"
    done
    if $INCLUDE_CADDY || caddy_running; then
      printf "\n"
      printf "%-26s " "$PREFIX.caddy (system)"
      if caddy_running; then printf "%b\n" "$(c_green 'running')"
      else printf "%b\n" "$(c_red 'not running')"; fi
    fi
    ;;

  start)
    for label in "${LABELS[@]}"; do
      plist="$LAUNCHD_DIR/$label.plist"
      if is_running "$label"; then
        say "$label already running — kickstarting"
        launchctl kickstart "gui/$UID_VAL/$label"
      else
        say "starting $label"
        launchctl bootstrap "gui/$UID_VAL" "$plist"
      fi
    done
    ;;

  stop)
    for label in "${LABELS[@]}"; do
      if is_running "$label"; then
        say "stopping $label"
        launchctl bootout "gui/$UID_VAL/$label"
      else
        c_dim "$label not running"; echo
      fi
    done
    say "stopped (services will respawn at next login unless you also disable)"
    ;;

  restart)
    for label in "${LABELS[@]}"; do
      say "restarting $label"
      launchctl kickstart -k "gui/$UID_VAL/$label" 2>/dev/null \
        || launchctl bootstrap "gui/$UID_VAL" "$LAUNCHD_DIR/$label.plist"
    done
    ;;

  disable)
    for label in "${LABELS[@]}"; do
      say "disabling $label"
      launchctl disable "gui/$UID_VAL/$label" 2>/dev/null || true
      launchctl bootout  "gui/$UID_VAL/$label" 2>/dev/null || true
    done
    say "disabled (services will NOT start on reboot — re-enable with: ./service.sh enable)"
    ;;

  enable)
    for label in "${LABELS[@]}"; do
      plist="$LAUNCHD_DIR/$label.plist"
      say "enabling $label"
      launchctl enable "gui/$UID_VAL/$label" 2>/dev/null || true
      if ! is_running "$label"; then
        launchctl bootstrap "gui/$UID_VAL" "$plist"
      fi
    done
    ;;
esac

# --- caddy daemon (system-level, sudo) ---
if $INCLUDE_CADDY; then
  caddy_label="$PREFIX.caddy"
  caddy_plist="/Library/LaunchDaemons/$caddy_label.plist"
  case "$ACTION" in
    stop|disable)
      if caddy_running; then
        say "stopping Caddy daemon (sudo)"
        sudo launchctl bootout "system/$caddy_label" || true
        if [[ "$ACTION" == "disable" ]]; then
          sudo launchctl disable "system/$caddy_label" 2>/dev/null || true
        fi
      fi
      ;;
    start|enable|restart)
      if [[ -f "$caddy_plist" ]]; then
        say "starting Caddy daemon (sudo)"
        if [[ "$ACTION" == "enable" ]]; then
          sudo launchctl enable "system/$caddy_label" 2>/dev/null || true
        fi
        if caddy_running; then
          sudo launchctl kickstart -k "system/$caddy_label" 2>/dev/null || true
        else
          sudo launchctl bootstrap system "$caddy_plist"
        fi
      fi
      ;;
  esac
fi
