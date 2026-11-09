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
    list) [ -n "${LIST_FAIL:-}" ] && exit 255; cat "$LIST_REPLY_FILE"; exit 0 ;;
  esac
done
exit 0
STUB
chmod +x "$STUBDIR/ssh"
export META_REPLY_FILE="$META"
export LIST_REPLY_FILE="$STUBDIR/list_reply"
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
[ -f "$H/.ssh/floo.d/goodlabel-a1b2.conf" ] && ok "clean reply: drop-in written under <label>-<sid4>" || bad "clean reply: no drop-in"
grep -q '^Host goodlabel-a1b2$' "$H/.ssh/floo.d/goodlabel-a1b2.conf" 2>/dev/null && ok "clean reply: drop-in has the expected Host line" || bad "clean reply: drop-in missing Host line"
# the bare label must never become a Host alias: it would shadow the operator's own `Host <label>`
# in ~/.ssh/config (our Include is prepended; first match wins) and keep shadowing it after the session
[ ! -e "$H/.ssh/floo.d/goodlabel.conf" ] && ! grep -rqx 'Host goodlabel' "$H/.ssh/floo.d" 2>/dev/null \
  && ok "clean reply: no bare-label Host alias (cannot shadow the operator's own host)" || bad "clean reply: a bare-label Host alias was written"
grep -q 'goodlabel-a1b2' <<<"$out" && ok "clean reply: the banner names the suffixed handle" || bad "clean reply: banner does not show goodlabel-a1b2: $out"

# (f) a second connect to the SAME session finds its handle taken → falls back to the sid (no overwrite)
out="$(run_connect 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$H/.ssh/floo.d/a1b2c3d4e5f60718.conf" ]; } && ok "handle taken: falls back to the sid" || bad "handle taken: rc=$rc out=$out"
[ -f "$H/.ssh/floo.d/goodlabel-a1b2.conf" ] && ok "handle taken: the first drop-in is kept" || bad "handle taken: the first drop-in was removed"

echo "=== gc: keeps live sessions whatever their handle, fails closed ==="
run_gc() { env HOME="$H" FLOO_HOME="$FH" FLOO_RELAY_HOST=relay.test FLOO_RELAY_PORT=443 "$OP" gc; }
printf 'a1b2c3d4e5f60718\tsocket=live\tlabel=goodlabel\tregistered=x\n' > "$LIST_REPLY_FILE"
out="$(run_gc 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$H/.ssh/floo.d/goodlabel-a1b2.conf" ] && [ -f "$H/.ssh/floo.d/a1b2c3d4e5f60718.conf" ]; } \
  && ok "gc: a live session's <label>-<sid4> and sid drop-ins are kept" || bad "gc dropped a live session: rc=$rc out=$out"
out="$(LIST_FAIL=1 run_gc 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && [ -f "$H/.ssh/floo.d/goodlabel-a1b2.conf" ]; } && ok "gc: relay unreachable → nothing removed, non-zero exit" || bad "gc with failed list: rc=$rc out=$out"
: > "$LIST_REPLY_FILE"
out="$(run_gc 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(drop_in_count)" -eq 0 ] && [ ! -e "$FH/sessions/goodlabel-a1b2" ]; } \
  && ok "gc: an ended session's drop-ins and session dir are removed" || bad "gc kept a dead session: rc=$rc out=$out"

# (g) a max-length label (40, validate_meta's cap) still yields a handle exec/close accept
long="$(printf 'L%.0s' $(seq 1 40))"
sed -i "s/^label=.*/label=$long/" "$META"
out="$(run_connect 2>&1)"; rc=$?
h="$long-a1b2"
{ [ "$rc" -eq 0 ] && [ -f "$H/.ssh/floo.d/$h.conf" ]; } && ok "40-char label: handle written (${#h} chars)" || bad "40-char label: rc=$rc out=$out"
env HOME="$H" FLOO_HOME="$FH" "$OP" close "$h" >/dev/null 2>&1 && [ ! -e "$H/.ssh/floo.d/$h.conf" ] \
  && ok "40-char label: close accepts the handle" || bad "40-char label: close rejected the handle"

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
