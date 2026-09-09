#!/usr/bin/env bash
# Unit tests for the smaller item-6 hardening fixes:
#  - relay/install-relay.sh: FLOO_RELAY_PORT must be an integer 1-65535 before it's templated
#    into sshd_config / the fail2ban jail.
#  - floo --emit-hook: the nonce argument must match ^[A-Za-z0-9_-]{1,64}$ before it's embedded
#    into the generated shell-hook script.
#  - floo's HMAC of the pairing code no longer passes it as a plain -hmac argv value to openssl.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLOO="$REPO/floo"
INSTALLER="$REPO/relay/install-relay.sh"
P=0; F=0
ok(){ printf '  \e[32mPASS\e[0m %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  \e[31mFAIL\e[0m %s\n' "$1"; F=$((F+1)); }

echo "=== install-relay.sh: FLOO_RELAY_PORT must be a 1-65535 integer ==="
for bad_port in '443;rm -rf /' '99999' '0' '-1' 'abc' '22 --uninstall'; do
  out="$(FLOO_RELAY_PORT="$bad_port" bash "$INSTALLER" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && grep -qi 'bad FLOO_RELAY_PORT' <<<"$out" \
    && ok "rejects FLOO_RELAY_PORT='$bad_port'" \
    || bad "accepted (or wrong error for) FLOO_RELAY_PORT='$bad_port': rc=$rc out=$out"
done
# a valid port still passes the port check itself (it then fails on the real root check, not the port)
out="$(FLOO_RELAY_PORT=2222 bash "$INSTALLER" 2>&1)"; rc=$?
grep -qi 'bad FLOO_RELAY_PORT' <<<"$out" && bad "valid port 2222 was rejected: $out" || ok "valid port 2222 passes the port check"
grep -qi 'run as root' <<<"$out" && ok "valid port then hits the (expected) root check, not the port check" || bad "unexpected failure for a valid port: $out"

echo "=== floo --emit-hook: nonce is validated ==="
for bad_nonce in "a'b" 'a"b' 'a;b' 'a b' "$(printf 'a\nb')" "$(printf 'a%.0s' $(seq 1 65))"; do
  out="$("$FLOO" --emit-hook bash "$bad_nonce" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && grep -qi 'bad nonce' <<<"$out" \
    && ok "rejects a bad nonce" \
    || bad "accepted (or wrong error for) a bad nonce '$bad_nonce': rc=$rc out=$out"
done
out="$("$FLOO" --emit-hook bash 'deadbeef0123' 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q '1337;floo;deadbeef0123;' <<<"$out" && ok "accepts a clean nonce and embeds it" || bad "clean nonce failed: rc=$rc"
out="$("$FLOO" --emit-hook bash '' 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "an empty nonce (internal default) is still accepted" || bad "empty nonce rejected: rc=$rc out=$out"

echo "=== floo: pairing-code HMAC no longer passed as a plain openssl argv value ==="
grep -qE -- '-hmac[[:space:]]+"\$\(norm "\$PAIRCODE"\)"' "$FLOO" \
  && bad "still passes the pairing code via a plain -hmac argv value" \
  || ok "no more plain -hmac argv value for the pairing code"
grep -q 'macopt "hexkey:' "$FLOO" && ok "HMAC key is passed via -macopt hexkey:" || bad "no -macopt hexkey: usage found"
# functional: hmac_code(key, stdin-message) matches the old openssl -hmac construction. Sourcing
# floo overwrites this script's own ok()/bad() (floo defines its own), so do it in a subshell and
# only bring the digest back out.
got="$(FLOO_NO_MAIN=1 source "$FLOO" >/dev/null 2>&1; printf 'somemessage' | hmac_code 'AB12-CD34')"
want="$(printf 'somemessage' | openssl dgst -sha256 -hmac 'AB12-CD34' | awk '{print $NF}')"
[ "$got" = "$want" ] && ok "hmac_code() produces the same digest as a plain HMAC" || bad "hmac_code() mismatch: got=$got want=$want"

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
