#!/usr/bin/env bash
# Unit tests for the built-in public relay defaults (0.8.0): `floo --public` and
# `floo-powder connect CODE` with no relay given (flags, env or saved config) use
# FLOO_PUBLIC_RELAY_{HOST,PORT,PIN}; explicit --relay/--pin or a saved relay always win;
# CA mode and other floo-powder subcommands never pick the default.
# Stubs ssh-keyscan (relay host key) and ssh (relay calls) — no network involved.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OP="$REPO/bin/floo-powder"
P=0; F=0
ok(){ printf '  \e[32mPASS\e[0m %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  \e[31mFAIL\e[0m %s\n' "$1"; F=$((F+1)); }

STUBDIR="$(mktemp -d)"
KEYDIR="$(mktemp -d)"
H="$(mktemp -d)"
trap 'rm -rf "$STUBDIR" "$KEYDIR" "$H"' EXIT

ssh-keygen -t ed25519 -f "$KEYDIR/relay" -N '' -q -C relaykey
RELAY_BLOB="$(awk '{print $2}' "$KEYDIR/relay.pub")"
RELAY_FP="$(printf '%s' "$RELAY_BLOB" | base64 -d | sha256sum | cut -c1-16)"
export KEYSCAN_LOG="$STUBDIR/keyscan.log" SSH_LOG="$STUBDIR/ssh.log"

cat > "$STUBDIR/ssh-keyscan" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "\$KEYSCAN_LOG"
echo "relay.test ssh-ed25519 $RELAY_BLOB"
STUB
cat > "$STUBDIR/ssh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$SSH_LOG"
for a in "$@"; do [ "$a" = resolve ] && exit 1; done
exit 0
STUB
chmod +x "$STUBDIR/ssh-keyscan" "$STUBDIR/ssh"
export PATH="$STUBDIR:$PATH"

# every FLOO_* setting that could leak in from the caller's environment
CLEAN=(env -u FLOO_RELAY_HOST -u FLOO_RELAY_PORT -u FLOO_RELAY_PIN -u FLOO_RELAY_HOSTKEY
       -u FLOO_OPERATOR_CA -u FLOO_PUBLIC -u FLOO_PUBLIC_RELAY_HOST -u FLOO_PUBLIC_RELAY_PORT
       -u FLOO_PUBLIC_RELAY_PIN -u FLOO_HOME -u FLOO_CONFIG_DIR)
reset_logs(){ rm -f "$KEYSCAN_LOG" "$SSH_LOG"; }

# ── floo (sourced): resolve host/port/pin ────────────────────────────────────────────────
# $1 = FLOO_PUBLIC, $2 = host from --relay, $3 = port, $4 = pin from --pin
resolve_floo() {
  "${CLEAN[@]}" HOME="$H" FLOO_CONFIG_DIR="$H/cfg" bash -c '
    FLOO_NO_MAIN=1 source "$0" >/dev/null 2>&1
    FLOO_PUBLIC="$1"; FLOO_RELAY_HOST="$2"; FLOO_RELAY_PORT="$3"; FLOO_RELAY_PIN="$4"
    apply_public_defaults
    echo "HOST=$FLOO_RELAY_HOST PORT=$FLOO_RELAY_PORT PIN=$FLOO_RELAY_PIN"
  ' "$REPO/floo" "$@" 2>&1
}

echo "=== public defaults: floo ==="
out="$("${CLEAN[@]}" bash -c 'FLOO_NO_MAIN=1 source "$0" >/dev/null 2>&1; echo "$FLOO_PUBLIC_RELAY_HOST $FLOO_PUBLIC_RELAY_PORT $FLOO_PUBLIC_RELAY_PIN"' "$REPO/floo")"
[ "$out" = "relay.floo.run 443 df2b83ff925f89bd" ] && ok "floo: constants are relay.floo.run / 443 / df2b83ff925f89bd" || bad "floo: constants wrong ($out)"

out="$(resolve_floo 1 "" 443 "")"
grep -q 'HOST=relay.floo.run PORT=443 PIN=df2b83ff925f89bd' <<<"$out" && ok "floo --public alone: host/port/pin = the constants" || bad "floo --public alone: not resolved to the constants ($out)"
grep -q 'public relay relay.floo.run:443' <<<"$out" && grep -q 'built in' <<<"$out" && ok "floo --public alone: prints the one-line notice" || bad "floo --public alone: no notice ($out)"

out="$(resolve_floo 1 my.relay 2222 "")"
grep -q 'HOST=my.relay PORT=2222 PIN=$' <<<"$out" && ok "floo --public --relay (no --pin): explicit relay wins, no pin invented" || bad "floo --public --relay: default leaked in ($out)"
grep -q 'public relay' <<<"$out" && bad "floo --public --relay: printed the public-relay notice" || ok "floo --public --relay: no notice"

out="$(resolve_floo 1 "" 443 abcdefabcdefabcd)"
grep -q 'HOST= PORT=443 PIN=abcdefabcdefabcd' <<<"$out" && ok "floo --public --pin X (no --relay): nothing filled in, behaves as before" || bad "floo --public --pin X: default relay leaked in next to a foreign pin ($out)"

out="$(resolve_floo 0 "" 443 "")"
grep -q 'HOST= PORT=443 PIN=$' <<<"$out" && ok "floo (CA mode): no default relay picked" || bad "floo (CA mode): default relay leaked in ($out)"

# end to end through main(): --public --show-operator verifies the (overridden) default pin
reset_logs
out="$("${CLEAN[@]}" HOME="$H" FLOO_CONFIG_DIR="$H/cfg" FLOO_NAME=t FLOO_PUBLIC_RELAY_HOST=relay.test \
       FLOO_PUBLIC_RELAY_PIN="$RELAY_FP" bash "$REPO/floo" --public --show-operator 2>&1)"
grep -q '^relay=relay.test:443$' <<<"$out" && grep -q 'pin matches' <<<"$out" && ok "floo --public (main): dials the default relay and verifies its pin" || bad "floo --public (main): ($out)"
grep -q 'relay.test' "$KEYSCAN_LOG" 2>/dev/null && ok "floo --public (main): keyscan went to the default host" || bad "floo --public (main): keyscan not called on the default host"

reset_logs
out="$("${CLEAN[@]}" HOME="$H" FLOO_CONFIG_DIR="$H/cfg" FLOO_NAME=t bash "$REPO/floo" --public --show-operator 2>&1)"
grep -q 'df2b83ff925f89bd' <<<"$out" && grep -q 'relay.floo.run' "$KEYSCAN_LOG" 2>/dev/null && ok "floo --public (main, no overrides): uses relay.floo.run + the built-in pin" || bad "floo --public (main, no overrides): ($out)"

reset_logs
out="$("${CLEAN[@]}" HOME="$H" FLOO_CONFIG_DIR="$H/cfg" FLOO_NAME=t bash "$REPO/floo" --show-operator 2>&1)"
grep -q '^relay=:443$' <<<"$out" && [ ! -e "$KEYSCAN_LOG" ] && ok "floo (main, CA mode): no default relay, nothing dialled" || bad "floo (main, CA mode): ($out)"

# ── floo-powder connect ──────────────────────────────────────────────────────────────────
echo "=== public defaults: floo-powder ==="
run_op() { "${CLEAN[@]}" HOME="$H" FLOO_HOME="$H/fh" "$@"; }

rm -rf "$H/fh"; reset_logs
out="$(run_op FLOO_PUBLIC_RELAY_HOST=relay.test FLOO_PUBLIC_RELAY_PIN="$RELAY_FP" "$OP" connect --confirm CODE1 --no-shell 2>&1)"
grep -q 'public relay relay.test:443' <<<"$out" && grep -q 'built in' <<<"$out" && ok "powder connect (no relay): prints the one-line notice" || bad "powder connect (no relay): no notice ($out)"
grep -q 'relay.test' "$KEYSCAN_LOG" 2>/dev/null && grep -q 'pinned (not saved)' <<<"$out" && ok "powder connect (no relay): verifies the default pin" || bad "powder connect (no relay): pin not verified ($out)"
[ ! -e "$H/fh/relay.env" ] || ! grep -q 'RELAY_HOST=' "$H/fh/relay.env" \
  && ok "powder connect (no relay): the public relay is NOT written to relay.env" || bad "powder connect (no relay): relay.env now holds the public relay (list/exec would inherit it)"
grep -q 'gw@relay.test resolve' "$SSH_LOG" 2>/dev/null && ok "powder connect (no relay): resolves the code at the default relay" || bad "powder connect (no relay): did not resolve at the default relay"

rm -rf "$H/fh"; reset_logs
out="$(run_op "$OP" connect --confirm CODE1 --no-shell 2>&1)"
grep -q 'df2b83ff925f89bd' <<<"$out" && grep -q -- '-p 443 relay.floo.run' "$KEYSCAN_LOG" 2>/dev/null && ok "powder connect (no overrides): uses relay.floo.run:443 + the built-in pin" || bad "powder connect (no overrides): ($out)"

rm -rf "$H/fh"; reset_logs
out="$(run_op "$OP" --relay other.test connect --confirm CODE1 --no-shell 2>&1)"
grep -q 'public relay' <<<"$out" && bad "powder --relay (no --pin): printed the notice" || ok "powder --relay (no --pin): no notice"
[ ! -e "$KEYSCAN_LOG" ] && grep -q 'gw@other.test resolve' "$SSH_LOG" 2>/dev/null && ok "powder --relay (no --pin): explicit relay used, no pin invented" || bad "powder --relay (no --pin): default leaked in"

rm -rf "$H/fh"; mkdir -p "$H/fh"; echo "RELAY_HOST=saved.test" > "$H/fh/relay.env"; reset_logs
out="$(run_op "$OP" connect --confirm CODE1 --no-shell 2>&1)"
! grep -q 'public relay' <<<"$out" && grep -q 'gw@saved.test resolve' "$SSH_LOG" 2>/dev/null && ok "powder connect (saved relay.env): saved relay wins" || bad "powder connect (saved relay.env): ($out)"

rm -rf "$H/fh"; reset_logs
out="$(run_op "$OP" list 2>&1)"
! grep -q 'public relay' <<<"$out" && [ ! -e "$KEYSCAN_LOG" ] && ok "powder list (no relay): other subcommands do not pick the default" || bad "powder list: default leaked in ($out)"

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
