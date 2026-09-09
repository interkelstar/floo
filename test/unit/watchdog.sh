#!/usr/bin/env bash
# Unit test for the sshd watchdog: the throwaway endpoint must not outlive the controller (the
# floo process). Drives start_sshd_watchdog directly (sourced with FLOO_NO_MAIN=1) against a fake
# controller pid and a fake "sshd" process group, with no real sshd/relay involved.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLOO_NO_MAIN=1 source "$REPO/floo"   # source FIRST, then define the harness (floo defines its own ok())
P=0; F=0
ok(){ printf '  \e[32mPASS\e[0m %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  \e[31mFAIL\e[0m %s\n' "$1"; F=$((F+1)); }

group_alive() { kill -0 "-$1" 2>/dev/null; }

echo "=== sshd watchdog: endpoint dies when the controller does ==="

# fake "controller" — just a sleeping process whose pid we monitor
sleep 100 & CTRL=$!
# fake "sshd" — its own process group (setsid), like the real start_sshd sets up
setsid sleep 100 & FAKE_SSHD=$!
sleep 0.2
group_alive "$FAKE_SSHD" && ok "fake sshd group is up before the kill" || bad "fake sshd group never started"

FLOO_WATCHDOG_POLL_INTERVAL=1 start_sshd_watchdog "$CTRL" "$FAKE_SSHD"
[ -n "$WATCHDOG_PID" ] && kill -0 "$WATCHDOG_PID" 2>/dev/null && ok "watchdog subshell is running" || bad "no watchdog pid / not running"

# kill the "controller" hard, the way a crash/SIGKILL would
kill -KILL "$CTRL" 2>/dev/null
wait "$CTRL" 2>/dev/null

gone=0
for _ in $(seq 1 25); do   # ~5s at 0.2s steps
  group_alive "$FAKE_SSHD" || { gone=1; break; }
  sleep 0.2
done
[ "$gone" = 1 ] && ok "fake sshd's process group is gone within ~5s of the controller dying" \
                 || bad "fake sshd group survived the controller's death"

# cleanup (best-effort, in case the assertion above failed)
kill -KILL "-$FAKE_SSHD" 2>/dev/null
[ -n "${WATCHDOG_PID:-}" ] && kill -KILL "$WATCHDOG_PID" 2>/dev/null

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
