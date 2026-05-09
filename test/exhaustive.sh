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

# Tailnet host for the cleanup-via-API fallback. Honor $TAILNET_HOST, otherwise
# derive from `tailscale status` like install.sh does. Empty string is fine —
# the fallback path edits services.json directly when the API isn't reachable.
TAILNET_HOST="${TAILNET_HOST:-}"
if [[ -z "$TAILNET_HOST" ]] && command -v tailscale >/dev/null 2>&1; then
  TAILNET_HOST=$(tailscale status --self --json 2>/dev/null | python3 -c '
import json, sys
try: print(json.load(sys.stdin).get("Self", {}).get("DNSName", "").rstrip("."))
except Exception: pass
' 2>/dev/null)
fi
export TAILNET_HOST

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
  # Sweep any leftover services with test prefixes (exhaust-, pw-) in case
  # a spec crashed before its own cleanup ran. Tries the API first; if Caddy
  # is down (connection refused), falls back to editing services.json.
  if [[ -f "$HOME/.config/webterm-kit/services.json" ]]; then
    python3 - "$HOME/.config/webterm-kit/services.json" "$TAILNET_HOST" <<'PYEOF'
import json, sys, urllib.request, ssl
path = sys.argv[1]
host = sys.argv[2] if len(sys.argv) > 2 else ""
data = json.load(open(path))
def istest(s):
    n = s.get('name', '')
    return n.startswith('exhaust-') or n.startswith('pw-')
keep = [s for s in data.get('services', []) if not istest(s)]
removed = [s['name'] for s in data.get('services', []) if istest(s)]
if not removed:
    sys.exit(0)
ctx = ssl.create_default_context()
ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
api_works = bool(host)  # only try API if we have a host
for name in removed:
    if api_works:
        req = urllib.request.Request(
            f'https://{host}/api/services?name={name}',
            method='DELETE')
        try: urllib.request.urlopen(req, context=ctx, timeout=2)
        except Exception: api_works = False
    print(f'  cleaned leftover service: {name}')
if not api_works:
    # Direct edit since the API was unreachable.
    data['services'] = keep
    json.dump(data, open(path, 'w'), indent=2)
    print('  (edited services.json directly — Caddy was down)')
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
INCLUDE_EXTENDED=1 npx playwright test exhaustive.spec.js --reporter=line "$@"
RC=$?

if (( RC == 0 )); then
  echo
  echo "==> all exhaustive checks passed"
  echo "  screenshots in $ROOT/test/browser/screenshots/"
fi
exit $RC
