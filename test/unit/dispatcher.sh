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

echo "=== quick mode (bindop/getop, allow-quick gate, caps) ==="
QSID="b1c2d3e4f5061728"
QCODE="ABCD-EF01-2345-6"; QCH="$(printf '%s' "$QCODE" | sha256sum | cut -c1-64)"
OPKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAopkeyblob op-test"
AUTH="$(printf '%s' "$OPKEY" | openssl dgst -sha256 -hmac "$QCODE" | awk '{print $NF}')"
ALLOWQ="$(mktemp)"   # presence = quick enabled
qroute(){ SSH_ORIGINAL_COMMAND="$*" SSH_CONNECTION="1.2.3.4 5 6 7" FLOO_ALLOW_QUICK_FILE="$ALLOWQ" bash "$ROUTE"; }

# register is REFUSED for quick=1 when the allow-quick marker is absent (no socket yet — the real client
# registers BEFORE its tunnel creates the socket, so register must run with no live socket).
SSH_ORIGINAL_COMMAND="register $QSID $QCH kelstar qbox quick=1 $OPKEY" SSH_CONNECTION="1.2.3.4 5 6 7" \
  FLOO_ALLOW_QUICK_FILE=/nonexistent bash "$ROUTE" >/dev/null 2>&1 \
  && bad "quick register accepted with allow-quick OFF" || ok "quick register refused when allow-quick is off"

# with the marker present, quick register succeeds and records quick=1
qroute register "$QSID" "$QCH" kelstar qbox quick=1 $OPKEY >/dev/null 2>&1 \
  && grep -q '^quick=1' "$SOCK/$QSID.meta" && ok "quick register writes quick=1 meta" || bad "quick register failed"

# NOW bring the session's socket live (mirrors the client's reverse tunnel), so bindop's liveness check passes
QL=""; nc -lkU "$SOCK/$QSID.sock" >/dev/null 2>&1 & QL=$!; sleep 0.4

# bindop appends a bind; getop returns it
qroute bindop "$QSID" "$AUTH" $OPKEY >/dev/null 2>&1 && ok "bindop accepted a well-formed bind" || bad "bindop rejected a valid bind"
grep -q "$AUTH" <<<"$(qroute getop "$QSID" 2>/dev/null)" && ok "getop returns the stored bind" || bad "getop did not return the bind"

# store-all: a second (griefer, junk-auth) bind is also stored, and getop returns BOTH
GARBAGE="$(printf '%064d' 0 | tr 0 d)"   # 64 hex chars, wrong auth
qroute bindop "$QSID" "$GARBAGE" "ssh-ed25519 AAAAgrieferblob grief" >/dev/null 2>&1
[ "$(qroute getop "$QSID" 2>/dev/null | wc -l)" -ge 2 ] && ok "store-all keeps multiple binds (client filters)" || bad "second bind not stored"

# bindop is refused for a non-quick session (the CA session registered earlier has no quick=1)
qroute bindop "$SID" "$AUTH" $OPKEY >/dev/null 2>&1 && bad "bindop accepted on a non-quick session" || ok "bindop refuses a non-quick session"
# bindop validates the auth hex
qroute bindop "$QSID" NOTHEX $OPKEY >/dev/null 2>&1 && bad "bindop accepted a non-hex auth" || ok "bindop rejects a malformed auth"
# getop on a session with no binds denies
qroute getop "$SID" >/dev/null 2>&1 && bad "getop returned binds for a session with none" || ok "getop denies when nothing is bound"
# bindop refused when allow-quick is OFF even for a quick session
SSH_ORIGINAL_COMMAND="bindop $QSID $AUTH $OPKEY" SSH_CONNECTION="1.2.3.4 5 6 7" \
  FLOO_ALLOW_QUICK_FILE=/nonexistent bash "$ROUTE" >/dev/null 2>&1 \
  && bad "bindop accepted with allow-quick OFF" || ok "bindop refused when allow-quick is off"

# CAP — max-concurrent: with QSID already live and FLOO_QUICK_MAX=1, a 2nd quick register is refused
QSID2="c1c2c3c4c5c6c7c8"; QCH2="$(printf '%s' "OTHER-CODE" | sha256sum | cut -c1-64)"
SSH_ORIGINAL_COMMAND="register $QSID2 $QCH2 kelstar qbox2 quick=1 $OPKEY" SSH_CONNECTION="1.2.3.4 5 6 7" \
  FLOO_ALLOW_QUICK_FILE="$ALLOWQ" FLOO_QUICK_MAX=1 bash "$ROUTE" >/dev/null 2>&1 \
  && bad "max-concurrent cap not enforced" || ok "max-concurrent quick cap refuses a 2nd live session"

# CAP — TTL: a quick meta with an ancient registered_epoch is pruned on the next scan (no socket needed)
TSID="d1d2d3d4d5d6d7d8"
{ echo "sid=$TSID"; echo "code=$QCH2"; echo "loginuser=kelstar"; echo "label=tbox"; echo "quick=1"
  echo "registered=old"; echo "registered_epoch=1"; echo "peer=1.2.3.4"; echo "hostkey=$HK"; } > "$SOCK/$TSID.meta"
qroute list >/dev/null 2>&1
[ -f "$SOCK/$TSID.meta" ] && bad "expired quick session not pruned (TTL)" || ok "expired quick session pruned on scan (TTL)"
# a CA session (no quick=1) with an old epoch is NOT pruned by the quick-TTL path
CSID="e1e2e3e4e5e6e7e8"
{ echo "sid=$CSID"; echo "code=$QCH2"; echo "loginuser=kelstar"; echo "label=cbox"
  echo "registered=old"; echo "peer=1.2.3.4"; echo "hostkey=$HK"; } > "$SOCK/$CSID.meta"
qroute list >/dev/null 2>&1
[ -f "$SOCK/$CSID.meta" ] && ok "CA sessions are not touched by the quick-TTL prune" || bad "quick TTL wrongly pruned a CA session"
rm -f "$SOCK/$CSID.meta"

kill "$QL" 2>/dev/null; rm -f "$SOCK/$QSID.sock" "$SOCK/$QSID.binds" "$SOCK/$QSID.meta" "$ALLOWQ"

echo "=== authkeys ==="
o="$(bash "$AUTHKEYS" ssh-ed25519 AAAAKEYBLOB)"
[ "$o" = "ssh-ed25519 AAAAKEYBLOB" ] && ok "authkeys echoes a valid key (accept-any)" || bad "authkeys output wrong: '$o'"
o="$(bash "$AUTHKEYS" not-a-keytype AAAAKEYBLOB)"
[ -z "$o" ] && ok "authkeys emits nothing for an unknown key type (auth fails)" || bad "authkeys accepted a bad type"

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
