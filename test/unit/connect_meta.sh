#!/usr/bin/env bash
# Unit tests for floo-powder cmd_connect's handling of the relay `resolve` reply.
# The reply is untrusted (a relay we may not own, possibly compromised) — every field must be
# validated before it lands in an ssh_config drop-in, a filesystem path, or an ssh argv, even
# though the relay is supposed to have validated at registration time (relay/floo-route).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OP="$REPO/bin/floo-powder"
P=0; F=0
ok(){ printf '  PASS %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  FAIL %s\n' "$1"; F=$((F+1)); }

H="$(mktemp -d)"
FH="$H/.config/floo"
STUBDIR="$(mktemp -d)"
META="$STUBDIR/meta_reply"
trap 'rm -rf "$H" "$STUBDIR"' EXIT

# a stub `ssh` ahead of the real one on PATH: relay_ssh's `resolve`/`bindop` calls, and the
# post-bind `floo-probe` liveness poll, are all just `ssh ... <args...>` — inspect argv for the
# subcommand keyword and respond accordingly, no network involved.
cat > "$STUBDIR/ssh" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    resolve) cat "$META_REPLY_FILE"; exit 0 ;;
    bindop) echo "bound"; exit 0 ;;
    floo-probe) exit 0 ;;
  esac
done
exit 0
STUB
chmod +x "$STUBDIR/ssh"
export META_REPLY_FILE="$META"
export PATH="$STUBDIR:$PATH"

run_connect() {
  env HOME="$H" FLOO_HOME="$FH" FLOO_RELAY_HOST=relay.test FLOO_RELAY_PORT=443 \
    "$OP" connect --confirm TESTCODE --no-shell
}

drop_in_count() { find "$H/.ssh/floo.d" -name '*.conf' 2>/dev/null | wc -l; }

echo "=== connect: relay resolve reply is validated before any drop-in is written ==="

# (a) a multi-line loginuser (relay/attacker smuggled an extra "key=value" line in)
cat > "$META" <<'M'
socket=live
sid=a1b2c3d4e5f60718
loginuser=alice
loginuser=evil
label=goodlabel
quick=0
registered=2026-01-01T00:00:00Z
peer=1.2.3.4
hostkey=ssh-ed25519 AAAAB3NzaC1lZDI1NTE5AAAA
M
out="$(run_connect 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qi 'loginuser' <<<"$out" && ok "multi-line loginuser: dies naming the field" || bad "multi-line loginuser: rc=$rc out=$out"
[ "$(drop_in_count)" -eq 0 ] && ok "multi-line loginuser: no drop-in written" || bad "multi-line loginuser: a drop-in was written"

# (b) a path-traversal label
cat > "$META" <<'M'
socket=live
sid=a1b2c3d4e5f60718
loginuser=alice
label=../x
quick=0
registered=2026-01-01T00:00:00Z
peer=1.2.3.4
hostkey=ssh-ed25519 AAAAB3NzaC1lZDI1NTE5AAAA
M
out="$(run_connect 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qi 'label' <<<"$out" && ok "path-y label (../x): dies naming the field" || bad "path-y label: rc=$rc out=$out"
[ "$(drop_in_count)" -eq 0 ] && ok "path-y label: no drop-in written" || bad "path-y label: a drop-in was written"

# (c) a label beginning with '-' (would be parsed as an ssh/file-command flag)
cat > "$META" <<'M'
socket=live
sid=a1b2c3d4e5f60718
loginuser=alice
label=-x
quick=0
registered=2026-01-01T00:00:00Z
peer=1.2.3.4
hostkey=ssh-ed25519 AAAAB3NzaC1lZDI1NTE5AAAA
M
out="$(run_connect 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qi 'label' <<<"$out" && ok "dash-leading label: dies naming the field" || bad "dash-leading label: rc=$rc out=$out"
[ "$(drop_in_count)" -eq 0 ] && ok "dash-leading label: no drop-in written" || bad "dash-leading label: a drop-in was written"

# (d) a sid containing a double quote
cat > "$META" <<'M'
socket=live
sid=ab"cd0123456789
loginuser=alice
label=goodlabel
quick=0
registered=2026-01-01T00:00:00Z
peer=1.2.3.4
hostkey=ssh-ed25519 AAAAB3NzaC1lZDI1NTE5AAAA
M
out="$(run_connect 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qi 'sid' <<<"$out" && ok "quoted sid: dies naming the field" || bad "quoted sid: rc=$rc out=$out"
[ "$(drop_in_count)" -eq 0 ] && ok "quoted sid: no drop-in written" || bad "quoted sid: a drop-in was written"

# (e) a clean reply still produces the drop-in (quick=1 path, no CA needed)
cat > "$META" <<'M'
socket=live
sid=a1b2c3d4e5f60718
loginuser=alice
label=goodlabel
quick=1
registered=2026-01-01T00:00:00Z
peer=1.2.3.4
hostkey=ssh-ed25519 AAAAB3NzaC1lZDI1NTE5AAAA
M
out="$(run_connect 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "clean reply: connect succeeds" || bad "clean reply: rc=$rc out=$out"
[ -f "$H/.ssh/floo.d/goodlabel.conf" ] && ok "clean reply: drop-in written under the label" || bad "clean reply: no drop-in"
grep -q '^Host goodlabel$' "$H/.ssh/floo.d/goodlabel.conf" 2>/dev/null && ok "clean reply: drop-in has the expected Host line" || bad "clean reply: drop-in missing Host line"

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
