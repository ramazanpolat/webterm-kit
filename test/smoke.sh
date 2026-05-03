#!/usr/bin/env bash
# Smoke tests for a running webterm-kit install.
#
# Assumes the dashboard + ttyds + Caddy are all running and reachable at
# https://$HOST/. Use TAILNET_HOST env or pass --host to override (defaults
# to whatever this Mac's tailscale hostname resolves to).
#
# Exit code is 0 if all tests pass, 1 if any fail. Output is one line per
# test: green ok / red FAIL, then a summary at the end.
#
# What it tests:
#   - GET /  → dashboard HTML (<title>kit</title>)
#   - GET /api/sessions, /api/services, /api/processes, /api/system, /api/status
#     → 200 + valid JSON with the fields we expect
#   - Caddy routing: /chooser/ → ttyd, /chooser (no slash) → 301
#   - Caddy redirect: /tmux/<name>/ → 302 to /chooser/?arg=<name>
#   - Caddy: /playbook/ (no name) → dashboard
#   - HTTP→HTTPS redirect on :80
#   - POST /api/services creates a service (then DELETEs it to leave state clean)
#
# What it does NOT test (would need Tier 2 / Tier 3):
#   - Anything that requires the SPA's JS to actually run
#   - WebSocket upgrades to ttyd
#   - Terminal rendering / keyboard handling
#   - Caddy's --watch reload (timing-sensitive, flaky in tests)
set -uo pipefail

HOST="${TAILNET_HOST:-$(tailscale status --self --json 2>/dev/null \
  | grep -oE '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//')}"
HOST="${HOST:-macminim.tailad422.ts.net}"
URL="https://${HOST}"

# Allow --host override
if [[ "${1:-}" == "--host" && -n "${2:-}" ]]; then
  HOST="$2"; URL="https://${HOST}"
fi

# --- output helpers ---
PASS=0; FAIL=0
green()   { printf "\033[32m%s\033[0m" "$1"; }
red()     { printf "\033[31m%s\033[0m" "$1"; }
dim()     { printf "\033[2m%s\033[0m" "$1"; }
ok()   { PASS=$((PASS+1)); printf "  %s %s\n"   "$(green '✓')" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  %s %s\n  %s\n" "$(red '✗')" "$1" "$(dim "    $2")"; }
section() { printf "\n%s\n" "$1"; }

# --- assertion helpers ---
# Curls $1, asserts HTTP code matches $2, asserts body grep $3 (optional).
http_status() {
  local desc="$1" url="$2" want="$3"
  local got; got=$(curl -sko /dev/null -w '%{http_code}' "$url")
  if [[ "$got" == "$want" ]]; then ok "$desc → $got"
  else fail "$desc" "expected $want, got $got: $url"
  fi
}

http_redirect() {
  local desc="$1" url="$2" want_code="$3" want_loc="$4"
  local out; out=$(curl -skI "$url" 2>/dev/null)
  local code; code=$(printf '%s' "$out" | head -1 | awk '{print $2}')
  local loc;  loc=$(printf '%s' "$out" | grep -i '^location:' | head -1 | awk '{print $2}' | tr -d '\r')
  if [[ "$code" == "$want_code" && "$loc" == "$want_loc" ]]; then
    ok "$desc → $code Location: $loc"
  else
    fail "$desc" "expected $want_code → $want_loc, got $code → $loc"
  fi
}

http_contains() {
  local desc="$1" url="$2" want="$3"
  # --compressed handles gzip from Caddy; without it grep sees binary garbage.
  local body; body=$(curl -sk --compressed "$url")
  if printf '%s' "$body" | grep -q -- "$want"; then ok "$desc"
  else fail "$desc" "missing '$want' in body of $url"
  fi
}

# Like http_contains but checks the Server response header instead of the body
# — useful when the body is hard to grep (binary/JS-bundle/etc).
header_contains() {
  local desc="$1" url="$2" header="$3" want="$4"
  local val; val=$(curl -skI "$url" | grep -i "^${header}:" | head -1)
  if printf '%s' "$val" | grep -q -- "$want"; then ok "$desc"
  else fail "$desc" "$header header missing '$want': $val"
  fi
}

json_has_key() {
  local desc="$1" url="$2" key="$3"
  local body; body=$(curl -sk "$url")
  if printf '%s' "$body" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    keys = '$key'.split('.')
    for k in keys:
        d = d[k] if not k.isdigit() else d[int(k)]
except Exception as e:
    sys.exit(1)
" 2>/dev/null; then ok "$desc → has .$key"
  else fail "$desc" "JSON missing .$key (or not valid JSON)"
  fi
}

# --- header ---
printf "%s\n" "$(dim "smoke tests against $URL")"

# --- core HTTP routes ---
section "$(dim '— core routes —')"
http_status   "GET /"                  "$URL/"                  "200"
http_contains "GET / serves the SPA"   "$URL/"                  "<title>kit</title>"
http_status     "GET /chooser/"         "$URL/chooser/"          "200"
header_contains "/chooser/ → ttyd"      "$URL/chooser/"          "Server" "ttyd"
http_redirect   "GET /chooser → 301"    "$URL/chooser"           "301" "/chooser/"
http_status     "GET /tmux/"            "$URL/tmux/"             "200"
# /tmux/ (no name) falls through to the dashboard, which serves the SPA;
# the SPA's pageMode JS hides the playbooks section client-side.
http_contains   "/tmux/ serves SPA"     "$URL/tmux/"             "<title>kit</title>"
http_redirect   "GET /tmux/foo/ → 302"  "$URL/tmux/foo/"         "302" "/chooser/?arg=foo"
http_status     "GET /playbook/"        "$URL/playbook/"         "200"
http_contains   "/playbook/ serves SPA" "$URL/playbook/"         "<title>kit</title>"

# HTTP→HTTPS upgrade on :80. Caddy's `redir … permanent` issues 301.
http_redirect   "GET http://host → 301" "http://${HOST}/"        "301" "${URL}/"

# --- API endpoints (JSON shape) ---
section "$(dim '— API ($URL/api/*) —')"
json_has_key  "GET /api/sessions"      "$URL/api/sessions"      "sessions"
json_has_key  "GET /api/sessions"      "$URL/api/sessions"      "playbooks"
json_has_key  "GET /api/sessions"      "$URL/api/sessions"      "chooserUrl"
json_has_key  "GET /api/services"      "$URL/api/services"      "services"
json_has_key  "GET /api/processes"     "$URL/api/processes"     "processes"
json_has_key  "GET /api/system"        "$URL/api/system"        "cpuPct"
json_has_key  "GET /api/system"        "$URL/api/system"        "ramTotalGB"
json_has_key  "GET /api/system"        "$URL/api/system"        "diskFreeGB"
json_has_key  "GET /api/system"        "$URL/api/system"        "user"
json_has_key  "GET /api/system"        "$URL/api/system"        "host"
json_has_key  "GET /api/status"        "$URL/api/status"        "entries"
json_has_key  "GET /api/status"        "$URL/api/status"        "now"

# --- mutations: add a service, verify it's returned, delete it ---
section "$(dim '— mutations (POST /api/services) —')"
TEST_NAME="smoke-$$-$(date +%s)"
TEST_PAYLOAD=$(printf '{"name":"%s","category":"services","url":"https://example.com/","description":"smoke test"}' "$TEST_NAME")
post_code=$(curl -sko /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$TEST_PAYLOAD" "$URL/api/services")
if [[ "$post_code" == "201" ]]; then
  ok "POST /api/services → 201"
  # Verify it shows up in GET
  if curl -sk "$URL/api/services" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
sys.exit(0 if any(s.get('name') == '$TEST_NAME' for s in d.get('services', [])) else 1)
" 2>/dev/null; then
    ok "GET /api/services contains test entry"
  else
    fail "GET /api/services contains test entry" "service '$TEST_NAME' not found"
  fi
  # Cleanup
  del_code=$(curl -sko /dev/null -w '%{http_code}' -X DELETE "$URL/api/services?name=$TEST_NAME")
  if [[ "$del_code" == "204" ]]; then ok "DELETE /api/services?name=$TEST_NAME → 204"
  else fail "cleanup DELETE failed" "got $del_code"
  fi
else
  fail "POST /api/services → 201" "got $post_code"
fi

# --- summary ---
echo
TOTAL=$((PASS + FAIL))
if (( FAIL == 0 )); then
  printf "%s  %d/%d passed\n" "$(green '==')" "$PASS" "$TOTAL"
  exit 0
else
  printf "%s  %d passed, %d failed (of %d)\n" "$(red '==')" "$PASS" "$FAIL" "$TOTAL"
  exit 1
fi
