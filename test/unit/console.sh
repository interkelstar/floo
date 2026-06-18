#!/usr/bin/env bash
# Tests the client's live-status core: the shared `_session_active` connect/idle detector, and the
# no-python3 `monitor()` fallback (the path with ZERO coverage before — exactly the silent-regression
# risk that has bitten this project). Sources floo with FLOO_NO_MAIN=1 to drive the functions directly.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FLOO_NO_MAIN=1 source "$REPO/floo"   # source FIRST, then define the harness (floo defines its own ok())
P=0; F=0
ok(){ echo "  PASS $1"; P=$((P+1)); }; bad(){ echo "  FAIL $1"; F=$((F+1)); }

echo "=== _session_active: shared connect/idle detector (used by the python console AND monitor) ==="
d="$(mktemp -d)"; mkdir -p "$d/active"
_session_active "$d" 0 >/dev/null; [ "$?" = 1 ] && ok "empty session dir -> inactive" || bad "empty dir read active"
: > "$d/active/$$"                                   # a live (this-shell) PID marker
_session_active "$d" 0 >/dev/null; [ "$?" = 0 ] && ok "a live PID marker -> active" || bad "live marker read inactive"
rm -f "$d/active/$$"; printf '2026 cmd\n' > "$d/sessions.log"
n="$(_session_active "$d" 0)"; rc=$?
{ [ "$rc" = 0 ] && [ "$n" = 1 ]; } && ok "a new sessions.log line -> active (count surfaced on stdout)" || bad "sessions.log line not detected: rc=$rc n=$n"
_session_active "$d" 1 >/dev/null; [ "$?" = 1 ] && ok "no new line since 'seen' + no live marker -> inactive" || bad "false-active with no change"
echo 2147480000 > "$d/active/2147480000"            # an almost-certainly-dead pid marker
_session_active "$d" 1 >/dev/null
[ -e "$d/active/2147480000" ] && bad "dead active-marker not reaped" || ok "dead active-marker is reaped"
rm -rf "$d"

echo "=== monitor(): no-python fallback announces a connected helper for a live session ==="
out="$(
  W="$(mktemp -d)"; mkdir -p "$W/active"
  WORKDIR="$W" G="" X="" D=""
  sleep 30 & SSHD_PID=$!; sleep 30 & TUNNEL_PID=$!   # keep monitor's while-loop alive
  : > "$W/active/$$"                                 # an active (this-shell) session marker
  monitor > "$W/mon.out" 2>&1 &
  MPID=$!; sleep 2.5
  kill "$SSHD_PID" "$TUNNEL_PID" 2>/dev/null; wait "$MPID" 2>/dev/null
  cat "$W/mon.out"; rm -rf "$W"
)"
grep -q 'your helper is connected' <<<"$out" && ok "monitor announces a connected helper" || bad "monitor silent: [$out]"

echo "=== render_console falls through to monitor() when python3 is ABSENT (minimal/container boxes) ==="
out="$(
  W="$(mktemp -d)"; mkdir -p "$W/active" "$W/recording"
  WORKDIR="$W" G="" X="" D=""
  command() { if [ "${1:-}" = -v ] && [ "${2:-}" = python3 ]; then return 1; fi; builtin command "$@"; }
  sleep 30 & SSHD_PID=$!; sleep 30 & TUNNEL_PID=$!
  : > "$W/active/$$"
  render_console > "$W/rc.out" 2>&1 &
  RPID=$!; sleep 2.5
  kill "$SSHD_PID" "$TUNNEL_PID" 2>/dev/null; wait "$RPID" 2>/dev/null
  cat "$W/rc.out"; rm -rf "$W"
)"
grep -q 'your helper is connected' <<<"$out" && ok "render_console uses monitor (plain lines, no pinned frame) without python3" || bad "no-python render_console produced no status: [$out]"

echo "=== floo --stop closes a session from ANOTHER terminal (lost-window recovery) ==="
# no session open → says so, exits 0 (nothing to close)
env -u XDG_RUNTIME_DIR HOME="$(mktemp -d)" FLOO_NAME=nope-$$ bash "$REPO/floo" --stop 2>&1 \
  | grep -q 'no support session' && ok "floo --stop with no open session reports it (no-op)" || bad "stop without a session misbehaved"
# ORPHANED session: the owning floo is gone but its sshd+tunnel linger. --stop must reap both + wipe the dir.
res="$(
  TH="$(mktemp -d)"
  D="$TH/.local/state/floo/stopbox"; mkdir -p "$D/recording"
  : > "$D/before.txt"; echo deadbeefdeadbeef > "$D/principals"      # principals = the sid (no clientkey → no relay call)
  setsid sleep 120 & echo $! > "$D/sshd.pid"; SP=$!                 # stand in for the orphaned sshd (pid==pgid)
  setsid sleep 120 & echo $! > "$D/tunnel.pid"; TP=$!               # stand in for the orphaned tunnel
  env -u XDG_RUNTIME_DIR HOME="$TH" FLOO_NAME=stopbox bash "$REPO/floo" --stop >/dev/null 2>&1
  kill -0 "$SP" 2>/dev/null && echo SSHD_ALIVE
  kill -0 "$TP" 2>/dev/null && echo TUNNEL_ALIVE
  [ -d "$D" ] && echo DIR_PRESENT
  kill "$SP" "$TP" 2>/dev/null; rm -rf "$TH"
)"
{ ! grep -q ALIVE <<<"$res" && ! grep -q DIR_PRESENT <<<"$res"; } \
  && ok "floo --stop reaps an orphaned session's endpoint + tunnel and wipes the dir" || bad "stop left something behind: [$res]"

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
