#!/usr/bin/env bash
# Tests the record-session recorder logic (extracted from the floo client's REC heredoc) — in
# particular that the binary-transfer fast path can't be abused to run unrecorded commands.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P=0; F=0
ok(){ echo "  PASS $1"; P=$((P+1)); }; bad(){ echo "  FAIL $1"; F=$((F+1)); }

# extract the record-session script verbatim from the single-quoted REC heredoc in `floo`
REC="$(mktemp)"
awk '/record-session" <<.REC.$/{f=1;next} f&&/^REC$/{f=0} f' "$REPO/floo" > "$REC"
[ -s "$REC" ] || { echo "could not extract record-session from floo"; rm -f "$REC"; exit 1; }

run_rec(){ # $1=SSH_ORIGINAL_COMMAND ; stdin = the piped input ; echoes the recording log
  local soc="$1" d; d="$(mktemp -d)"; mkdir -p "$d/recording" "$d/active"; printf 'testnonce' > "$d/marknonce"
  cp "$REC" "$d/record-session"
  SSH_ORIGINAL_COMMAND="$soc" bash "$d/record-session" >/dev/null 2>&1
  cat "$d"/recording/*.raw 2>/dev/null; rm -rf "$d"
}

echo "=== recorder: binary-transfer bypass is closed ==="
# a command CHAINED behind a transfer-looking prefix must fall through to the teed path → its
# OUTPUT (S_42, distinct from the command string) must appear in the raw recording.
out="$(printf '' | run_rec 'scp -h 2>/dev/null; echo S_$((6*7))')"
grep -q 'S_42' <<<"$out" && ok "chained cmd behind a transfer prefix is recorded (no bypass)" || bad "BYPASS: output S_42 not recorded: [$out]"
out="$(printf '' | run_rec 'rsync --server x 2>/dev/null; echo R_$((6*7))')"
grep -q 'R_42' <<<"$out" && ok "rsync-prefixed chain is recorded too" || bad "BYPASS via rsync prefix: [$out]"
# a PURE transfer invocation still uses the command-only fast path (no deadlock-prone teeing)
out="$(printf '' | run_rec 'scp -t /tmp/nonexistent_floo_xyz')"
grep -q 'file transfer' <<<"$out" && ok "a pure transfer keeps the command-only fast path" || bad "pure transfer misclassified: [$out]"

rm -f "$REC"
echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
