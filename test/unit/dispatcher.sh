#!/usr/bin/env bash
# Unit tests for the relay dispatcher + authkeys helper — no sshd, drives them directly.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROUTE="$REPO/relay/floo-route"; AUTHKEYS="$REPO/relay/floo-authkeys"
P=0; F=0
ok(){ printf '  \e[32mPASS\e[0m %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  \e[31mFAIL\e[0m %s\n' "$1"; F=$((F+1)); }

SOCK="$(mktemp -d /dev/shm/floo-unit.XXXX)"
export FLOO_RELAY_SOCK_DIR="$SOCK"
LISTENER=""
cleanup(){ [ -n "$LISTENER" ] && kill "$LISTENER" 2>/dev/null; rm -rf "$SOCK"; }
trap cleanup EXIT
route(){ SSH_ORIGINAL_COMMAND="$*" SSH_CONNECTION="1.2.3.4 5 6 7" bash "$ROUTE"; }

echo "=== dispatcher (sid-keyed, connect-by-code) ==="
HK="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAtestkeyblob comment@host"
SID="a1b2c3d4e5f60718"
CODE="AB12-CD34"; CH="$(printf '%s' "$CODE" | sha256sum | cut -c1-64)"
WRONG="$(printf '%s' "WRONG-CODE" | sha256sum | cut -c1-64)"
LABEL="testbox"

route register "$SID" "$CH" kelstar "$LABEL" $HK >/dev/null 2>&1 \
  && [ -f "$SOCK/$SID.meta" ] && ok "register writes a meta keyed by sid" || bad "register failed"
grep -q "^label=$LABEL"   "$SOCK/$SID.meta" && ok "meta records the label"      || bad "label not in meta"
grep -q '^loginuser=kelstar' "$SOCK/$SID.meta" && ok "meta records the login user" || bad "loginuser not in meta"

route register 'BADSID'   "$CH" kelstar "$LABEL" $HK >/dev/null 2>&1 && bad "accepted a non-hex sid"   || ok "rejects a bad sid"
route register "$SID" NOTACODE kelstar "$LABEL" $HK >/dev/null 2>&1 && bad "accepted a bad code hash"  || ok "rejects a malformed code hash"
route register "$SID" "$CH" 'root;rm' "$LABEL" $HK   >/dev/null 2>&1 && bad "accepted a bad login user" || ok "rejects an invalid login user"
route register "$SID" "$CH" kelstar 'bad/label' $HK  >/dev/null 2>&1 && bad "accepted a path-y label"   || ok "rejects a bad label"

route resolve "$CH" >/dev/null 2>&1 && bad "resolve returned a session with no live socket" || ok "resolve denies when the socket isn't live"
grep -q 'socket=absent' <<<"$(route meta "$SID" 2>/dev/null)" && ok "meta reports socket=absent when no tunnel is up" || bad "meta should report absent"
route route "$SID" >/dev/null 2>&1 && bad "route with no live socket" || ok "route denies when the socket isn't live"
route meta nosuchsessionid0 >/dev/null 2>&1 && bad "meta on unknown sid succeeded" || ok "meta denies an unknown session"

# a real (live) listener → resolve maps the code to the sid
nc -lkU "$SOCK/$SID.sock" >/dev/null 2>&1 & LISTENER=$!; sleep 0.4
RES="$(route resolve "$CH" 2>/dev/null)"
{ grep -q "^sid=$SID" <<<"$RES" && grep -q 'socket=live' <<<"$RES"; } && ok "resolve maps the code → the live sid" || bad "resolve failed for a live session"
grep -q '^code=' <<<"$RES" && bad "resolve leaks the code hash" || ok "resolve never exposes the code"
grep -q "label=$LABEL" <<<"$RES" && ok "resolve returns the label + hostkey" || bad "resolve missing label"
route resolve "$WRONG" >/dev/null 2>&1 && bad "resolve matched a wrong code" || ok "resolve denies a wrong code"
route list 2>/dev/null | grep -q 'code=' && bad "list leaks the code" || ok "list never exposes the code"
route list 2>/dev/null | grep -q "label=$LABEL" && ok "list shows the label" || bad "list missing label"
kill "$LISTENER" 2>/dev/null; LISTENER=""; rm -f "$SOCK/$SID.sock"

route deregister "$SID" >/dev/null 2>&1
[ -f "$SOCK/$SID.meta" ] && bad "deregister left the meta" || ok "deregister removes socket + meta"
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
