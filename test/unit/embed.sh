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

# 2. the embed is READABLE verbatim bash (quoted heredocs), NOT an opaque base64 blob — this is the
#    "don't trust us, read us" property: an operator can `less floo-powder` and audit what init sudo-runs.
for f in floo-route floo-authkeys install-relay.sh; do
  grep -qF "cat > \"\$d/$f\" <<'" "$POWDER" && ok "$f embedded as a readable heredoc" || bad "$f heredoc opener missing"
done
# a distinctive line from each source must appear verbatim in floo-powder (proves it's the real code inline)
grep -qF 'ForceCommand /usr/local/bin/floo-route' "$POWDER" && ok "install-relay.sh body is inline + readable" || bad "install-relay.sh body not inline"
grep -qF 'the relay is a DUMB PIVOT' "$POWDER" 2>/dev/null || grep -qF 'DUMB PIVOT' "$POWDER" && ok "floo-route body is inline + readable" || bad "floo-route body not inline"
# guard against a regression back to base64: no enormous single-token line in the embedded block
awk '/BEGIN EMBEDDED RELAY PAYLOAD/{f=1} f{ if ($0 ~ /^[A-Za-z0-9_]+='\''[A-Za-z0-9+\/=]{200,}'\''$/) b=1 } /END EMBEDDED RELAY PAYLOAD/{f=0} END{exit b}' "$POWDER" \
  && ok "no base64 blob in the embedded block (stays readable)" || bad "found a base64-looking blob — embed regressed to opaque"

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
