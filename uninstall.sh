#!/usr/bin/env bash
# Reverse install.sh — boots out launchd services and deletes generated files.
# Logs and the Go source are left in place.
#
# Caddy is NOT torn down here (it's installed as a system daemon and may be
# used by other services). To remove the Caddy daemon:
#   sudo launchctl bootout system/<LABEL_PREFIX>.caddy
#   sudo rm /Library/LaunchDaemons/<LABEL_PREFIX>.caddy.plist
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
UID_VAL=$(id -u)
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
PREFIX="${LABEL_PREFIX:-com.webterm}"

say() { printf "==> %s\n" "$*"; }

shopt -s nullglob
plists=("$LAUNCHD_DIR/$PREFIX".*.plist)

if (( ${#plists[@]} == 0 )); then
  say "no user services with prefix '$PREFIX' found in $LAUNCHD_DIR"
fi

for plist in "${plists[@]}"; do
  label=$(basename "$plist" .plist)
  say "stopping $label"
  launchctl bootout "gui/$UID_VAL/$label" 2>/dev/null || true
  rm -f "$plist"
done

if [[ -d "$ROOT/generated" ]]; then
  say "removing $ROOT/generated"
  rm -rf "$ROOT/generated"
fi

if [[ -f "$ROOT/chooser/chooser" ]]; then
  rm -f "$ROOT/chooser/chooser"
fi

if [[ -f "$ROOT/dashboard/dashboard" ]]; then
  rm -f "$ROOT/dashboard/dashboard"
fi

say "user-level cleanup done."
say "if Caddy was bootstrapped as a system daemon, remove it manually:"
say "  sudo launchctl bootout system/$PREFIX.caddy"
say "  sudo rm /Library/LaunchDaemons/$PREFIX.caddy.plist"
