#!/usr/bin/env bash
# Stop a backgrounded ./run.sh instance.
# Reads the supervisor PID from generated/run.pid, sends SIGTERM, waits for
# the trap to clean up. Falls through to SIGKILL after 5s if it doesn't exit.
#
# This script does NOT touch the launchd-installed flavor — for that, use
# ./uninstall.sh or `launchctl bootout gui/$UID/com.webterm.<port>`.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
PIDFILE="$ROOT/generated/run.pid"

c_red()   { printf "\033[31m%s\033[0m" "$1"; }
c_green() { printf "\033[32m%s\033[0m" "$1"; }
c_dim()   { printf "\033[2m%s\033[0m" "$1"; }
say()  { printf "%s %s\n" "$(c_green '==>')" "$*"; }
die()  { printf "%s %s\n" "$(c_red 'XX')"  "$*" >&2; exit 1; }

if [[ ! -f "$PIDFILE" ]]; then
  c_dim "no $PIDFILE — webterm-kit isn't running in background mode."; echo
  exit 0
fi

pid=$(cat "$PIDFILE")
if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
  c_dim "stale $PIDFILE (pid $pid not running) — cleaning up."; echo
  rm -f "$PIDFILE"
  exit 0
fi

say "stopping pid ${pid}..."
kill -TERM "$pid"

# Give the supervisor's trap up to 5 seconds to clean up its children.
i=0
while (( i < 50 )); do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PIDFILE"
    say "stopped."
    exit 0
  fi
  sleep 0.1
  i=$((i+1))
done

say "supervisor didn't exit after 5s — forcing"
kill -KILL "$pid" 2>/dev/null || true
rm -f "$PIDFILE"
say "killed."
