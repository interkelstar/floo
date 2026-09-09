#!/usr/bin/env bash
# Unit test for floo-route's `route` gate on quick sessions: only the caller who actually
# authenticated with a key bindop recorded for this sid (i.e. someone who proved knowledge of
# the pairing code) may splice into it — an authenticated gw-account holder who merely learns a
# live sid must NOT be able to ride it. Drives floo-route directly (no real sshd); the connecting
# key is supplied the way sshd's `ExposeAuthInfo yes` would (a file named by $SSH_USER_AUTH).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROUTE="$REPO/relay/floo-route"
P=0; F=0
ok(){ printf '  \e[32mPASS\e[0m %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  \e[31mFAIL\e[0m %s\n' "$1"; F=$((F+1)); }

SOCK="$(mktemp -d /dev/shm/floo-routegate.XXXX)"
STUBDIR="$(mktemp -d)"
NC_LOG="$STUBDIR/nc.log"; : > "$NC_LOG"
LISTENER=""
cleanup(){ [ -n "$LISTENER" ] && kill "$LISTENER" 2>/dev/null; rm -rf "$SOCK" "$STUBDIR"; }
trap cleanup EXIT

SID="a1b2c3d4e5f60718"
CSID="c1c2c3c4c5c6c7c8"   # a cert (non-quick) session, for the unchanged-behavior check
BOUND_B64="AAAAC3NzaC1lZDI1NTE5AAAAboundkeyblob"
OTHER_B64="AAAAC3NzaC1lZDI1NTE5AAAAotherkeyblob"

{ echo "sid=$SID"; echo "code=deadbeef"; echo "loginuser=kelstar"; echo "label=qbox"; echo "quick=1"
  echo "registered=now"; echo "peer=1.2.3.4"; echo "hostkey=ssh-ed25519 AAAAtest"; } > "$SOCK/$SID.meta"
{ echo "sid=$CSID"; echo "code=deadbeef2"; echo "loginuser=kelstar"; echo "label=cbox"
  echo "registered=now"; echo "peer=1.2.3.4"; echo "hostkey=ssh-ed25519 AAAAtest"; } > "$SOCK/$CSID.meta"
printf '%s ssh-ed25519 %s op-comment\n' "$(printf '%064d' 0 | tr 0 a)" "$BOUND_B64" > "$SOCK/$SID.binds"

# real live sockets (created with the REAL nc, before PATH is overridden below)
nc -lkU "$SOCK/$SID.sock"  >/dev/null 2>&1 & LISTENER=$!
nc -lkU "$SOCK/$CSID.sock" >/dev/null 2>&1 &
LISTENER2=$!
sleep 0.4

# a stub `nc` (PATH-shadowed only for the floo-route invocation below) that just logs it ran,
# standing in for BOTH socket_live's liveness probe (any exit 0/124 reads as "live") and the
# final `exec nc -U ...` splice — so "reached the exec line" is simply "a 2nd log line appeared".
cat > "$STUBDIR/nc" <<STUB
#!/usr/bin/env bash
echo "called \$*" >> "$NC_LOG"
exit 0
STUB
chmod +x "$STUBDIR/nc"

# SSH_USER_AUTH's actual OpenSSH format is "publickey <algo> <base64>" (the algo prefix IS
# present — not a bare authorized_keys-style base64).
AUTH_MATCH="$(mktemp)";    printf 'publickey ssh-ed25519 %s\n' "$BOUND_B64" > "$AUTH_MATCH"
AUTH_MISMATCH="$(mktemp)"; printf 'publickey ssh-ed25519 %s\n' "$OTHER_B64" > "$AUTH_MISMATCH"

run_route() {   # $1=SSH_USER_AUTH file (or "") ; rest = SSH_ORIGINAL_COMMAND words
  local authfile="$1"; shift
  : > "$NC_LOG"
  FLOO_RELAY_SOCK_DIR="$SOCK" SSH_ORIGINAL_COMMAND="$*" SSH_CONNECTION="1.2.3.4 5 6 7" \
    SSH_USER_AUTH="$authfile" PATH="$STUBDIR:$PATH" bash "$ROUTE"
}

echo "=== route: quick sessions require the caller's key to be bound (bindop) ==="

run_route "$AUTH_MISMATCH" route "$SID" >/dev/null 2>&1; rc=$?
n="$(wc -l < "$NC_LOG")"
[ "$rc" -ne 0 ] && ok "unbound key: route denies" || bad "unbound key: route succeeded (rc=$rc)"
[ "$n" -eq 1 ] && ok "unbound key: never reached the exec nc line (only the liveness probe ran)" || bad "unbound key: nc log had $n lines"

run_route "" route "$SID" >/dev/null 2>&1; rc=$?
n="$(wc -l < "$NC_LOG")"
[ "$rc" -ne 0 ] && ok "no SSH_USER_AUTH at all: route denies (fail-closed)" || bad "no SSH_USER_AUTH: route succeeded"
[ "$n" -eq 1 ] && ok "no SSH_USER_AUTH: never reached the exec nc line" || bad "no SSH_USER_AUTH: nc log had $n lines"

run_route "$AUTH_MATCH" route "$SID" >/dev/null 2>&1; rc=$?
n="$(wc -l < "$NC_LOG")"
[ "$rc" -eq 0 ] && ok "bound key: route succeeds" || bad "bound key: route denied (rc=$rc)"
[ "$n" -eq 2 ] && ok "bound key: reached the exec nc line" || bad "bound key: nc log had $n lines"

# cert (non-quick) sessions: unaffected by this gate — proceeds even with no matching bind at all
run_route "$AUTH_MISMATCH" route "$CSID" >/dev/null 2>&1; rc=$?
n="$(wc -l < "$NC_LOG")"
[ "$rc" -eq 0 ] && ok "cert session: route unaffected by the bind gate" || bad "cert session: route denied (rc=$rc)"
[ "$n" -eq 2 ] && ok "cert session: reached the exec nc line" || bad "cert session: nc log had $n lines"

kill "$LISTENER" "$LISTENER2" 2>/dev/null
rm -f "$AUTH_MATCH" "$AUTH_MISMATCH"

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
