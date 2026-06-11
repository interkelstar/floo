#!/usr/bin/env bash
set -uo pipefail
OP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/floo-powder"
H=$(mktemp -d); P=0; F=0; ok(){ echo "  PASS $1"; P=$((P+1)); }; bad(){ echo "  FAIL $1"; F=$((F+1)); }
out=$(env HOME="$H" FLOO_HOME="$H/.config/floo" FLOO_INIT_NO_RELAY=1 FLOO_RELAY_PUBLIC_HOST=relay.test.com "$OP" init 2>&1)
[ -f "$H/.config/floo/ca/operator_ca" ] && ok "CA generated" || bad "CA"
[ -f "$H/.config/floo/relay_hostkey" ] && ok "relay host key generated" || bad "hostkey"
grep -q 'curl -fsSL' <<<"$out" && grep -q 'relay.test.com' <<<"$out" && ok "prints client one-liner with the host" || bad "one-liner"
grep -q '"operator_ca"' <<<"$out" && ok "prints importable config blob" || { bad "blob"; echo "$out" | tail -5; }
env HOME="$H" "$OP" --version 2>/dev/null | grep -q "floo-powder 0.1.0" && env HOME="$H" "$OP" --version 2>/dev/null | grep -qi agents-deployed && ok "--version" || bad "--version"
rm -rf "$H"; echo "$P passed, $F failed"; [ "$F" -eq 0 ]
