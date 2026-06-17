#!/usr/bin/env bash
# Tests the record-session recorder logic (extracted from the floo client's REC heredoc): the
# binary-transfer fast path can't be abused to run unrecorded commands, the cmd marker carries the
# REAL command for EVERY operator invocation shape (no empty `$`), and the quick-mode probe records
# nothing.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P=0; F=0
ok(){ echo "  PASS $1"; P=$((P+1)); }; bad(){ echo "  FAIL $1"; F=$((F+1)); }

# extract the record-session script verbatim from the single-quoted REC heredoc in `floo`
REC="$(mktemp)"
awk '/record-session" <<.REC.$/{f=1;next} f&&/^REC$/{f=0} f' "$REPO/floo" > "$REC"
[ -s "$REC" ] || { echo "could not extract record-session from floo"; rm -f "$REC"; exit 1; }

run_rec(){ # $1=SSH_ORIGINAL_COMMAND ; stdin = the piped input ; echoes the raw recording
  local soc="$1" d; d="$(mktemp -d)"; mkdir -p "$d/recording" "$d/active"; printf 'testnonce' > "$d/marknonce"
  cp "$REC" "$d/record-session"
  SSH_ORIGINAL_COMMAND="$soc" timeout 8 bash "$d/record-session" >/dev/null 2>&1
  cat "$d"/recording/*.raw 2>/dev/null; rm -rf "$d"
}
cmd_marker(){ # $1=SSH_ORIGINAL_COMMAND ; stdin=piped -> echoes the DECODED cmd-marker label(s)
  local soc="$1" d; d="$(mktemp -d)"; mkdir -p "$d/recording" "$d/active"; printf testnonce > "$d/marknonce"; cp "$REC" "$d/record-session"
  SSH_ORIGINAL_COMMAND="$soc" timeout 8 bash "$d/record-session" >/dev/null 2>&1
  grep -aoP '1337;floo;testnonce;cmd;\K[A-Za-z0-9+/=]*' "$d"/recording/session.raw | while read -r b; do printf '%s' "$b" | base64 -d 2>/dev/null; echo; done
  rm -rf "$d"
}

echo "=== recorder: binary-transfer bypass is closed (chained / option-bearing transfers are teed) ==="
# a command CHAINED behind a transfer-looking prefix must fall through to the teed path → its OUTPUT
# (S_42, distinct from the command string) must appear in the raw recording.
out="$(printf '' | run_rec 'scp -h 2>/dev/null; echo S_$((6*7))')"
grep -q 'S_42' <<<"$out" && ok "chained cmd behind a transfer prefix is recorded (no bypass)" || bad "BYPASS: output S_42 not recorded: [$out]"
out="$(printf '' | run_rec 'rsync --server x 2>/dev/null; echo R_$((6*7))')"
grep -q 'R_42' <<<"$out" && ok "rsync-prefixed chain is recorded too" || bad "BYPASS via rsync prefix: [$out]"
# command-EXECUTING transfer options (scp -S program / rsync --rsh=program) must NOT take the
# unrecorded fast path — they fall through to the teed+marked path, so the cmd marker is the command
# ITSELF (not a 'file transfer' disclosure), proving the command is recorded rather than run silently.
m="$(printf '' | cmd_marker 'scp -S /bin/echo a b')"
[ "$m" = 'scp -S /bin/echo a b' ] && ok "scp -S <program> is teed+recorded, not fast-pathed" || bad "scp -S took the unrecorded fast path: [$m]"
m="$(printf '' | cmd_marker 'rsync --server --rsh=/bin/echo . /tmp/x')"
{ grep -q 'rsync --server --rsh' <<<"$m" && ! grep -q 'file transfer' <<<"$m"; } && ok "rsync --rsh=<program> is teed+recorded, not fast-pathed" || bad "rsync --rsh fast-pathed: [$m]"

echo "=== recorder: a GENUINE binary transfer keeps the command-only fast path (disclosed via marker) ==="
# a pure transfer is disclosed through the NONCE marker channel (not a bare line suppression could eat)
m="$(printf '' | cmd_marker 'scp -t /tmp/nonexistent_floo_xyz')"
grep -q 'file transfer' <<<"$m" && ok "a pure transfer is disclosed through the nonce marker channel" || bad "pure transfer not disclosed via marker: [$m]"
# the benign capability token a real `rsync --server` sends (-e.iLsfxC) must NOT trip the option guard
m="$(printf '' | cmd_marker 'rsync --server -vlogDtpre.iLsfxC . /tmp/x')"
grep -q 'file transfer' <<<"$m" && ok "real 'rsync --server -e.iLsfxC' still fast-paths (no false positive)" || bad "legit rsync --server misclassified as exec: [$m]"

echo "=== recorder: the cmd marker reflects the ACTUAL command for EVERY operator invocation shape ==="
# (a) the `floo-powder exec` shuttle: the real commands are the piped script
[ "$(printf 'uname -s' | cmd_marker 'bash -s')" = 'uname -s' ] && ok "bash -s shuttle marker = the piped script" || bad "bash -s marker wrong: [$(printf 'uname -s' | cmd_marker 'bash -s')]"
# (b) a direct command: the command is SSH_ORIGINAL_COMMAND, no piped stdin
[ "$(printf '' | cmd_marker 'id -un')" = 'id -un' ] && ok "direct 'ssh host id -un' marker = the real command" || bad "direct-command marker wrong: [$(printf '' | cmd_marker 'id -un')]"
# (c) a DIRECT `bash -s <args>` must render the command, NOT an empty '$' (the v0.5.3-reintroduced bug)
[ "$(printf '' | cmd_marker 'bash -s /etc/hostname')" = 'bash -s /etc/hostname' ] && ok "direct 'bash -s <args>' marker = the command (not empty)" || bad "direct 'bash -s <args>' rendered empty: [$(printf '' | cmd_marker 'bash -s /etc/hostname')]"
[ "$(printf '' | cmd_marker 'bash -s -- foo')" = 'bash -s -- foo' ] && ok "direct 'bash -s -- foo' marker = the command" || bad "direct 'bash -s -- foo' wrong: [$(printf '' | cmd_marker 'bash -s -- foo')]"
# (d) the degenerate empty shuttle ('floo-powder exec h </dev/null') labels 'bash -s', never empty
[ "$(printf '' | cmd_marker 'bash -s')" = 'bash -s' ] && ok "empty shuttle labels 'bash -s', never an empty '$'" || bad "empty shuttle rendered empty: [$(printf '' | cmd_marker 'bash -s')]"

echo "=== recorder: the quick-mode 'floo-probe' liveness token records NOTHING and never reads stdin ==="
# even with data on stdin, the probe must exit immediately (before the cat that would otherwise block)
out="$(printf 'STDIN_THAT_WOULD_BLOCK' | timeout 5 bash -c '
  d=$(mktemp -d); mkdir -p "$d/recording" "$d/active"; printf testnonce > "$d/marknonce"
  cp "'"$REC"'" "$d/record-session"
  SSH_ORIGINAL_COMMAND=floo-probe bash "$d/record-session" >/dev/null 2>&1; rc=$?
  cat "$d"/recording/*.raw 2>/dev/null; echo "RC=$rc"; rm -rf "$d"')"
{ grep -q 'RC=0' <<<"$out" && ! grep -q 'STDIN_THAT_WOULD_BLOCK\|floo session' <<<"$out"; } \
  && ok "floo-probe exits 0, records nothing, doesn't block on stdin" || bad "floo-probe misbehaved: [$out]"

rm -f "$REC"
echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
