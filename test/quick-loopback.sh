#!/usr/bin/env bash
# quick-loopback.sh — end-to-end proof of NO-CERT (quick) mode on one host, no root-CA needed.
# Stands up the relay with --allow-quick (marker), runs the real client with --public, and the real
# operator connect (auto-detected quick path). Asserts: the operator reaches the box with ONLY the
# code (ephemeral key bound by HMAC), a WRONG code never authorizes, and Ctrl-C still revokes.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \e[32mPASS\e[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \e[31mFAIL\e[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
note(){ printf '\e[2m  · %s\e[0m\n' "$1"; }

OPHOME="$HOME"
WORK="$(mktemp -d /dev/shm/floo-qlb.XXXX)"
THOME="$WORK/home"; SOCK="$WORK/sock"; RELAY="$WORK/relay"
RUN="/run/user/$(id -u)/floo-qlb-$$"
ALLOWQ="$WORK/allow_quick"; : > "$ALLOWQ"     # the --allow-quick marker, handed to the dispatcher via SetEnv
mkdir -p "$THOME/.ssh" "$RUN" "$SOCK" "$RELAY"; chmod 700 "$THOME/.ssh" "$RUN"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
ME="$(id -un)"
CLIENT_PID=""; RELAY_PID=""; PTYRUN_PID=""
HELPBIN="/usr/local/lib/floo-qlb-$$"

cleanup() {
  [ -n "$PTYRUN_PID" ] && kill -TERM "$PTYRUN_PID" 2>/dev/null
  [ -n "$CLIENT_PID" ] && { kill -INT "$CLIENT_PID" 2>/dev/null; kill -TERM "$CLIENT_PID" 2>/dev/null; }
  sleep 0.5
  [ -n "$RELAY_PID" ] && kill -TERM "-$RELAY_PID" 2>/dev/null
  pkill -f "$WORK" 2>/dev/null
  sudo rm -rf "$HELPBIN" 2>/dev/null
  rm -rf "$WORK" "$RUN" 2>/dev/null
  for f in "$HOME"/.ssh/floo.d/qbox.conf "$HOME"/.config/floo/sessions/qbox; do rm -rf "$f" 2>/dev/null; done
  sed -i '/127.0.0.1/d' "$HOME/.config/floo/relay_known_hosts" 2>/dev/null || true
}
trap cleanup EXIT
sudo install -d -m755 -o root -g root "$HELPBIN"
sudo install -m755 -o root -g root "$REPO/relay/floo-route" "$REPO/relay/floo-authkeys" "$HELPBIN/"

echo "=== floo QUICK (no-cert) loopback (port $PORT, user $ME) ==="

# ── relay with allow-quick wired in via SetEnv (the dispatcher reads FLOO_ALLOW_QUICK_FILE) ──
ssh-keygen -t ed25519 -f "$RELAY/hostkey" -N '' -q
cat > "$RELAY/sshd_config" <<CFG
Port $PORT
ListenAddress 127.0.0.1
HostKey $RELAY/hostkey
PidFile $RELAY/pid
LogLevel VERBOSE
UsePAM no
PasswordAuthentication no
AuthorizedKeysFile none
AuthorizedKeysCommand $HELPBIN/floo-authkeys %t %k
AuthorizedKeysCommandUser $ME
AllowUsers $ME
SetEnv FLOO_RELAY_SOCK_DIR=$SOCK FLOO_ALLOW_QUICK_FILE=$ALLOWQ
Match User $ME
    AllowTcpForwarding remote
    PermitListen none
    AllowStreamLocalForwarding remote
    StreamLocalBindUnlink yes
    PermitTTY no
    ForceCommand FLOO_RELAY_SOCK_DIR=$SOCK FLOO_ALLOW_QUICK_FILE=$ALLOWQ $HELPBIN/floo-route
CFG
/usr/sbin/sshd -t -f "$RELAY/sshd_config" || { echo "relay config invalid"; exit 1; }
setsid /usr/sbin/sshd -D -e -f "$RELAY/sshd_config" >"$RELAY/log" 2>&1 &
RELAY_PID=$!
sleep 0.6
kill -0 "$RELAY_PID" 2>/dev/null && ok "relay (allow-quick) is up on :$PORT" || { bad "relay did not start"; cat "$RELAY/log"; exit 1; }

# ── client in --public mode ──
PTYRUN_LOG="$WORK/client.log" PTYRUN_PIDFILE="$WORK/client.pid" \
  python3 "$REPO/test/ptyrun.py" \
    env -i HOME="$THOME" PATH="$PATH" XDG_RUNTIME_DIR="$RUN" TERM=xterm \
    FLOO_NAME=qbox FLOO_RELAY_HOST=127.0.0.1 FLOO_RELAY_PORT="$PORT" \
    FLOO_RELAY_USER="$ME" FLOO_RELAY_SOCK_DIR="$SOCK" \
    FLOO_RELAY_HOSTKEY="$(cat "$RELAY/hostkey.pub")" \
    bash "$REPO/floo" --public &
PTYRUN_PID=$!
for i in $(seq 1 30); do [ -s "$WORK/client.pid" ] && break; sleep 0.1; done
CLIENT_PID="$(cat "$WORK/client.pid" 2>/dev/null)"

for i in $(seq 1 50); do ls "$SOCK"/*.sock >/dev/null 2>&1 && ls "$SOCK"/*.meta >/dev/null 2>&1 && break; sleep 0.2; done
SID="$(sed -n 's/^sid=//p' "$SOCK"/*.meta 2>/dev/null | head -1)"
{ [ -n "$SID" ] && grep -q '^quick=1' "$SOCK/$SID.meta"; } && ok "client registered a quick session (sid ${SID:0:8}…)" || { bad "no quick registration"; cat "$WORK/client.log"; }

# the displayed code (base32, grouped) — long, uppercase, with dashes
CODE=""; for i in $(seq 1 50); do CODE="$(grep -oE '[A-Z2-7]{4}(-[A-Z2-7]{1,4})+' "$WORK/client.log" | head -1)"; [ -n "$CODE" ] && break; sleep 0.2; done
[ -n "$CODE" ] && [ "${#CODE}" -ge 14 ] && ok "client showed a high-entropy code ($CODE)" || bad "no/short public code shown"

# ── a WRONG code must NOT authorize (operator binds garbage; client never writes it) ──
if env -i HOME="$OPHOME" PATH="$PATH" FLOO_HOME="$OPHOME/.config/floo" \
    FLOO_RELAY_HOST=127.0.0.1 FLOO_RELAY_PORT="$PORT" FLOO_RELAY_USER="$ME" \
    "$REPO/bin/floo-powder" connect --confirm WRON-GCOD-EXXX-X --no-shell >"$WORK/wrong.log" 2>&1; then
  bad "operator connect with a WRONG code reported success"
else
  ok "operator connect with a wrong code fails to authorize"
fi

# ── ADVERSARIAL: a griefer who knows the SID (via 'list') binds a junk auth FIRST. The store-all design
#    means the client must SKIP it (HMAC fails) and never authorize it — so the legit operator still gets in. ──
JUNK_AUTH="$(printf '%064d' 0 | tr 0 a)"   # 64 hex, will never equal HMAC(realcode, junkkey)
ssh -p "$PORT" -i "$OPHOME/.config/floo/relay_id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ME@127.0.0.1" \
    bindop "$SID" "$JUNK_AUTH" "ssh-ed25519 AAAAgrieferpubkeyblob grief" >/dev/null 2>&1 \
  && note "injected a junk griefer bind for $SID" || note "griefer bind call returned nonzero (still stored if quick on)"
sleep 3   # give the client's bind_watcher (2s poll) a cycle to see + reject the junk bind
if [ -s "$RUN/floo/qbox/authorized_keys" ]; then
  bad "client authorized a junk griefer bind (store-all skip broken — DoS/again open)"
else
  ok "client refused the junk griefer bind (authorized_keys still empty — HMAC skip works)"
fi

# ── the CORRECT code: operator auto-detects quick, binds an ephemeral key, gets in (past the griefer) ──
env -i HOME="$OPHOME" PATH="$PATH" FLOO_HOME="$OPHOME/.config/floo" \
    FLOO_RELAY_HOST=127.0.0.1 FLOO_RELAY_PORT="$PORT" FLOO_RELAY_USER="$ME" \
    "$REPO/bin/floo-powder" connect --confirm "$CODE" --no-shell >"$WORK/connect.log" 2>&1 \
  && ok "operator connect (quick, code-bound ephemeral key) succeeded" \
  || { bad "operator quick connect failed"; cat "$WORK/connect.log"; }

OUT="$(env -i HOME="$OPHOME" PATH="$PATH" FLOO_HOME="$OPHOME/.config/floo" \
    FLOO_RELAY_HOST=127.0.0.1 FLOO_RELAY_PORT="$PORT" FLOO_RELAY_USER="$ME" \
    "$REPO/bin/floo-powder" exec qbox 2>"$WORK/exec.err" <<<'echo QMARK_$((6*7))' )"
grep -q 'QMARK_42' <<<"$OUT" && ok "BOT-operator (exec) ran a command over the no-cert pivot (HMAC-bound key)" \
  || { bad "exec over the quick pivot failed"; echo "$OUT"; cat "$WORK/exec.err"; tail -15 "$RUN"/floo/qbox/sshd.log 2>/dev/null; }

# ── the BOT session must be RECORDED to the client's disk (logging, no-cert mode) ──
sleep 0.3
{ ls "$RUN"/floo/qbox/recording/*.raw >/dev/null 2>&1 && grep -aq 'QMARK_42' "$RUN"/floo/qbox/recording/session.raw 2>/dev/null; } \
  && ok "BOT-operator session recorded on the client (cmd + output logged)" \
  || { bad "BOT-operator session NOT recorded"; ls -la "$RUN"/floo/qbox/recording/ 2>/dev/null; }

# ── MANUAL-operator mode: a real INTERACTIVE shell over a pty must work AND be recorded ──
# (the exec path above is non-interactive; this drives an actual login shell via ssh -tt — the
#  record-session wrapper's interactive branch, distinct from the command branch.)
{ sleep 2.5; printf 'echo IMARK_$((6*7))\n'; sleep 1.5; printf 'exit\n'; sleep 0.5; } \
  | timeout 25 env HOME="$OPHOME" PATH="$PATH" ssh -tt -o BatchMode=yes qbox >"$WORK/interactive.log" 2>&1 || true
sleep 0.3
grep -q 'IMARK_42' "$WORK/interactive.log" && ok "MANUAL-operator interactive shell ran (live output seen)" \
  || { bad "interactive shell produced no output"; cat "$WORK/interactive.log"; }
grep -rq 'IMARK_42' "$RUN"/floo/qbox/recording/ 2>/dev/null && ok "MANUAL-operator interactive session recorded on the client" \
  || { bad "interactive session NOT recorded"; }

# ── Ctrl-C still revokes ──
note "delivering Ctrl-C to the public client…"
kill -TERM "$PTYRUN_PID" 2>/dev/null
for i in $(seq 1 50); do kill -0 "$CLIENT_PID" 2>/dev/null || break; sleep 0.2; done
kill -0 "$CLIENT_PID" 2>/dev/null && { bad "public client did not exit on Ctrl-C"; kill -KILL "$CLIENT_PID" 2>/dev/null; } || ok "public client exited on Ctrl-C (revoke ran)"
CLIENT_PID=""
for i in $(seq 1 15); do [ -S "$SOCK/$SID.sock" ] || break; sleep 0.2; done
[ -S "$SOCK/$SID.sock" ] && bad "relay socket still present after revoke" || ok "relay socket released (close = revoke)"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
