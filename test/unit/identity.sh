#!/usr/bin/env bash
set -uo pipefail
FLOO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/floo"
P=0; F=0; ok(){ echo "  PASS $1"; P=$((P+1)); }; bad(){ echo "  FAIL $1"; F=$((F+1)); }
[ "$(env FLOO_NAME=flagwin "$FLOO" --print-name 2>/dev/null)" = flagwin ] && ok "FLOO_NAME wins" || bad "FLOO_NAME"
HOOK=$(mktemp); printf '#!/bin/sh\necho hookname\n' > "$HOOK"; chmod +x "$HOOK"
[ "$(env -u FLOO_NAME FLOO_IDENTITY_HOOK="$HOOK" "$FLOO" --print-name 2>/dev/null)" = hookname ] && ok "identity hook used" || bad "hook"
[ -n "$(env -u FLOO_NAME -u FLOO_IDENTITY_HOOK "$FLOO" --print-name 2>/dev/null)" ] && ok "falls back to hostname/user" || bad "fallback"
rm -f "$HOOK"; echo "$P passed, $F failed"; [ "$F" -eq 0 ]
