#!/usr/bin/env bash
# Unit tests for --pin pin-bootstrap: `floo --pin RELAY16[:CA16]` verifies the relay's host key
# (RELAY16, as before) and, when the optional CA16 half is given, ALSO verifies the operator CA
# fetched from that relay — otherwise a compromised/malicious relay could hand back its own CA.
# Stubs ssh-keyscan (relay host key) and ssh (the opconfig fetch) — no network involved.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P=0; F=0
ok(){ printf '  \e[32mPASS\e[0m %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  \e[31mFAIL\e[0m %s\n' "$1"; F=$((F+1)); }

STUBDIR="$(mktemp -d)"
KEYDIR="$(mktemp -d)"
trap 'rm -rf "$STUBDIR" "$KEYDIR"' EXIT

# a real relay host key + a real operator CA key (locally generated; nothing goes over a network)
ssh-keygen -t ed25519 -f "$KEYDIR/relay" -N '' -q -C relaykey
ssh-keygen -t ed25519 -f "$KEYDIR/ca"    -N '' -q -C cakey
RELAY_BLOB="$(awk '{print $2}' "$KEYDIR/relay.pub")"
CA_LINE="$(cat "$KEYDIR/ca.pub")"
CA_BLOB="$(awk '{print $2}' "$KEYDIR/ca.pub")"
RELAY_FP="$(printf '%s' "$RELAY_BLOB" | base64 -d | sha256sum | cut -c1-16)"
CA_FP="$(printf '%s' "$CA_BLOB" | base64 -d | sha256sum | cut -c1-16)"
WRONG_FP="0000000000000000"

cat > "$STUBDIR/ssh-keyscan" <<STUB
#!/usr/bin/env bash
echo "relay.test ssh-ed25519 $RELAY_BLOB"
STUB
cat > "$STUBDIR/ssh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = opconfig ] && { echo "$CA_LINE"; exit 0; }; done
exit 0
STUB
chmod +x "$STUBDIR/ssh-keyscan" "$STUBDIR/ssh"
export PATH="$STUBDIR:$PATH"

run_bootstrap() {   # $1 = FLOO_RELAY_PIN value
  ( set -uo pipefail
    FLOO_NO_MAIN=1 source "$REPO/floo" >/dev/null 2>&1
    FLOO_RELAY_HOST=relay.test FLOO_RELAY_PORT=443 FLOO_RELAY_USER=gw FLOO_PUBLIC=0
    FLOO_RELAY_PIN="$1"
    bootstrap_from_relay
    rc=$?
    echo "RC=$rc"
    echo "CA=$FLOO_OPERATOR_CA"
  )
}

echo "=== pin-bootstrap: RELAY16[:CA16] ==="

# mismatched CA half -> refuses, non-zero exit, no CA stored
out="$(run_bootstrap "$RELAY_FP:$WRONG_FP" 2>&1)"
grep -q '^RC=0$' <<<"$out" && bad "mismatched CA pin: exited 0" || ok "mismatched CA pin: exits non-zero"
grep -qE '^CA=.+' <<<"$out" && bad "mismatched CA pin: a CA line was stored" || ok "mismatched CA pin: no CA stored"
grep -qi 'does not match your pin\|does NOT match your pin' <<<"$out" && ok "mismatched CA pin: names the mismatch" || bad "mismatched CA pin: no explanatory message"

# matching CA half -> accepted, CA stored
out="$(run_bootstrap "$RELAY_FP:$CA_FP" 2>&1)"
grep -q '^RC=0$' <<<"$out" && ok "matching CA pin: exits 0" || bad "matching CA pin: rc != 0 ($out)"
grep -qF "CA=$CA_LINE" <<<"$out" && ok "matching CA pin: fetched CA is stored" || bad "matching CA pin: CA not stored ($out)"

# no CA half at all -> accepted (unchanged behavior), with a warning line present
out="$(run_bootstrap "$RELAY_FP" 2>&1)"
grep -q '^RC=0$' <<<"$out" && ok "no CA pin: exits 0 (back-compat)" || bad "no CA pin: rc != 0 ($out)"
grep -qF "CA=$CA_LINE" <<<"$out" && ok "no CA pin: fetched CA is still stored" || bad "no CA pin: CA not stored"
grep -qi 'trust' <<<"$out" && ok "no CA pin: warns that the relay's operator is trusted for the CA" || bad "no CA pin: no trust warning printed"

# mismatched RELAY half (no CA half) still refuses exactly as before
out="$(run_bootstrap "$WRONG_FP" 2>&1)"
grep -q '^RC=0$' <<<"$out" && bad "mismatched relay pin: exited 0" || ok "mismatched relay pin: still exits non-zero"

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
