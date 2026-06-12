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
# (#5) a forged alt-screen must NOT blind the parser to subsequent hooked markers
RM="$(b64 'rm -rf /important')"
out="$(render "$(m "cmd;$(b64 'vim x')")$(m out)\033[?1049h$(m "cmd;$RM")$(m out)\033[?1049l$(m 'end;0')")"
grep -qx '$ rm -rf /important' <<<"$out" && ok "alt-screen blackout cannot hide a hooked command" || bad "alt-screen hid a hooked command: [$out]"

echo "=== renderer: full-screen collapse ==="
stream="$(m "cmd;$(b64 'vim /etc/hosts')")$(m out)\033[?1049hGARBAGE_REPAINT\033[?1049l$(m 'end;0')"
out="$(render "$stream")"
grep -q '▶ operator opened: vim /etc/hosts' <<<"$out" && ok "alt-screen enter collapses to one line" || bad "no collapse: [$out]"
grep -q 'GARBAGE_REPAINT' <<<"$out" && bad "raw TUI repaint leaked into the log" || ok "TUI repaint suppressed"
grep -q '◀ closed' <<<"$out" && ok "alt-screen exit prints closed" || bad "no close line: [$out]"

echo "=== degradation: renderer is a no-op-safe filter without markers ==="
out="$(render 'just plain output\nsecond line\n')"
grep -qx 'just plain output' <<<"$out" && grep -qx 'second line' <<<"$out" \
  && ok "marker-less stream renders as plain lines (heuristic rung)" || bad "plain fallback broken: [$out]"

# decode every cmd marker a hooked shell emits and assert it equals the TYPED command (not the
# PROMPT_COMMAND body, not a truncated pipeline). This is the assertion whose absence let the
# mis-capture bug ship. Driven through a REAL pty with a user PROMPT_COMMAND set.
hook_captures() {  # <shell> -> prints the decoded commands the client would see, one per line
  local sh="$1" rc home
  rc="$(mktemp)"; "$FLOO" --emit-hook "$sh" "$N" > "$rc"
  home="$(mktemp -d)"
  printf 'PROMPT_COMMAND='\''printf "\\033]0;%%s\\007" "$PWD"'\''\n' > "$home/.bashrc"
  printf 'precmd(){ true; }\n' > "$home/.zshrc"
  FLOO_HOOK_RC="$rc" FLOO_HOOK_HOME="$home" FLOO_HOOK_SHELL="$sh" FLOO_HOOK_NONCE="$N" python3 - <<'PY'
import os,pty,base64,re,time,sys
rc=os.environ['FLOO_HOOK_RC']; home=os.environ['FLOO_HOOK_HOME']
sh=os.environ['FLOO_HOOK_SHELL']; nonce=os.environ['FLOO_HOOK_NONCE']
pid,fd=pty.fork()
if pid==0:
    os.environ['HOME']=home
    if sh=='bash': os.execvp('bash',['bash','--rcfile',rc,'-i'])
    else:
        os.environ['ZDOTDIR']=os.path.dirname(rc); os.environ['__FLOO_REAL_ZDOTDIR']='/nonexistent'
        # zsh reads .zshrc from ZDOTDIR; put our hook there
        open(os.path.join(os.path.dirname(rc),'.zshrc'),'w').write(open(rc).read())
        os.execvp('zsh',['zsh','-i'])
for c in [b'echo ALPHA\n', b'true | cat | cat\n', b'exit\n']:
    os.write(fd,c); time.sleep(0.5)
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

echo "=== hook rcfile: bash (captures the RIGHT command, despite a custom PROMPT_COMMAND) ==="
caps="$(hook_captures bash)"
grep -qx 'echo ALPHA' <<<"$caps" && ok "bash hook captures the typed command" || bad "bash captured wrong: [$caps]"
grep -qx 'true | cat | cat' <<<"$caps" && ok "bash hook captures the FULL pipeline" || bad "bash truncated pipeline: [$caps]"
grep -q 'PROMPT_COMMAND\|printf .*033]0' <<<"$caps" && bad "bash leaked the PROMPT_COMMAND body" || ok "bash does NOT leak the PROMPT_COMMAND body"

echo "=== hook rcfile: zsh ==="
if command -v zsh >/dev/null 2>&1; then
  caps="$(hook_captures zsh)"
  grep -qx 'echo ALPHA' <<<"$caps" && ok "zsh hook captures the typed command" || bad "zsh captured wrong: [$caps]"
  grep -qx 'true | cat | cat' <<<"$caps" && ok "zsh hook captures the full pipeline" || bad "zsh pipeline: [$caps]"
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
grep -q 'waiting for the technician' <<<"$frame" && ok "paints the waiting status" || bad "no status line: [$frame]"
grep -qE '\^\[\[r' <<<"$frame" && ok "restores the full scroll region on teardown" || bad "no region reset: [$frame]"

echo "=== saved recording cleanup (renders markers to \$ cmd, strips raw OSC) ==="
CD="$(mktemp -d)"
printf '%b' "before\n$(m "cmd;$(b64 'echo hidden')")$(m out)visible\n$(m 'end;0')" > "$CD/session.log"
FLOO_TESTING=1 FLOO_MARK_NONCE="$N" "$FLOO" --clean-dir "$CD" 2>/dev/null
cleaned="$(cat "$CD/session.log")"
grep -q '1337;floo' <<<"$cleaned" && bad "cleaned recording leaked raw floo OSC markers" || ok "cleaned recording strips raw floo OSC markers"
grep -qx '$ echo hidden' <<<"$cleaned" && ok "cleaned recording renders the command line" || bad "cleaned lost the command: [$cleaned]"
grep -q 'visible' <<<"$cleaned" && ok "cleaned recording keeps real output" || bad "cleaned recording lost real output: [$cleaned]"
rm -rf "$CD"

echo "=== no temp-file leak from --render ==="
before=$(ls "${TMPDIR:-/tmp}"/floo-render.* 2>/dev/null | wc -l)
for i in 1 2 3; do printf 'x\n' | FLOO_MARK_NONCE="$N" "$FLOO" --render >/dev/null 2>&1; done
after=$(ls "${TMPDIR:-/tmp}"/floo-render.* 2>/dev/null | wc -l)
[ "$after" -le "$before" ] && ok "--render leaves no temp renderer files behind" || bad "leaked $((after-before)) temp files"

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
