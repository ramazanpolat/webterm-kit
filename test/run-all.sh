#!/usr/bin/env bash
# Run both tiers (smoke + browser) against a live install.
# Tier 3 (manual scenarios) is in test/browser/scenarios.md — humans/AI walk it.
#
# Usage:
#   ./test/run-all.sh                          # uses default tailnet host
#   TAILNET_HOST=foo.ts.net ./test/run-all.sh  # override target
#   SKIP_BROWSER=1 ./test/run-all.sh           # smoke only (no Node deps)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)

green() { printf "\033[32m%s\033[0m" "$1"; }
red()   { printf "\033[31m%s\033[0m" "$1"; }
dim()   { printf "\033[2m%s\033[0m" "$1"; }

step() { printf "\n%s %s\n" "$(green '==>')" "$1"; }

step "tier 1 — smoke (curl)"
"$ROOT/test/smoke.sh"
SMOKE_RC=$?

if [[ "${SKIP_BROWSER:-}" == "1" ]]; then
  step "skipping tier 2 (SKIP_BROWSER=1)"
  exit "$SMOKE_RC"
fi

step "tier 2 — SPA (Playwright)"
if ! command -v node >/dev/null 2>&1; then
  printf "  %s no node found — skipping browser tests\n" "$(red '!!')"
  printf "  %s install Node (brew install node) or run with SKIP_BROWSER=1\n" "$(dim '   ')"
  exit "$SMOKE_RC"
fi

cd "$ROOT/test/browser"
if [[ ! -d node_modules ]]; then
  printf "  %s\n" "$(dim 'first run — installing playwright (~50MB)')"
  npm install --silent
  npx playwright install --with-deps chromium 2>&1 | tail -5
fi
npm test
BROWSER_RC=$?

if (( SMOKE_RC == 0 && BROWSER_RC == 0 )); then
  printf "\n%s tiers 1+2 passed (tier 3 is manual — see test/browser/scenarios.md)\n" "$(green '==')"
  exit 0
fi
printf "\n%s smoke=%d browser=%d\n" "$(red '==')" "$SMOKE_RC" "$BROWSER_RC"
(( SMOKE_RC == 0 )) || exit 1
exit "$BROWSER_RC"
