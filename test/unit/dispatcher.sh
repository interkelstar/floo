#!/usr/bin/env bash
# Unit tests for the relay dispatcher + authkeys helper — no sshd, drives them directly.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROUTE="$REPO/relay/floo-route"; AUTHKEYS="$REPO/relay/floo-authkeys"
P=0; F=0
ok(){ printf '  \e[32mPASS\e[0m %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  \e[31mFAIL\e[0m %s\n' "$1"; F=$((F+1)); }

SOCK="$(mktemp -d /dev/shm/asx-unit.XXXX)"
export FLOO_RELAY_SOCK_DIR="$SOCK"
LISTENER=""
cleanup(){ [ -n "$LISTENER" ] && kill "$LISTENER" 2>/dev/null; rm -rf "$SOCK"; }
trap cleanup EXIT
route(){ SSH_ORIGINAL_COMMAND="$*" SSH_CONNECTION="1.2.3.4 5 6 7" bash "$ROUTE"; }

echo "=== dispatcher ==="
HK="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAtestkeyblob comment@host"
CODE="AB12-CD34"; CH="$(printf '%s' "$CODE" | sha256sum | cut -c1-64)"

route register testbot "$CH" kelstar $HK >/dev/null 2>&1 \
  && [ -f "$SOCK/testbot.meta" ] && ok "register writes a meta file" || bad "register failed"
[ "$(route verify testbot "$CH" 2>/dev/null)" = "match=yes" ] && ok "verify accepts the correct code hash" || bad "verify rejected the right hash"
[ "$(route verify testbot "$(printf '%s' WRONG | sha256sum | cut -c1-64)" 2>/dev/null)" = "match=no" ] && ok "verify rejects a wrong code hash" || bad "verify accepted a wrong hash"
route meta testbot 2>/dev/null | grep -q '^code=' && bad "meta leaks the code hash" || ok "meta never exposes the code"
route list 2>/dev/null | grep -q 'code=' && bad "list leaks the code" || ok "list never exposes the code"
grep -q '^loginuser=kelstar' "$SOCK/testbot.meta" && ok "meta records the login user" || bad "loginuser not in meta"

route register 'bad/name' "$CH" kelstar $HK >/dev/null 2>&1 && bad "accepted path-traversal botname" || ok "rejects an invalid botname"
route register testbot NOTACODE kelstar $HK >/dev/null 2>&1 && bad "accepted a malformed code" || ok "rejects a malformed code hash"
route register testbot "$CH" 'root;rm' $HK >/dev/null 2>&1 && bad "accepted a bad login user" || ok "rejects an invalid login user"

out="$(route meta testbot 2>/dev/null)"
grep -q 'socket=absent' <<<"$out" && ok "meta reports socket=absent when no tunnel is up" || bad "meta should report absent"
route meta nosuch >/dev/null 2>&1 && bad "meta on unknown session succeeded" || ok "meta denies an unknown session"
route route testbot >/dev/null 2>&1 && bad "route succeeded with no live socket" || ok "route denies when the socket isn't live"

# a real (live) listener → socket_live must report it as live
nc -lkU "$SOCK/testbot.sock" >/dev/null 2>&1 & LISTENER=$!; sleep 0.4
out="$(route meta testbot 2>/dev/null)"
grep -q 'socket=live' <<<"$out" && ok "meta reports socket=live against a real listener" || bad "meta missed a live socket"
kill "$LISTENER" 2>/dev/null; LISTENER=""; rm -f "$SOCK/testbot.sock"

route deregister testbot >/dev/null 2>&1
[ -f "$SOCK/testbot.meta" ] && bad "deregister left the meta" || ok "deregister removes socket + meta"

route somethingelse >/dev/null 2>&1 && bad "unknown command succeeded" || ok "rejects an unknown command"


# opconfig serves the operator PUBLIC CA (pin-bootstrap)
CAF=$(mktemp); echo "ssh-ed25519 AAAATESTCA opca" > "$CAF"
[ "$(FLOO_OPERATOR_CA_FILE="$CAF" route opconfig 2>/dev/null)" = "ssh-ed25519 AAAATESTCA opca" ] && ok "opconfig serves the operator CA" || bad "opconfig did not serve the CA"
FLOO_OPERATOR_CA_FILE=/nonexistent route opconfig >/dev/null 2>&1 && bad "opconfig served with no CA published" || ok "opconfig denies when no CA is published"
rm -f "$CAF"

echo "=== authkeys ==="
o="$(bash "$AUTHKEYS" ssh-ed25519 AAAAKEYBLOB)"
[ "$o" = "ssh-ed25519 AAAAKEYBLOB" ] && ok "authkeys echoes a valid key (accept-any)" || bad "authkeys output wrong: '$o'"
o="$(bash "$AUTHKEYS" not-a-keytype AAAAKEYBLOB)"
[ -z "$o" ] && ok "authkeys emits nothing for an unknown key type (auth fails)" || bad "authkeys accepted a bad type"

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
