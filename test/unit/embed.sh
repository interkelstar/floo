#!/usr/bin/env bash
# Unit tests for the embedded relay payload — floo-powder must be self-contained (curl|bash, no
# git clone) AND stay byte-identical to the canonical relay/ source (no silent two-copies drift).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POWDER="$ROOT/bin/floo-powder"
P=0; F=0
ok(){ printf '  \e[32mPASS\e[0m %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  \e[31mFAIL\e[0m %s\n' "$1"; F=$((F+1)); }

echo "=== embedded relay payload ==="

# 1. no drift: the embedded b64 matches a fresh encode of relay/ source
bash "$ROOT/scripts/embed.sh" --check >/dev/null 2>&1 \
  && ok "embedded payload in sync with relay/ source" \
  || bad "DRIFT — run scripts/embed.sh (relay/ edited without re-embedding)"

# 2. the payload vars are actually populated (catches a committed empty placeholder block)
for v in FLOO_EMBED_ROUTE_B64 FLOO_EMBED_AUTHKEYS_B64 FLOO_EMBED_INSTALL_RELAY_B64; do
  grep -qE "^$v='[A-Za-z0-9+/=]+'" "$POWDER" && ok "$v is embedded (non-empty)" || bad "$v is empty/missing"
done

# 3. runtime materialization reproduces every relay/ file byte-for-byte, executable
d=$(mktemp -d)
"$POWDER" relay-extract "$d" >/dev/null 2>&1 || bad "relay-extract failed"
for f in floo-route floo-authkeys install-relay.sh; do
  cmp -s "$d/$f" "$ROOT/relay/$f" && ok "relay-extract reproduces $f exactly" || bad "$f differs after extract"
  [ -x "$d/$f" ] && ok "$f executable after extract" || bad "$f not executable"
done
# the materialized dispatcher is runnable (smoke: unknown command denies cleanly)
SSH_ORIGINAL_COMMAND="nope" bash "$d/floo-route" >/dev/null 2>&1 && bad "materialized floo-route accepted junk" || ok "materialized floo-route runs (denies unknown cmd)"
rm -rf "$d"

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
