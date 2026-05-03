#!/usr/bin/env bash
# Exhaustive walkthrough — see test/browser/exhaustive.spec.js for what's
# covered. This wrapper handles setup (spin up a test HTTP server so the
# discover→add→proxy flow has something real to bind to) and teardown
# (kill that server, kill any tmux sessions named exhaust-*).
#
# SAFETY: only kills tmux sessions whose names start with "exhaust-".
# Sessions named claude-*, main, etc. are explicitly left alone.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_PORT=17777
SERVER_PID=""

cleanup() {
  echo
  echo "==> teardown"
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    echo "  killed test http server (pid $SERVER_PID)"
  fi
  # Sweep test-only tmux sessions. Pattern is conservative: must START WITH
  # "exhaust-" so we never touch claude-* or main.
  while read -r session; do
    if [[ "$session" =~ ^exhaust- ]]; then
      tmux kill-session -t "$session" 2>/dev/null && echo "  killed tmux session $session"
    fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
  # Sweep any leftover services with our run-id prefix in case the spec
  # crashed before its own cleanup ran.
  if [[ -f "$HOME/.webterm-kit/services.json" ]]; then
    python3 - "$HOME/.webterm-kit/services.json" <<'PYEOF'
import json, sys, urllib.request, ssl
path = sys.argv[1]
data = json.load(open(path))
keep = [s for s in data.get('services', []) if not s.get('name', '').startswith('exhaust-')]
removed = [s['name'] for s in data.get('services', []) if s.get('name', '').startswith('exhaust-')]
if removed:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    for name in removed:
        req = urllib.request.Request(
            f'https://macminim.tailad422.ts.net/api/services?name={name}',
            method='DELETE')
        try: urllib.request.urlopen(req, context=ctx, timeout=2)
        except Exception: pass
        print(f'  cleaned leftover service: {name}')
PYEOF
  fi
}
trap cleanup EXIT

echo "==> spinning up test HTTP server on 127.0.0.1:$TEST_PORT"
python3 -m http.server "$TEST_PORT" --bind 127.0.0.1 --directory /tmp >/tmp/exhaust-http.log 2>&1 &
SERVER_PID=$!
sleep 1
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "  test server failed to start — see /tmp/exhaust-http.log"
  exit 1
fi
echo "  pid $SERVER_PID listening"

echo "==> running exhaustive Playwright spec"
cd "$ROOT/test/browser"
rm -rf screenshots
npx playwright test exhaustive.spec.js --reporter=line "$@"
RC=$?

if (( RC == 0 )); then
  echo
  echo "==> all exhaustive checks passed"
  echo "  screenshots in $ROOT/test/browser/screenshots/"
fi
exit $RC
