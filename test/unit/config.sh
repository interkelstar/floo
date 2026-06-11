#!/usr/bin/env bash
set -uo pipefail
FLOO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/floo"
H=$(mktemp -d); export HOME="$H"; P=0; F=0
ok(){ echo "  PASS $1"; P=$((P+1)); }; bad(){ echo "  FAIL $1"; F=$((F+1)); }
"$FLOO" config add acme --relay relay.acme.com:8443 --operator-ca 'ssh-ed25519 AAAACA acme' --relay-hostkey 'ssh-ed25519 AAAAHK acme' >/dev/null 2>&1
[ -f "$H/.config/floo/operators/acme.json" ] && ok "config add writes a file" || bad "add"
"$FLOO" config list 2>/dev/null | grep -qx acme && ok "config list shows it" || bad "list"
[ "$("$FLOO" --show-operator 2>/dev/null)" = "relay=relay.acme.com:8443" ] && ok "single saved operator auto-loaded (host+port)" || bad "auto-load got: $("$FLOO" --show-operator 2>/dev/null)"
echo '{"name":"beta","relay_host":"relay.beta.com","relay_port":"443","operator_ca":"ssh-ed25519 AAAACB beta","relay_hostkey":""}' | "$FLOO" config import - >/dev/null 2>&1
[ -f "$H/.config/floo/operators/beta.json" ] && ok "config import saves by name" || bad "import"
[ "$("$FLOO" --operator beta --show-operator 2>/dev/null)" = "relay=relay.beta.com:443" ] && ok "--operator selects among several" || bad "--operator got: $("$FLOO" --operator beta --show-operator 2>/dev/null)"
"$FLOO" config remove acme >/dev/null 2>&1; [ -f "$H/.config/floo/operators/acme.json" ] && bad "remove" || ok "config remove deletes"
rm -rf "$H"; echo "$P passed, $F failed"; [ "$F" -eq 0 ]
