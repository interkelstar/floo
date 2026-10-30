#!/usr/bin/env bash
set -uo pipefail
FLOO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/floo"
P=0; F=0
ok(){ echo "  PASS $1"; P=$((P+1)); }
bad(){ echo "  FAIL $1"; F=$((F+1)); }
N="testnonce0123456789abcdef"                         # the per-session marker nonce, under test
render(){ printf '%b' "$1" | FLOO_MARK_NONCE="$N" "$FLOO" --render 2>/dev/null; }
m(){ printf '\033]1337;floo;%s;%s\007' "$N" "$1"; }   # a NONCE-stamped marker (what the hooks emit)
b64(){ printf '%s' "$1" | base64 | tr -d '\n'; }

echo "=== renderer: plain output ==="
out="$(render '\033[32mhello world\033[0m\n')"
[ "$out" = "hello world" ] && ok "strips SGR color, keeps text" || bad "plain got: [$out]"
out="$(render 'abc\rxyz\n')"
[ "$out" = "xyz" ] && ok "CR redraw collapses to final line" || bad "CR got: [$out]"

echo "=== renderer: command markers (nonce-stamped) ==="
stream="$(m "cmd;$(b64 'systemctl restart nginx')")$(m out)done\n$(m 'end;0')"
out="$(render "$stream")"
grep -qx '$ systemctl restart nginx' <<<"$out" && ok "cmd marker prints \$ <command>" || bad "cmd line missing: [$out]"
grep -qx 'done' <<<"$out" && ok "output after out-marker is shown" || bad "output missing: [$out]"
grep -q 'exit' <<<"$out" && bad "exit 0 should be silent" || ok "exit 0 is silent"
streamf="$(m "cmd;$(b64 false)")$(m out)$(m 'end;1')"
grep -q 'exit 1' <<<"$(render "$streamf")" && ok "non-zero exit is surfaced" || bad "exit 1 not surfaced"
out="$({ printf '%*s' 65535 '' | tr ' ' '\001'; printf '%b' "$(m "cmd;$(b64 'chunked marker')")$(m out)OK\n"; } | FLOO_MARK_NONCE="$N" "$FLOO" --render 2>/dev/null)"
grep -qx '$ chunked marker' <<<"$out" && grep -qx 'OK' <<<"$out" \
  && ok "markers split across read chunks are preserved" || bad "split marker failed: [$out]"
multi="$(m "cmd;$(b64 'echo one
echo two')")$(m out)$(m 'end;0')"
out="$(render "$multi")"
grep -qx '$ echo one' <<<"$out" && grep -qx '  echo two' <<<"$out" \
  && ok "multi-line (exec) command renders as continuation lines" || bad "multiline cmd: [$out]"

echo "=== SECURITY: command output cannot forge or smuggle into the live view ==="
# (#3) output carrying a marker but NO nonce must NOT forge a command line
out="$(render "real\n$(printf '\033]1337;floo;cmd;%s\007' "$(b64 'rm -rf /')")tail\n")"
grep -q 'rm -rf /' <<<"$out" && bad "FORGERY: no-nonce output forged a command" || ok "no-nonce output cannot forge a \$ command line"
# (#3) output carrying a marker with the WRONG nonce must NOT forge either
out="$(render "$(printf '\033]1337;floo;%s;cmd;%s\007' deadbeef "$(b64 'rm -rf /')")")"
grep -q 'rm -rf /' <<<"$out" && bad "FORGERY: wrong-nonce output forged a command" || ok "wrong-nonce output cannot forge a \$ command line"
# (#4/#15) escapes inside a VALID cmd label must be stripped (no raw ESC reaches the client tty)
out="$(render "$(m "cmd;$(b64 "$(printf 'x\033[999;1H\033[2KFORGED')")")" | cat -v)"
{ grep -q 'xFORGED' <<<"$out" && ! grep -q '\^\[' <<<"$out"; } && ok "escapes in the command label are stripped" || bad "raw escape survived in label: [$out]"
# (#5) a forged alt-screen in OUTPUT must NOT hide subsequent hooked markers...
RM="$(b64 'rm -rf /important')"
out="$(render "$(m "cmd;$(b64 'vim x')")$(m out)\033[?1049h$(m "cmd;$RM")$(m out)\033[?1049l$(m 'end;0')")"
grep -qx '$ rm -rf /important' <<<"$out" && ok "forged alt-screen cannot hide a hooked command" || bad "alt-screen hid a hooked command: [$out]"
# ...and must NOT hide subsequent OUTPUT either (the renderer never suppresses on output bytes)
out="$(render "$(m "cmd;$(b64 'cat f')")$(m out)visible-before\n\033[?1049hSECRET_AFTER_ALT\nmore\n$(m 'end;0')")"
{ grep -qx 'visible-before' <<<"$out" && grep -q 'SECRET_AFTER_ALT' <<<"$out" && grep -qx 'more' <<<"$out"; } \
  && ok "forged alt-screen cannot hide subsequent OUTPUT (live or saved)" || bad "alt-screen hid output: [$out]"
# the alt-screen toggle itself is consumed as a no-op CSI (no raw 1049h leaks as text)
grep -q '1049' <<<"$out" && bad "raw alt-screen sequence leaked as text" || ok "alt-screen toggle consumed, not leaked"
# a cursor-forward/absolute-column escape in OUTPUT must NOT balloon the line buffer / recording
sz="$(printf '\033[10000000CX\n' | FLOO_MARK_NONCE="$N" "$FLOO" --render 2>/dev/null | wc -c)"
[ "$sz" -lt 5000 ] && ok "cursor-column escape is clamped (no buffer balloon)" || bad "balloon: $sz bytes"
# 8-bit C1 controls (U+0080-U+009F) must be stripped, never reach the client terminal raw
hex="$(printf 'out\xc2\x9brTRAIL\n' | FLOO_MARK_NONCE="$N" "$FLOO" --render 2>/dev/null | od -An -tx1 | tr -d ' \n')"
grep -q 'c29b' <<<"$hex" && bad "8-bit C1 leaked to stdout: $hex" || ok "8-bit C1 controls stripped"

echo "=== degradation: renderer is a no-op-safe filter without markers ==="
out="$(render 'just plain output\nsecond line\n')"
grep -qx 'just plain output' <<<"$out" && grep -qx 'second line' <<<"$out" \
  && ok "marker-less stream renders as plain lines (heuristic rung)" || bad "plain fallback broken: [$out]"

# Drive a REAL interactive shell through a pty and DECODE the cmd markers — the assertion whose
# absence let the mis-capture bug ship. Parameterized over the user's rc body and the typed lines
# (an empty arg = a bare Enter), so we can exercise the hard PROMPT_COMMAND shapes.
# usage: hook_captures <shell> <rc-body> <line> [line ...]  -> decoded commands, one per line
hook_captures() {
  local sh="$1" body="$2"; shift 2
  local rc home; rc="$(mktemp)"; "$FLOO" --emit-hook "$sh" "$N" > "$rc"
  home="$(mktemp -d)"; printf '%s\n' "$body" > "$home/.bashrc"; printf '%s\n' "$body" > "$home/.zshrc"
  FLOO_HK_RC="$rc" FLOO_HK_HOME="$home" FLOO_HK_SH="$sh" FLOO_HK_N="$N" \
  FLOO_HK_LINES="$(printf '%s\x1f' "$@")" python3 - <<'PY'
import os,pty,base64,re,time
rc=os.environ['FLOO_HK_RC']; home=os.environ['FLOO_HK_HOME']; sh=os.environ['FLOO_HK_SH']; nonce=os.environ['FLOO_HK_N']
lines=os.environ['FLOO_HK_LINES'].split('\x1f')
if lines and lines[-1]=='': lines.pop()
pid,fd=pty.fork()
if pid==0:
    os.environ['HOME']=home
    if sh=='bash': os.execvp('bash',['bash','--rcfile',rc,'-i'])
    else:
        zd=os.path.dirname(rc); os.environ['ZDOTDIR']=zd; os.environ['__FLOO_REAL_ZDOTDIR']='/nonexistent'
        open(os.path.join(zd,'.zshrc'),'w').write(open(rc).read())
        os.execvp('zsh',['zsh','-i'])
for c in lines+['exit']:
    os.write(fd,(c+'\n').encode()); time.sleep(0.35)
buf=b''
try:
    while True:
        d=os.read(fd,65536)
        if not d: break
        buf+=d
except OSError: pass
for mm in re.findall(('1337;floo;%s;cmd;([A-Za-z0-9+/=]*)'%nonce).encode(),buf):
    try: print(base64.b64decode(mm).decode('utf-8','replace'))
    except Exception: pass
PY
  rm -rf "$rc" "$home"
}

echo "=== hook rcfile: bash (correct capture across hard PROMPT_COMMAND shapes) ==="
# string PROMPT_COMMAND + a bare Enter between two commands (the empty-line duplicate case)
caps="$(hook_captures bash 'PROMPT_COMMAND='\''printf "\033]0;x\007"'\''' 'echo ALPHA' '' 'true | cat | cat')"
grep -qx 'echo ALPHA' <<<"$caps" && ok "bash captures the typed command" || bad "bash captured wrong: [$caps]"
grep -qx 'true | cat | cat' <<<"$caps" && ok "bash captures the FULL pipeline" || bad "bash truncated pipeline: [$caps]"
[ "$(grep -cx 'echo ALPHA' <<<"$caps")" = 1 ] && ok "bash: empty line does NOT duplicate the prior command" || bad "bash duplicated on empty line: [$caps]"
grep -q 'PROMPT_COMMAND\|033]0\|printf ' <<<"$caps" && bad "bash leaked the PROMPT_COMMAND body" || ok "bash does NOT leak the PROMPT_COMMAND body"
# ARRAY PROMPT_COMMAND (modern Fedora default shape) — must not clobber it or mislabel
caps="$(hook_captures bash 'PROMPT_COMMAND=('\''printf "\033]0;x\007"'\'')' 'echo BETA')"
grep -qx 'echo BETA' <<<"$caps" && ok "bash handles an ARRAY PROMPT_COMMAND" || bad "array PROMPT_COMMAND broke capture: [$caps]"
# HISTCONTROL=ignorespace + a space-prefixed command must NOT be mislabeled as the previous one
caps="$(hook_captures bash 'HISTCONTROL=ignorespace' 'echo FIRST' ' echo SPACED_SECOND')"
grep -q 'echo SPACED_SECOND' <<<"$caps" && ok "bash labels a space-prefixed cmd correctly (no prior-cmd mislabel)" || bad "ignorespace mislabel: [$caps]"
# a string PROMPT_COMMAND ending in a separator must NOT break capture for the whole session
caps="$(hook_captures bash 'PROMPT_COMMAND='\''true;'\''' 'echo SEP_END')"
grep -qx 'echo SEP_END' <<<"$caps" && ok "bash survives a PROMPT_COMMAND ending in ';'" || bad "trailing-separator PROMPT_COMMAND killed capture: [$caps]"
caps="$(hook_captures bash 'PROMPT_COMMAND='\''   '\''' 'echo WS_PC')"
grep -qx 'echo WS_PC' <<<"$caps" && ok "bash survives a whitespace-only PROMPT_COMMAND" || bad "whitespace PROMPT_COMMAND killed capture: [$caps]"

echo "=== hook rcfile: zsh ==="
if command -v zsh >/dev/null 2>&1; then
  caps="$(hook_captures zsh 'precmd(){ true; }' 'echo ALPHA' '' 'true | cat | cat')"
  grep -qx 'echo ALPHA' <<<"$caps" && ok "zsh captures the typed command" || bad "zsh captured wrong: [$caps]"
  grep -qx 'true | cat | cat' <<<"$caps" && ok "zsh captures the full pipeline" || bad "zsh pipeline: [$caps]"
else
  ok "zsh not installed - skipping zsh hook test"
fi

echo "=== exec/bot path: marker carries the real script, not 'bash -s' ==="
# mirror what record-session's exec branch writes: cmd marker = base64 of the piped SCRIPT
EXECLOG="$(m "cmd;$(b64 'echo MARKER123; ls /nope')")$(m out)MARKER123\n$(m 'end;0')"
out="$(render "$EXECLOG")"
grep -qx '$ echo MARKER123; ls /nope' <<<"$out" && ok "exec marker renders the real script" || bad "exec render: [$out]"
grep -q 'bash -s' <<<"$out" && bad "exec view showed the 'bash -s' shuttle" || ok "exec view does not show 'bash -s'"

echo "=== console frame: scroll region setup/teardown ==="
frame="$("$FLOO" --console-frame 2>/dev/null | cat -v)"
grep -q '1;.*r' <<<"$frame" && ok "sets a DECSTBM scroll region" || bad "no scroll region: [$frame]"
grep -q 'waiting for your helper' <<<"$frame" && ok "paints the waiting status" || bad "no status line: [$frame]"
grep -qE '\^\[\[r' <<<"$frame" && ok "restores the full scroll region on teardown" || bad "no region reset: [$frame]"

echo "=== saved recording: raw .raw preserved, readable .log rendered alongside ==="
CD="$(mktemp -d)"
# the raw .raw includes a non-floo OSC wrapping output (the hide vector) — it MUST survive in the raw copy
printf '%b' "before\n$(m "cmd;$(b64 'echo hidden')")$(m out)visible\n\033]666;WRAPPED_SECRET\007after\n$(m 'end;0')" > "$CD/session.raw"
raw_before="$(cat "$CD/session.raw")"
FLOO_TESTING=1 FLOO_MARK_NONCE="$N" "$FLOO" --clean-dir "$CD" 2>/dev/null
# the raw .raw is left UNTOUCHED (complete, tamper-evident — incl. the OSC-wrapped secret)
[ "$(cat "$CD/session.raw")" = "$raw_before" ] && ok "raw .raw is left intact (complete record)" || bad "raw .raw was modified"
grep -q 'WRAPPED_SECRET' "$CD/session.raw" && ok "raw .raw preserves OSC-wrapped output (no evidence destruction)" || bad "raw lost the wrapped output"
# the readable .log is the rendered command-log
rl="$(cat "$CD/session.log" 2>/dev/null)"
grep -q '1337;floo' <<<"$rl" && bad "readable .log leaked raw floo OSC markers" || ok "readable .log strips raw floo OSC markers"
grep -qx '$ echo hidden' <<<"$rl" && ok "readable .log renders the command line" || bad "readable lost the command: [$rl]"
grep -q 'visible' <<<"$rl" && ok "readable .log keeps shown output" || bad "readable lost shown output: [$rl]"
rm -rf "$CD"

echo "=== LIVE console: tail -F of a session.raw created AFTER the tail starts (the A-bug) ==="
LD="$(mktemp -d)"; mkdir -p "$LD/recording"
( tail -n +1 -F "$LD/recording/session.raw" 2>/dev/null | FLOO_MARK_NONCE="$N" "$FLOO" --render ) > "$LD/live.out" 2>/dev/null &
LPID=$!; sleep 0.8
{ printf '=== session ===\n'; m prompt; printf 'h ~ \xc2\xbb id\r\n'; m "cmd;$(b64 'id -un')"; m out; printf 'kelstar\n'; m 'end;0'; m prompt; } >> "$LD/recording/session.raw"
sleep 1.5; kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
{ grep -qx '$ id -un' "$LD/live.out" && grep -qx 'kelstar' "$LD/live.out"; } && ok "live pane shows the command from a late-created session.raw" || bad "live pane blank: [$(cat "$LD/live.out")]"
grep -q 'h ~ ' "$LD/live.out" && bad "live pane leaked the raw prompt/echo (dedup failed)" || ok "live pane suppressed the prompt/echo (no 3x)"
rm -rf "$LD"

echo "=== LIVE console: concurrent connections + transfer disclosure can't be swallowed (suppression bugs) ==="
# Every operator connection appends to the ONE shared session.raw; the renderer concatenates them.
# A connection's `end` marker must NOT latch suppression and eat a CONCURRENT connection's output.
stream="$(m "cmd;$(b64 'A: systemctl status')")$(m out)A-OUTPUT\n$(m 'end;0')B-CONCURRENT-OUTPUT\nB-line2\n"
out="$(render "$stream")"
{ grep -qx 'A-OUTPUT' <<<"$out" && grep -qx 'B-CONCURRENT-OUTPUT' <<<"$out" && grep -qx 'B-line2' <<<"$out"; } \
  && ok "output after another connection's 'end' marker is NOT suppressed" || bad "concurrent output suppressed after end: [$out]"
# A `prompt` marker suppresses only the single prompt+echo LINE, then self-limits — a concurrent
# connection's output on the NEXT line must render (a latched flag would eat it).
stream="$(m prompt)PROMPT-AND-ECHO-LINE\nCONCURRENT-B-OUTPUT\n"
out="$(render "$stream")"
{ ! grep -q 'PROMPT-AND-ECHO-LINE' <<<"$out" && grep -qx 'CONCURRENT-B-OUTPUT' <<<"$out"; } \
  && ok "prompt suppression self-limits to one line (next-line output renders)" || bad "prompt over-suppressed: [$out]"
# The file-transfer disclosure is emitted by the recorder as a nonce `cmd` marker, so even right after
# a `prompt` (which suppresses) the `cmd` resets suppression and the disclosure is shown to the client.
stream="$(m "cmd;$(b64 'ls')")$(m out)$(m 'end;0')$(m prompt)$(m "cmd;$(b64 'file transfer (binary — recorded as the command only): scp -t /home/u/secret')")$(m out)$(m 'end;0')"
out="$(render "$stream")"
grep -q 'file transfer.*scp -t /home/u/secret' <<<"$out" && ok "file-transfer disclosure renders after a prior command" || bad "transfer disclosure suppressed: [$out]"

echo "=== no temp-file leak from --render ==="
before=$(ls "${TMPDIR:-/tmp}"/floo-render.* 2>/dev/null | wc -l)
for _ in 1 2 3; do printf 'x\n' | FLOO_MARK_NONCE="$N" "$FLOO" --render >/dev/null 2>&1; done
after=$(ls "${TMPDIR:-/tmp}"/floo-render.* 2>/dev/null | wc -l)
[ "$after" -le "$before" ] && ok "--render leaves no temp renderer files behind" || bad "leaked $((after-before)) temp files"

echo "=== renderer: util-linux script(1) header/footer are not rendered (0.8.2) ==="
out="$(render 'Script started on 2026-10-30 13:17:05+00:00 [COMMAND="/bin/bash --rcfile /x/hook.bash -i " TERM="x"]\n$ hostname\nbox\n\nScript done on 2026-10-30 13:17:15+00:00 [COMMAND_EXIT_CODE="0"]\n')"
grep -q 'Script started' <<<"$out" && bad "script(1) header leaked into the rendered view" || ok "script(1) 'Script started' header is dropped"
grep -q 'Script done' <<<"$out" && bad "script(1) footer leaked into the rendered view" || ok "script(1) 'Script done' footer is dropped"
grep -qx 'box' <<<"$out" && ok "real output around the headers is kept" || bad "output lost around headers: [$out]"

echo "=== renderer: the user's Ctrl-C never paints a traceback (0.8.2) ==="
# The renderer sits in the user's foreground process group, so Ctrl-C reaches it mid-read. Mimic that:
# its own process group (job control on), the renderer blocked on a slow stdin, INT to the whole group.
tmp="$(mktemp "${TMPDIR:-/tmp}/floo-sigint.XXXXXX")"
# Job control ON (set -m) so the background pipeline gets its own process group AND keeps SIGINT at
# its default disposition, as under a real terminal. (A plain `&` without job control makes bash
# ignore INT for the child — inherited by python3 — and the test would pass vacuously, even on
# the 0.8.1 code that painted the traceback live.) Scoped in a subshell; the verdict comes out as text.
# Two vacuity guards: the renderer must be SEEN running, and the launched floo must NOT have INT
# already ignored on entry (bash cannot un-ignore an inherited ignore; nohup/CI wrappers do that) —
# read from /proc/<pid>/status SigIgn, bit 2 = SIGINT.
verdict="$(
  set -m
  sleep 3 | FLOO_MARK_NONCE="$N" "$FLOO" --render >"$tmp" 2>&1 &
  jpid=$!
  set +m
  pgid=""; py=""
  for _ in $(seq 1 25); do
    sleep 0.1
    pgid="$(ps -o pgid= -p "$jpid" 2>/dev/null | tr -d ' ')"
    [ -n "$pgid" ] && py="$(pgrep -g "$pgid" -x python3 2>/dev/null | head -1)"
    [ -n "$py" ] && break
  done
  sigign="$(awk '/^SigIgn:/{print $2}' "/proc/$jpid/status" 2>/dev/null)"
  if [ -n "$sigign" ] && (( 0x$sigign & 2 )); then echo VACUOUS-INHERITED-IGN; kill -- -"$pgid" 2>/dev/null; wait "$jpid" 2>/dev/null; exit 0; fi
  sleep 0.3   # past the renderer's own startup, so we test steady state, not the import race
  [ -n "$pgid" ] && kill -INT -- -"$pgid" 2>/dev/null
  wait "$jpid" 2>/dev/null
  if [ -z "$py" ]; then echo VACUOUS
  elif grep -q 'Traceback\|KeyboardInterrupt' "$tmp"; then echo TRACEBACK
  else echo OK; fi
)"
case "$verdict" in
  OK) ok "SIGINT to the group: renderer stays quiet, no traceback" ;;
  TRACEBACK) bad "SIGINT painted a traceback: $(head -c 300 "$tmp")" ;;
  VACUOUS-INHERITED-IGN) bad "SIGINT test is vacuous here: this shell inherited INT ignored (nohup/CI wrapper) — run it from a normal shell" ;;
  *) bad "SIGINT test never saw the renderer running (vacuous)" ;;
esac
rm -f "$tmp"

echo "=== recorder: script(1) runs with -f so the live pane streams, not buffers (0.8.2) ==="
# Static lock: without --flush util-linux `script` buffers session.raw and the live pane shows the
# helper's commands only at disconnect (every Debian/Ubuntu box in 0.8.1). The live proof is a
# session on a box WITH script(1); this keeps the flag from being dropped by accident.
grep -q 'script -q -f -a "\$log"' "$FLOO" && ok "script(1) is invoked with -f (flush)" || bad "script(1) call lacks -f: live pane would buffer until disconnect"

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
