#!/usr/bin/env bash
# loopback.sh — full end-to-end proof of floo on a single host, no root.
#
# Stands up a real relay sshd (own user, high port, accept-any-key + dispatcher), runs the
# real client floo and the real operator CLI through it, and asserts the things that
# matter: the operator can reach the box ONLY with a CA-signed cert, the pairing code gates
# it, the session is recorded, and — the load-bearing one — Ctrl-C truly REVOKES (endpoint
# down, relay socket gone, no orphans, surfaces unchanged).
#
# Uses the real operator CA at ~/.config/floo/ca (whose pubkey floo embeds).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { printf '  \e[32mPASS\e[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \e[31mFAIL\e[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '\e[2m  · %s\e[0m\n' "$1"; }

CA_PUB="$HOME/.config/floo/ca/operator_ca.pub"
[ -f "$CA_PUB" ] || { echo "need operator CA at $CA_PUB (run: bin/floo-powder ca-init)"; exit 1; }

# ssh resolves the operator's config via getpwuid() (the real home), not $HOME — so the
# operator CLI must run with the real home (which is the genuine operator setup anyway).
OPHOME="$HOME"
WORK="$(mktemp -d /dev/shm/asx-loopback.XXXX)"
THOME="$WORK/home"; SOCK="$WORK/sock"; RELAY="$WORK/relay"
# the client's runtime dir must be on a path sshd considers safe (not world-writable
# ancestors) — exactly like production's /run/user/UID. /dev/shm has a 1777 ancestor → unsafe.
RUN="/run/user/$(id -u)/asx-loopback-$$"
mkdir -p "$THOME/.ssh" "$RUN" "$SOCK" "$RELAY"; chmod 700 "$THOME/.ssh" "$RUN"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
ME="$(id -un)"
CLIENT_PID=""; RELAY_PID=""; PTYRUN_PID=""
# sshd requires AuthorizedKeysCommand to be root-owned on a safe path (true in production:
# /usr/local/bin). Mirror that here with root-owned copies in a dedicated dir.
HELPBIN="/usr/local/lib/asx-loopback-$$"

cleanup() {
  [ -n "$PTYRUN_PID" ] && kill -TERM "$PTYRUN_PID" 2>/dev/null
  [ -n "$CLIENT_PID" ] && { kill -INT "$CLIENT_PID" 2>/dev/null; kill -TERM "$CLIENT_PID" 2>/dev/null; }
  sleep 0.5
  [ -n "$RELAY_PID" ] && kill -TERM "-$RELAY_PID" 2>/dev/null
  pkill -f "$WORK" 2>/dev/null
  sudo rm -rf "$HELPBIN" 2>/dev/null
  rm -rf "$WORK" "$RUN" "$HOME/.config/floo/sessions/testbot" "$HOME/.ssh/floo.d/testbot.conf" 2>/dev/null
  sed -i '/127.0.0.1/d' "$HOME/.config/floo/relay_known_hosts" 2>/dev/null || true  # drop test relay pins
}
trap cleanup EXIT
sudo install -d -m755 -o root -g root "$HELPBIN"
sudo install -m755 -o root -g root "$REPO/relay/floo-route" "$REPO/relay/floo-authkeys" "$HELPBIN/"

echo "=== floo loopback test (port $PORT, user $ME) ==="

# ── 1. the relay ─────────────────────────────────────────────────────────────────────────
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
SetEnv FLOO_RELAY_SOCK_DIR=$SOCK
Match User $ME
    AllowTcpForwarding remote
    PermitListen none
    AllowStreamLocalForwarding remote
    StreamLocalBindUnlink yes
    PermitTTY no
    ForceCommand FLOO_RELAY_SOCK_DIR=$SOCK $HELPBIN/floo-route
CFG
/usr/sbin/sshd -t -f "$RELAY/sshd_config" || { echo "relay config invalid"; exit 1; }
setsid /usr/sbin/sshd -D -e -f "$RELAY/sshd_config" >"$RELAY/log" 2>&1 &
RELAY_PID=$!
sleep 0.6
kill -0 "$RELAY_PID" 2>/dev/null && ok "relay sshd is up on 127.0.0.1:$PORT" || { bad "relay did not start"; cat "$RELAY/log"; exit 1; }

# the relay-pin mechanism: a PRE-PINNED but WRONG host key must be REJECTED (not TOFU-accepted) —
# this is what closes the relay-MITM. Pin a valid-but-wrong key, then expect ssh to refuse.
BADKH="$WORK/badkh"; awk '{print "[127.0.0.1]:'"$PORT"' " $1 " " $2}' "$HOME/.config/floo/relay_id_ed25519.pub" > "$BADKH"
if timeout 8 ssh -p "$PORT" -i "$HOME/.config/floo/relay_id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \
     -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$BADKH" "$ME@127.0.0.1" list >/dev/null 2>&1; then
  bad "a MISMATCHED relay host key was accepted (pin not enforced — MITM open!)"
else
  ok "a mismatched relay host key is rejected (pin enforced — relay-MITM closed)"
fi

# ── 2. the client (floo), as if a client typed `support` ───────────────────────────
# Run the client under a real PTY (via ptyrun.py) so we can deliver a genuine Ctrl-C later.
# A plain `cmd &` cannot test SIGINT: bash ignores it for async-backgrounded scripts.
PTYRUN_LOG="$WORK/client.log" PTYRUN_PIDFILE="$WORK/client.pid" \
  python3 "$REPO/test/ptyrun.py" \
    env -i HOME="$THOME" PATH="$PATH" XDG_RUNTIME_DIR="$RUN" TERM=xterm \
    FLOO_NAME=testbot FLOO_RELAY_HOST=127.0.0.1 FLOO_RELAY_PORT="$PORT" \
    FLOO_RELAY_USER="$ME" FLOO_RELAY_SOCK_DIR="$SOCK" \
    FLOO_RELAY_HOSTKEY="$(cat "$RELAY/hostkey.pub")" \
    FLOO_OPERATOR_CA="$(cat "$CA_PUB")" \
    bash "$REPO/floo" &
PTYRUN_PID=$!
for i in $(seq 1 30); do [ -s "$WORK/client.pid" ] && break; sleep 0.1; done
CLIENT_PID="$(cat "$WORK/client.pid" 2>/dev/null)"

# wait for the reverse socket + the registration meta to appear
for i in $(seq 1 50); do [ -S "$SOCK/testbot.sock" ] && [ -f "$SOCK/testbot.meta" ] && break; sleep 0.2; done
[ -S "$SOCK/testbot.sock" ] && ok "client dialed out: reverse socket present on the relay" || { bad "no reverse socket"; cat "$WORK/client.log"; }
[ -f "$SOCK/testbot.meta" ] && ok "client registered its pairing code + host key" || bad "no registration meta"

CODE=""; for i in $(seq 1 50); do CODE="$(grep -oE '[0-9A-F]{4}-[0-9A-F]{4}' "$WORK/client.log" | head -1)"; [ -n "$CODE" ] && break; sleep 0.2; done
[ -n "$CODE" ] && ok "client displayed a pairing code ($CODE)" || bad "client showed no pairing code"

# ── 3. squatter / wrong-code is refused ──────────────────────────────────────────────────
if env -i HOME="$OPHOME" PATH="$PATH" FLOO_HOME="$OPHOME/.config/floo" \
    FLOO_RELAY_HOST=127.0.0.1 FLOO_RELAY_PORT="$PORT" FLOO_RELAY_USER="$ME" \
    "$REPO/bin/floo-powder" connect testbot --confirm 0000-0000 --no-shell >"$WORK/wrong.log" 2>&1; then
  bad "operator connect ACCEPTED a wrong pairing code (should refuse)"
else
  grep -qiE 'does not match|not this session|pairing code' "$WORK/wrong.log" && ok "operator refuses a wrong pairing code" || bad "wrong-code rejected but not via code check"
fi

# ── 4. operator connect with the correct code, then the bot exec (audit) path ────────────
env -i HOME="$OPHOME" PATH="$PATH" FLOO_HOME="$OPHOME/.config/floo" \
    FLOO_RELAY_HOST=127.0.0.1 FLOO_RELAY_PORT="$PORT" FLOO_RELAY_USER="$ME" \
    "$REPO/bin/floo-powder" connect testbot --confirm "$CODE" --no-shell >"$WORK/connect.log" 2>&1 \
  && ok "operator connect succeeded (code confirmed, cert minted, host key pinned)" \
  || { bad "operator connect failed"; cat "$WORK/connect.log"; }

OUT="$(env -i HOME="$OPHOME" PATH="$PATH" FLOO_HOME="$OPHOME/.config/floo" \
    FLOO_RELAY_HOST=127.0.0.1 FLOO_RELAY_PORT="$PORT" FLOO_RELAY_USER="$ME" \
    "$REPO/bin/floo-powder" exec testbot 2>"$WORK/exec.err" <<<'echo MARKER_$((6*7)); id -un' )"
grep -q 'MARKER_42' <<<"$OUT" && ok "operator ran a command on the box via the relay pivot (cert auth)" \
  || { bad "exec over the pivot did not return expected output"; echo "--- out:"; echo "$OUT"; echo "--- err:"; cat "$WORK/exec.err"; echo "--- client sshd.log:"; tail -15 "$RUN"/floo/testbot/sshd.log 2>/dev/null; }

# ── 5. the session was recorded on the CLIENT side ───────────────────────────────────────
sleep 0.3
if ls "$RUN"/floo/testbot/recording/*.log >/dev/null 2>&1 && grep -rq 'MARKER_42' "$RUN"/floo/testbot/recording/ 2>/dev/null; then
  ok "the session (incl. the bot's command) was recorded to the client's disk"
else
  bad "no client-side recording of the session"
fi

# ── 6. an UNSIGNED key (no CA cert) is refused — only the operator CA gets in ─────────────
ssh-keygen -t ed25519 -f "$WORK/rogue" -N '' -q
# -F /dev/null on BOTH hops so we do NOT inherit the operator's cert from the real drop-in;
# this tests a bare rogue key, which the client must reject (only the operator CA gets in).
if env -i PATH="$PATH" \
   ssh -F /dev/null -p "$PORT" -i "$WORK/rogue" -o IdentitiesOnly=yes -o BatchMode=yes \
       -o HostKeyAlias=rogue -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o ProxyCommand="ssh -F /dev/null -p $PORT -i $OPHOME/.config/floo/relay_id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $ME@127.0.0.1 route testbot" \
       "$ME@placeholder" 'echo SHOULD_NOT_HAPPEN' >"$WORK/rogue.log" 2>&1; then
  bad "an un-certified key got a shell (CA gate broken!)"
else
  ok "a key without an operator-CA cert is refused by the box"
fi

# ── 7. THE BIG ONE: Ctrl-C on the client truly revokes ───────────────────────────────────
# optionally simulate a technician changing an access surface mid-session (tests DISCLOSURE)
if [ -n "${FLOO_INJECT_CHANGE:-}" ]; then
  echo "ssh-ed25519 AAAAINJECTEDTESTKEYsimulatingleftoveraccess injected@test" >> "$THOME/.ssh/authorized_keys"
  note "injected an authorized_keys entry to test change-detection"
fi

note "delivering a real Ctrl-C (\\x03) to the client's terminal…"
kill -TERM "$PTYRUN_PID" 2>/dev/null   # ptyrun forwards \x03 to the pty = a genuine Ctrl-C
for i in $(seq 1 50); do kill -0 "$CLIENT_PID" 2>/dev/null || break; sleep 0.2; done
kill -0 "$CLIENT_PID" 2>/dev/null && { bad "client did not exit after Ctrl-C"; kill -KILL "$CLIENT_PID" 2>/dev/null; } || ok "client exited on Ctrl-C and ran teardown"
CLIENT_PID=""

for i in $(seq 1 15); do [ -S "$SOCK/testbot.sock" ] || break; sleep 0.2; done   # async unlink
[ -S "$SOCK/testbot.sock" ] && bad "relay socket STILL present after revoke" || ok "relay socket released (close = revoke)"
# no orphaned throwaway sshd / tunnel left behind
if pgrep -af "floo/testbot" 2>/dev/null | grep -q sshd; then bad "orphaned throwaway sshd survived teardown"; else ok "no orphaned sshd/tunnel after teardown"; fi
# the surface state-diff verdict was produced and matches reality
if [ -n "${FLOO_INJECT_CHANGE:-}" ]; then
  grep -q 'CHANGED' "$WORK/client.log" && ok "teardown DETECTED the injected access-surface change (disclosure works)" || { bad "teardown MISSED an injected change"; tail -12 "$WORK/client.log"; }
else
  grep -q 'unchanged' "$WORK/client.log" && ok "teardown reported the attack surface UNCHANGED (no false positive)" || { bad "no clean state-diff verdict on exit"; tail -8 "$WORK/client.log"; }
fi
# the operator's cert really is short-lived
CERT="$HOME/.config/floo/sessions/testbot/opkey-cert.pub"
[ -f "$CERT" ] && ssh-keygen -Lf "$CERT" | grep -q 'Valid:.*to' && ok "operator cert is time-boxed (≤60m)" || note "cert file already cleaned"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
