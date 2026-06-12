#!/usr/bin/env bash
set -uo pipefail
OP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/floo-powder"
H=$(mktemp -d); P=0; F=0; ok(){ echo "  PASS $1"; P=$((P+1)); }; bad(){ echo "  FAIL $1"; F=$((F+1)); }
out=$(env HOME="$H" FLOO_HOME="$H/.config/floo" FLOO_INIT_NO_RELAY=1 FLOO_RELAY_PUBLIC_HOST=relay.test.com "$OP" init 2>&1)
[ -f "$H/.config/floo/ca/operator_ca" ] && ok "CA generated" || bad "CA"
[ -f "$H/.config/floo/relay_hostkey" ] && ok "relay host key generated" || bad "hostkey"
grep -q 'curl -fsSL' <<<"$out" && grep -q 'relay.test.com' <<<"$out" && ok "prints client one-liner with the host" || bad "one-liner"
grep -q '"operator_ca"' <<<"$out" && ok "prints importable config blob" || { bad "blob"; echo "$out" | tail -5; }
env HOME="$H" "$OP" --version 2>/dev/null | grep -qE "floo-powder [0-9]+\.[0-9]+" && env HOME="$H" "$OP" --version 2>/dev/null | grep -qi agents-deployed && ok "--version" || bad "--version"

# install-relay --allow-quick marker (static checks — the installer needs root, so we don't run it)
INST="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/relay/install-relay.sh"
grep -q 'allow_quick' "$INST" && ok "install-relay references the allow_quick marker" || bad "no allow_quick handling"
grep -q -- '--allow-quick' "$INST" && ok "install-relay accepts --allow-quick" || bad "no --allow-quick flag"
grep -qE 'rm -f .*allow_quick' "$INST" && ok "uninstall removes the allow_quick marker" || bad "uninstall leaves allow_quick"

rm -rf "$H"; echo "$P passed, $F failed"; [ "$F" -eq 0 ]
