#!/usr/bin/env bash
# Reverse install.sh — boots out launchd services and deletes generated files.
# Logs and the chooser source are left in place.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
UID_VAL=$(id -u)
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
PREFIX="${LABEL_PREFIX:-com.webterm}"

say() { printf "==> %s\n" "$*"; }

shopt -s nullglob
plists=("$LAUNCHD_DIR/$PREFIX".*.plist)

if (( ${#plists[@]} == 0 )); then
  say "no services with prefix '$PREFIX' found in $LAUNCHD_DIR"
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

say "done"
