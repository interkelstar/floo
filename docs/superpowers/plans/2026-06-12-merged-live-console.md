# floo Merged Live Console Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace floo's two-window `monitor()`+`--watch` split with one default window — a scrolling command-log pane above a pinned status line — so a single-terminal client sees the operator act in real time and can make an informed Ctrl-C.

**Architecture:** The operator's shell emits invisible private-OSC markers (`ESC]1337;floo;cmd|out|end…BEL`) delimiting each command + its output; injected bash/zsh hooks produce them on the interactive path, and the exec/bot path emits them directly. A python renderer (an extension of the existing `clean_recordings` terminal-emulator) tails the raw recording, parses the markers, prints clean `$ cmd`/output lines, and collapses full-screen TUI apps to a one-liner. A bash wrapper paints those lines inside a DECSTBM scroll region with a status line glued to the bottom row.

**Tech Stack:** Bash (the single `floo` client file, incl. its embedded `REC` heredoc), python3 (renderer, mirroring `relay.py`/`clean_recordings`), `base64` (coreutils), util-linux `script` / the existing pty `relay.py`. No relay or wire-protocol change; `bin/floo-powder` and `scripts/embed.sh` are untouched.

**Spec:** `docs/superpowers/specs/2026-06-12-merged-live-console-design.md`

**Conventions to follow (from the existing codebase):**
- The client is one monolithic bash file `floo`. Add functions near related code; mirror the existing style (lowercase helpers, `warn`/`info`/`ok`/`say` for output, `umask 077`).
- Unit tests live in `test/unit/*.sh`, invoke the `floo` client as a subprocess, set `HOME=$(mktemp -d)`, and use the `ok(){ … P++ }` / `bad(){ … F++ }` counter pattern, ending with `[ "$F" -eq 0 ]`. Register new unit files in `test/run-all.sh`.
- A python script that must read stdin **must be written to a file and run** (`python3 "$f"`), never `python3 - <<'PY'` (the heredoc would become stdin — see the `relay.py` comment at `floo:198`).
- Markers use `ESC`=`\033`, `BEL`=`\007`. Private-OSC form: `\033]1337;floo;<kind>[;<arg>]\007`.

---

## File Structure

- **`floo`** (modify) — the only source file changed. New functions: `write_render_py` + `render_stream` (the python renderer + its bash entry), `floo_hook_rc` (bash/zsh hook rcfile content, single source of truth), `render_console` (scroll-region + status-line wrapper, replaces `monitor()` body and folds in `watch_attach`). New internal modes `--render` and `--emit-hook` (test seams, not in `usage`). The `REC` heredoc in `build_endpoint` gains marker emission on the exec path and hook-launch on the interactive path. `run_session` makes `render_console` the default; teardown restores the terminal.
- **`test/unit/render.sh`** (create) — pure-function tests for the renderer (`--render`) and the hook rcfiles (`--emit-hook`). No sshd.
- **`test/loopback.sh`** (modify) — extend the existing single-host e2e to assert the merged console shows command-level activity, markers land in the recording, and the raw recording stays clean after `clean_recordings`.
- **`test/run-all.sh`** (modify) — register `unit/render.sh`.
- **`VERSION`, `CHANGELOG.md`, `README.md`** (modify) — 0.5.0 + the new default-view description.

---

## Task 1: Renderer — plain output passthrough + `--render` seam

**Files:**
- Modify: `floo` (add `write_render_py`, `render_stream`; add `--render` to `main()`'s arg loop and `case "$mode"`)
- Test: `test/unit/render.sh` (create)

The renderer is a python script (mirroring `clean_recordings`' terminal-emulator) that reads the raw recording on **stdin** and writes clean, plain lines to **stdout**. This task handles only ordinary output (no floo markers yet): it must strip color/cursor/OSC noise and emit finished lines. `--render` is an internal mode that runs exactly this renderer on stdin, so tests drive the real code.

- [ ] **Step 1: Write the failing test**

Create `test/unit/render.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
FLOO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/floo"
P=0; F=0
ok(){ echo "  PASS $1"; P=$((P+1)); }; bad(){ echo "  FAIL $1"; F=$((F+1)); }
render(){ printf '%b' "$1" | "$FLOO" --render 2>/dev/null; }

echo "=== renderer: plain output ==="
# colored prompt + a plain line; renderer strips the SGR color, keeps the text
out="$(render '\033[32mhello world\033[0m\n')"
[ "$out" = "hello world" ] && ok "strips SGR color, keeps text" || bad "plain got: [$out]"
# a carriage-return redraw (line-editor style) collapses to the final visible line
out="$(render 'abc\rxyz\n')"
[ "$out" = "xyz" ] && ok "CR redraw collapses to final line" || bad "CR got: [$out]"

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/unit/render.sh`
Expected: FAIL — `--render` is an unknown option (`floo` prints "unknown option: --render" and exits 1, so `out` is empty).

- [ ] **Step 3: Implement the renderer + `--render` mode**

In `floo`, immediately **above** `clean_recordings()` (around `floo:414`), add the renderer. It reuses the same control-sequence handling as `clean_recordings`' `render()` but operates as a streaming filter (stdin→stdout, flushing each completed line):

```bash
# ─── Live renderer: raw recording stream (stdin) → clean command-log lines (stdout). ─────────
# Mirrors clean_recordings' terminal-emulator, but streams: it flushes each finished line as it
# completes, understands floo's private-OSC markers (added in later steps), and is used by the
# merged console, by --watch, and directly by --render (the test seam). Written to a file (not a
# `python3 - <<PY` heredoc) because it must read the operator's stream on stdin (see relay.py).
RENDER_PY=""
write_render_py() {
  [ -n "$RENDER_PY" ] && return 0
  RENDER_PY="$(mktemp "${TMPDIR:-/tmp}/floo-render.XXXXXX")" || return 1
  cat > "$RENDER_PY" <<'PY'
import sys, os, re, base64
out = sys.stdout
buf = b""
cur = []          # the line being built (terminal-emulator cells)
col = 0
def emit(line):
    out.write(line.rstrip() + "\n"); out.flush()
def put(ch):
    global col
    while len(cur) <= col: cur.append(' ')
    cur[col] = ch; col += 1
def flush_line():
    global col
    emit(''.join(cur)); cur[:] = []; col = 0
def feed(text):
    global col
    i = 0; n = len(text)
    while i < n:
        ch = text[i]
        if ch == '\x1b':
            if i+1 < n and text[i+1] == '[':                 # CSI
                j = i+2
                while j < n and text[j] in '0123456789;?': j += 1
                while j < n and ' ' <= text[j] <= '/': j += 1
                if j < n:
                    f = text[j]; p = re.sub(r'\?', '', text[i+2:j])
                    nums = [int(x) for x in p.split(';') if x.isdigit()] or [0]
                    if f == 'K':
                        m = nums[0]
                        if m == 0: del cur[col:]
                        elif m == 1:
                            for k in range(min(col+1, len(cur))): cur[k] = ' '
                        else: cur[:] = []
                    elif f == 'C': col += (nums[0] or 1)
                    elif f == 'D': col = max(0, col-(nums[0] or 1))
                    elif f == 'G': col = max(0, (nums[0] or 1)-1)
                    elif f in ('H', 'f'): col = 0
                    i = j+1; continue
                i = j; continue
            if i+1 < n and text[i+1] == ']':                 # OSC: skip to BEL/ST
                j = i+2
                while j < n and text[j] not in '\x07\x1b': j += 1
                if j < n and text[j] == '\x1b' and j+1 < n and text[j+1] == '\\': j += 1
                i = j+1; continue
            i += 2; continue
        if ch == '\r': col = 0; i += 1; continue
        if ch == '\n': flush_line(); i += 1; continue
        if ch == '\b': col = max(0, col-1); i += 1; continue
        if ch == '\t': put(' '); i += 1; continue
        if ord(ch) < 32: i += 1; continue
        put(ch); i += 1
while True:
    try: chunk = os.read(0, 65536)
    except OSError: break
    if not chunk: break
    buf += chunk
    # decode only up to the last complete byte we can; keep a small tail for split escapes
    text = buf.decode('utf-8', 'replace'); buf = b""
    feed(text)
if cur: flush_line()
PY
}
render_stream() { write_render_py || return 1; python3 "$RENDER_PY"; }
```

Then wire the internal mode. In `main()`'s arg loop (the `while [ $# -gt 0 ]` at `floo:701`), add a case alongside `--watch`:

```bash
    --render) mode=render; shift;;
```

And in the `case "$mode"` dispatch (at `floo:724`), add:

```bash
    render) render_stream;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/unit/render.sh`
Expected: PASS — both assertions (`hello world`, `xyz`).

- [ ] **Step 5: Register the unit file and run the suite slice**

Edit `test/run-all.sh`: add after the `unit/embed.sh` line (`floo:13` of that file):

```bash
  bash "$DIR/unit/render.sh" || rc=1
```

Run: `bash test/unit/render.sh`
Expected: PASS (still 2/2).

- [ ] **Step 6: Commit**

```bash
git add floo test/unit/render.sh test/run-all.sh
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' commit -m "feat(console): streaming renderer + --render seam (plain output)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Renderer — floo command markers (`cmd`/`out`/`end`)

**Files:**
- Modify: `floo` (the `RENDER_PY` python in `write_render_py`)
- Test: `test/unit/render.sh`

Teach the renderer floo's private-OSC markers: `\033]1337;floo;cmd;<b64>\007` prints `$ <decoded command>`; `out` switches to output mode; `end;<exit>` prints `↳ exit <n>` only on a non-zero exit. Other OSC sequences are still skipped as before.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/render.sh`, before the final summary block:

```bash
echo "=== renderer: command markers ==="
B64="$(printf '%s' 'systemctl restart nginx' | base64 | tr -d '\n')"
stream="\033]1337;floo;cmd;${B64}\007\033]1337;floo;out\007done\n\033]1337;floo;end;0\007"
out="$(render "$stream")"
grep -qx '$ systemctl restart nginx' <<<"$out" && ok "cmd marker prints \$ <command>" || bad "cmd line missing: [$out]"
grep -qx 'done' <<<"$out" && ok "output after out-marker is shown" || bad "output missing: [$out]"
grep -q 'exit' <<<"$out" && bad "exit 0 should be silent" || ok "exit 0 is silent"
# non-zero exit IS surfaced
B64F="$(printf '%s' 'false' | base64 | tr -d '\n')"
streamf="\033]1337;floo;cmd;${B64F}\007\033]1337;floo;out\007\033]1337;floo;end;1\007"
grep -q 'exit 1' <<<"$(render "$streamf")" && ok "non-zero exit is surfaced" || bad "exit 1 not surfaced"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/unit/render.sh`
Expected: FAIL — the `cmd`/`end` assertions fail (markers are currently swallowed by the generic OSC skip; `$ systemctl…` and `exit 1` never appear).

- [ ] **Step 3: Implement marker handling**

In the `RENDER_PY` python, replace the generic OSC branch (the `if i+1 < n and text[i+1] == ']':` block inside `feed`) with one that first checks for the floo marker:

```python
            if i+1 < n and text[i+1] == ']':                 # OSC
                j = i+2
                while j < n and text[j] not in '\x07\x1b': j += 1
                body = text[i+2:j]
                end = j+1
                if j < n and text[j] == '\x1b' and j+1 < n and text[j+1] == '\\': end = j+2
                m = re.match(r'1337;floo;(\w+)(?:;(.*))?$', body, re.S)
                if m:
                    if cur: flush_line()
                    kind, arg = m.group(1), m.group(2)
                    handle_marker(kind, arg)
                i = end; continue
```

And add, above `feed`, the marker handler + the "last command" / mode state:

```python
state = {"lastcmd": ""}
def handle_marker(kind, arg):
    if kind == "cmd":
        try: cmd = base64.b64decode(arg or "").decode('utf-8', 'replace')
        except Exception: cmd = arg or ""
        state["lastcmd"] = cmd
        emit("$ " + cmd)
    elif kind == "out":
        pass
    elif kind == "end":
        try: code = int(arg or "0")
        except ValueError: code = 0
        if code != 0: emit("  ↳ exit %d" % code)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/unit/render.sh`
Expected: PASS — all command-marker assertions plus the Task 1 plain-output ones.

- [ ] **Step 5: Commit**

```bash
git add floo test/unit/render.sh
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' commit -m "feat(console): renderer parses floo command markers (cmd/out/end)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Renderer — full-screen (alt-screen) collapse

**Files:**
- Modify: `floo` (the `RENDER_PY` python)
- Test: `test/unit/render.sh`

When the operator runs a TUI app, the stream contains an alt-screen enter (`\033[?1049h`) and later exit (`\033[?1049l`). Instead of rendering the app's repaint (which would be garbage in a command log and fight the status line), print `▶ operator opened: <last command>` on enter, suppress everything until exit, then print `◀ closed`.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/render.sh`, before the summary block:

```bash
echo "=== renderer: full-screen collapse ==="
B64V="$(printf '%s' 'vim /etc/hosts' | base64 | tr -d '\n')"
stream="\033]1337;floo;cmd;${B64V}\007\033]1337;floo;out\007\033[?1049hGARBAGE_REPAINT\033[?1049l\033]1337;floo;end;0\007"
out="$(render "$stream")"
grep -q '▶ operator opened: vim /etc/hosts' <<<"$out" && ok "alt-screen enter collapses to one line" || bad "no collapse: [$out]"
grep -q 'GARBAGE_REPAINT' <<<"$out" && bad "raw TUI repaint leaked into the log" || ok "TUI repaint suppressed"
grep -q '◀ closed' <<<"$out" && ok "alt-screen exit prints closed" || bad "no close line: [$out]"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/unit/render.sh`
Expected: FAIL — `GARBAGE_REPAINT` currently leaks through as plain text; no `▶`/`◀` lines.

- [ ] **Step 3: Implement alt-screen handling**

In `RENDER_PY`, add an `alt` flag to the `state` dict and short-circuit in `feed`. Change the `state` init line to:

```python
state = {"lastcmd": "", "alt": False}
```

At the very top of the `while i < n:` loop body in `feed` (before the `if ch == '\x1b':` check), detect the alt-screen toggles and otherwise drop bytes while in alt mode:

```python
        if text.startswith('\x1b[?1049h', i):
            if not state["alt"]:
                state["alt"] = True
                if cur: flush_line()
                lc = state["lastcmd"] or "a full-screen app"
                emit("▶ operator opened: " + lc)
            i += len('\x1b[?1049h'); continue
        if text.startswith('\x1b[?1049l', i):
            if state["alt"]:
                state["alt"] = False
                emit("◀ closed")
            i += len('\x1b[?1049l'); continue
        if state["alt"]:
            i += 1; continue
```

Note: keep this block ABOVE the existing `if ch == '\x1b':` CSI/OSC handling so the toggles are caught before the generic CSI parser consumes them. The floo `end` marker still arrives after `1049l` (alt is already False), so exit codes still render.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/unit/render.sh`
Expected: PASS — collapse line present, repaint suppressed, close line present; all earlier assertions still pass.

- [ ] **Step 5: Commit**

```bash
git add floo test/unit/render.sh
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' commit -m "feat(console): collapse full-screen TUI apps to a one-liner

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Shell hook rcfile (bash) + `--emit-hook` seam

**Files:**
- Modify: `floo` (add `floo_hook_rc`; add `--emit-hook` to `main()`)
- Test: `test/unit/render.sh`

`floo_hook_rc bash` prints a bash rcfile that loads the user's normal interactive env, then installs a `DEBUG` trap + `PROMPT_COMMAND` emitting the `cmd`/`out`/`end` markers. `--emit-hook bash` prints it (test seam + the file `build_endpoint` will write in Task 7). The markers are invisible OSC, so they never appear on the operator's screen.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/render.sh`, before the summary block:

```bash
echo "=== hook rcfile: bash ==="
RC="$(mktemp)"; "$FLOO" --emit-hook bash > "$RC" 2>/dev/null
# pipe commands into an INTERACTIVE bash with our rcfile (so the prompt loop runs and
# PROMPT_COMMAND/precmd fires). The markers are invisible-OSC; capture with cat -v and grep
# the escape form. Job-control warnings on a piped interactive shell go to stderr (dropped).
raw="$(printf 'true\necho RANIT\nexit\n' | bash --rcfile "$RC" -i 2>/dev/null | cat -v)"
grep -q '1337;floo;cmd;' <<<"$raw" && ok "bash hook emits a cmd marker" || bad "no cmd marker: [$raw]"
grep -q '1337;floo;end;' <<<"$raw" && ok "bash hook emits an end marker" || bad "no end marker: [$raw]"
grep -q RANIT <<<"$raw" && ok "command still runs under the hook" || bad "command did not run: [$raw]"
rm -f "$RC"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/unit/render.sh`
Expected: FAIL — `--emit-hook` is unknown, `$RC` is empty, bash runs with an empty rcfile and emits no markers.

- [ ] **Step 3: Implement `floo_hook_rc` + `--emit-hook`**

In `floo`, add near the renderer (above `clean_recordings`):

```bash
# ─── Shell hooks: make the operator's shell announce each command via invisible private-OSC. ──
# Single source of truth for both build_endpoint (writes these into the session dir) and
# --emit-hook (test seam). The markers are non-rendering OSC, so the operator sees nothing.
floo_hook_rc() {
  case "$1" in
    bash) cat <<'RC'
# floo command-boundary hook (bash). Load the user's normal interactive env first.
[ -r /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
__floo_osc() { printf '\033]1337;floo;%s\007' "$1"; }
__floo_state=idle
__floo_preexec() {
  [ -n "${COMP_LINE:-}" ] && return
  [ "$__floo_state" = running ] && return
  case "$BASH_COMMAND" in __floo_*|"$PROMPT_COMMAND") return;; esac
  __floo_state=running
  __floo_osc "cmd;$(printf '%s' "$BASH_COMMAND" | base64 | tr -d '\n')"
  __floo_osc "out"
}
__floo_precmd() {
  local ec=$?
  [ "$__floo_state" = running ] && { __floo_osc "end;$ec"; __floo_state=idle; }
  return $ec
}
trap '__floo_preexec' DEBUG
PROMPT_COMMAND="__floo_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
RC
    ;;
    zsh) cat <<'RC'
# floo command-boundary hook (zsh). Load the user's normal env from their real ZDOTDIR/HOME.
[ -r "${__FLOO_REAL_ZDOTDIR:-$HOME}/.zshrc" ] && source "${__FLOO_REAL_ZDOTDIR:-$HOME}/.zshrc"
__floo_osc() { printf '\033]1337;floo;%s\007' "$1" }
__floo_ran=
__floo_preexec() { __floo_ran=1; __floo_osc "cmd;$(print -rn -- "$1" | base64 | tr -d '\n')"; __floo_osc "out" }
__floo_precmd() { local ec=$?; [[ -n $__floo_ran ]] && { __floo_osc "end;$ec"; __floo_ran= }; }
autoload -Uz add-zsh-hook
add-zsh-hook preexec __floo_preexec
add-zsh-hook precmd  __floo_precmd
RC
    ;;
    *) return 1;;
  esac
}
```

In `main()`, handle `--emit-hook` early (alongside `config`/`install` at `floo:697`, so it needs no relay/operator):

```bash
    --emit-hook) floo_hook_rc "${2:-bash}"; exit $?;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/unit/render.sh`
Expected: PASS — bash hook emits `cmd`/`end` markers and the command still runs.

- [ ] **Step 5: Commit**

```bash
git add floo test/unit/render.sh
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' commit -m "feat(console): bash command-boundary hook + --emit-hook seam

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Shell hook rcfile (zsh)

**Files:**
- Test: `test/unit/render.sh`

The zsh hook content was added in Task 4 (`floo_hook_rc zsh`). This task adds its test, skipping cleanly where zsh isn't installed (CI/minimal boxes), and proves the marker round-trips through the renderer.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/render.sh`, before the summary block:

```bash
echo "=== hook rcfile: zsh ==="
if command -v zsh >/dev/null 2>&1; then
  ZD="$(mktemp -d)"; "$FLOO" --emit-hook zsh > "$ZD/.zshrc" 2>/dev/null
  raw="$(printf 'true\necho RANIT\nexit\n' | ZDOTDIR="$ZD" __FLOO_REAL_ZDOTDIR=/nonexistent zsh -i 2>/dev/null | cat -v)"
  grep -q '1337;floo;cmd;' <<<"$raw" && ok "zsh hook emits a cmd marker" || bad "no zsh cmd marker: [$raw]"
  grep -q '1337;floo;end;' <<<"$raw" && ok "zsh hook emits an end marker" || bad "no zsh end marker: [$raw]"
  rm -rf "$ZD"
else
  ok "zsh not installed — skipping zsh hook test (degrades to heuristic at runtime)"
fi
```

- [ ] **Step 2: Run test to verify it fails (or skips)**

Run: `bash test/unit/render.sh`
Expected (zsh present): the two zsh assertions appear and PASS once `floo_hook_rc zsh` exists (it does, from Task 4), so this should already pass — if it FAILS, the zsh hook content has a bug to fix here. Expected (no zsh): a single skip PASS line.

- [ ] **Step 3: Fix the zsh hook if the test failed**

If running with zsh present surfaced a bug (e.g. `add-zsh-hook` not found on an old zsh, or the marker not emitted), adjust the `zsh)` branch of `floo_hook_rc` in `floo`. A robust fallback if `add-zsh-hook` is unavailable — append directly to the hook arrays:

```bash
# (only if add-zsh-hook proves unavailable on the target zsh)
typeset -ga preexec_functions precmd_functions
preexec_functions+=(__floo_preexec)
precmd_functions+=(__floo_precmd)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/unit/render.sh`
Expected: PASS (zsh assertions or the skip line).

- [ ] **Step 5: Commit**

```bash
git add floo test/unit/render.sh
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' commit -m "test(console): zsh command-boundary hook test (skip when absent)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Exec/bot path emits markers

**Files:**
- Modify: `floo` (the `REC` heredoc exec branch, `floo:170-187`)

The bot/exec path already writes clean `----- commands -----` / `----- output -----` blocks. Wrap that block with the same `cmd`/`out`/`end` markers so the renderer treats bot commands command-level identically to interactive ones. (Verified end-to-end in Task 9; this task is the emission edit, checked by `node --check`-equivalent `bash -n` since it lives in a heredoc that can't be unit-sourced.)

- [ ] **Step 1: Implement marker emission on the exec path**

In `floo`, inside the `REC` heredoc, find the exec branch (`floo:183-186`):

```bash
  in="$(cat)"
  { echo "----- commands the operator ran -----"; printf '%s\n' "$in"; echo "----- output -----"; } >> "$log"
  printf '%s' "$in" | { bash -c "$SSH_ORIGINAL_COMMAND"; } 2>&1 | tee -a "$log"
  exit "${PIPESTATUS[1]}"
```

Replace it with a version that emits markers into the log (the markers go to the recording, which the renderer parses; the operator's non-interactive channel is unaffected):

```bash
  in="$(cat)"
  __floo_osc() { printf '\033]1337;floo;%s\007' "$1" >> "$log"; }
  __floo_osc "cmd;$(printf '%s' "$SSH_ORIGINAL_COMMAND" | base64 | tr -d '\n')"
  { echo "----- commands the operator ran -----"; printf '%s\n' "$in"; echo "----- output -----"; } >> "$log"
  __floo_osc "out"
  printf '%s' "$in" | { bash -c "$SSH_ORIGINAL_COMMAND"; } 2>&1 | tee -a "$log"
  rc="${PIPESTATUS[1]}"
  __floo_osc "end;$rc"
  exit "$rc"
```

- [ ] **Step 2: Verify the client still parses**

Run: `bash -n floo`
Expected: no output, exit 0 (syntax OK). The `REC` heredoc is `'REC'`-quoted, so `__floo_osc` etc. are literal text written to the remote script — they are not expanded by the client.

- [ ] **Step 3: Spot-check the emitted marker shape**

Run:
```bash
log=$(mktemp); SSH_ORIGINAL_COMMAND='echo hi' bash -c '
  log="'"$log"'"; __floo_osc() { printf "\033]1337;floo;%s\007" "$1" >> "$log"; }
  __floo_osc "cmd;$(printf %s "$SSH_ORIGINAL_COMMAND" | base64 | tr -d "\n")"; __floo_osc "out"
  echo hi 2>&1 | tee -a "$log" >/dev/null; __floo_osc "end;0"'
cat -v "$log"; rm -f "$log"
```
Expected: output containing `1337;floo;cmd;ZWNobyBoaQ==`, `1337;floo;out`, `hi`, `1337;floo;end;0`.

- [ ] **Step 4: Commit**

```bash
git add floo
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' commit -m "feat(console): exec/bot path emits command markers into the recording

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Interactive path launches the hooked shell

**Files:**
- Modify: `floo` (`build_endpoint` writes the hook files; the `REC` heredoc interactive branch launches bash/zsh with them)

Make the interactive login shell load the hooks. `build_endpoint` writes `hook.bash` and `hook.zsh` into `$WORKDIR` (via `floo_hook_rc`), and the `REC` interactive branch selects the operator's shell and launches it with the hook loaded (bash `--rcfile`, zsh `ZDOTDIR`). Verified e2e in Task 9.

- [ ] **Step 1: Write the hook files in `build_endpoint`**

In `floo`, in `build_endpoint`, right after `chmod 700 "$WORKDIR/record-session"` (`floo:253`), add:

```bash
  floo_hook_rc bash > "$WORKDIR/hook.bash" 2>/dev/null || true
  mkdir -p "$WORKDIR/zdot"; floo_hook_rc zsh > "$WORKDIR/zdot/.zshrc" 2>/dev/null || true
  chmod 600 "$WORKDIR/hook.bash" "$WORKDIR/zdot/.zshrc" 2>/dev/null || true
```

- [ ] **Step 2a: Insert the shell-selection block in the `REC` interactive branch**

In the `REC` heredoc, the interactive branch currently reads (`floo:193-196`):

```bash
trap '' INT                                         # Ctrl-C interrupts the shell's command, never this wrapper
unset SSH_CONNECTION SSH_CLIENT SSH_TTY             # defeat SSH-auto-tmux in the user's shell rc
if command -v script >/dev/null 2>&1; then
  script -q -a "$log" -c "${SHELL:-/bin/bash} -l"    # keystroke-recorded where util-linux `script` exists
```

Replace those four lines with (insert the selection block, and change the `script` launch to use the chosen argv):

```bash
trap '' INT                                         # Ctrl-C interrupts the shell's command, never this wrapper
unset SSH_CONNECTION SSH_CLIENT SSH_TTY             # defeat SSH-auto-tmux in the user's shell rc
# choose how to start the shell: a hooked bash/zsh emits invisible command markers; any other
# shell starts a plain login shell (the renderer degrades to heuristic boundaries for it).
ushell="${SHELL:-/bin/bash}"; sh_base="$(basename "$ushell")"
if [ "$sh_base" = bash ] && [ -r "$DIR/hook.bash" ]; then
  set -- "$ushell" --rcfile "$DIR/hook.bash" -i
elif [ "$sh_base" = zsh ] && [ -r "$DIR/zdot/.zshrc" ]; then
  export __FLOO_REAL_ZDOTDIR="${ZDOTDIR:-$HOME}" ZDOTDIR="$DIR/zdot"
  set -- "$ushell" -i
else
  set -- "$ushell" -l
fi
if command -v script >/dev/null 2>&1; then
  script -q -a "$log" -c "$(printf '%q ' "$@")"      # keystroke-recorded where util-linux `script` exists
```

- [ ] **Step 2b: Update the no-`script` (relay.py) launch line**

Still in the `REC` heredoc, the `else` branch runs the pty relay (`floo:250`):

```bash
  python3 "$DIR/relay.py" "$log" "${SHELL:-/bin/bash}"   # stdin stays the operator's terminal
```

Change it to pass the chosen argv:

```bash
  python3 "$DIR/relay.py" "$log" "$@"   # stdin stays the operator's terminal
```

- [ ] **Step 2c: Make relay.py accept full shell argv**

Inside the `relay.py` heredoc (`floo:201-249`), two one-line edits so it execs the argv we pass instead of hardcoding `-l`:

- Change (`floo:207`) `log = open(sys.argv[1], "ab", buffering=0); shell = sys.argv[2]`
  to `log = open(sys.argv[1], "ab", buffering=0); shell_argv = sys.argv[2:]`
- Change (`floo:216`) `    os.execvp(shell, [shell, "-l"]); os._exit(127)`
  to `    os.execvp(shell_argv[0], shell_argv); os._exit(127)`

- [ ] **Step 3: Verify the client still parses**

Run: `bash -n floo`
Expected: exit 0.

- [ ] **Step 4: Verify the hooked-bash launch shape locally (no ssh)**

Run:
```bash
RC=$(mktemp); ./floo --emit-hook bash > "$RC"
script -q -a /dev/null -c "$(printf '%q ' bash --rcfile "$RC" -i -c 'true; echo OK')" 2>/dev/null | cat -v | grep -q '1337;floo;cmd;' \
  && echo PASS-hooked-script || echo FAIL-hooked-script
rm -f "$RC"
```
Expected: `PASS-hooked-script` (proves `script -c` runs the hooked interactive bash and the markers reach the log path — here stdout).

- [ ] **Step 5: Commit**

```bash
git add floo
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' commit -m "feat(console): interactive path launches the hooked bash/zsh shell

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Merged console — scroll region + pinned status line; make it the default

**Files:**
- Modify: `floo` (add `render_console`; rewrite `watch_attach` to reuse it; change `run_session` to use `render_console` as the default; teardown restores the terminal)
- Test: `test/unit/render.sh`

Add `render_console`: it sets a DECSTBM scroll region reserving the bottom row, runs `tail -F | render_stream` into the scrolling pane, and paints a status line (`waiting`/`connected`/`finished` + elapsed + the Ctrl-C affordance) on the bottom row driven by the same `active/` + `sessions.log` signals `monitor()` uses. It restores the terminal on exit and repaints on `SIGWINCH`. `run_session` calls it instead of `monitor`; `--watch` reuses it read-only.

- [ ] **Step 1: Write the failing test (structural)**

Append to `test/unit/render.sh`, before the summary block. This checks the scroll-region setup/teardown sequences are emitted by an internal `--console-frame` smoke mode that paints the frame, prints a status, and tears down (no live session needed):

```bash
echo "=== console frame: scroll region setup/teardown ==="
frame="$("$FLOO" --console-frame 2>/dev/null | cat -v)"
grep -q '1;.*r' <<<"$frame" && ok "sets a DECSTBM scroll region" || bad "no scroll region: [$frame]"
grep -q 'waiting for the technician' <<<"$frame" && ok "paints the waiting status" || bad "no status line: [$frame]"
grep -qE '\^\[\[r' <<<"$frame" && ok "restores the full scroll region on teardown" || bad "no region reset: [$frame]"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/unit/render.sh`
Expected: FAIL — `--console-frame` is unknown, `$frame` empty.

- [ ] **Step 3: Implement `render_console`, the frame smoke mode, and rewire**

In `floo`, replace the `watch_attach()` function (`floo:397-404`) and add the console. First, the shared frame helpers + `render_console`:

```bash
# ─── Terminal frame: a scrolling pane (rows 1..N-1) above a pinned status row (row N). ────────
_con_rows() { tput lines 2>/dev/null || { set -- $(stty size 2>/dev/null); echo "${1:-24}"; }; }
_con_setup() { CON_ROWS="$(_con_rows)"; printf '\033[1;%dr\033[%d;1H' $((CON_ROWS-1)) $((CON_ROWS-1)); }
_con_status() { printf '\033[s\033[%d;1H\033[2K%s\033[u' "$CON_ROWS" "$1"; }
_con_teardown() { printf '\033[r\033[%d;1H\033[2K\033[?25h\n' "$CON_ROWS"; }

# the status text for a state ('waiting'|'connected'|'finished') + elapsed seconds
_con_line() {
  case "$1" in
    waiting)   printf '%s◷ waiting for the technician to connect — Ctrl-C cancels%s' "$D" "$X";;
    connected) printf '%s● technician connected · %s · Ctrl-C cuts the connection%s' "$G" "$2" "$X";;
    finished)  printf '%s○ technician finished — Ctrl-C to close, or wait if they reconnect%s' "$D" "$X";;
  esac
}
_fmt_elapsed() { local s="$1"; printf '%dm%02ds' $((s/60)) $((s%60)); }

# The default in-window view: a live command log + a glued status line. read_only=1 for --watch.
render_console() {
  local read_only="${1:-0}" dir; dir="$WORKDIR"
  [ "$read_only" = 1 ] && { dir="$(session_dir "$NAME")"; [ -d "$dir" ] || { warn "no support session is open right now."; exit 1; }; }
  command -v python3 >/dev/null 2>&1 || { [ "$read_only" = 1 ] && { tail -n +1 -F "$dir"/recording/*.log 2>/dev/null; return; }; monitor; return; }
  trap '_con_setup' WINCH
  printf '\033[?25l'; _con_setup
  tail -n +1 -F "$dir"/recording/*.log 2>/dev/null | render_stream &
  local rpid=$!
  local start="" shown=0 idle=0 seen live now state
  seen="$( [ -f "$dir/sessions.log" ] && wc -l < "$dir/sessions.log" || echo 0 )"
  _con_status "$(_con_line waiting)"
  while kill -0 "$rpid" 2>/dev/null; do
    for m in "$dir"/active/*; do [ -e "$m" ] || continue; kill -0 "$(basename "$m")" 2>/dev/null || rm -f "$m"; done
    live="$(ls "$dir/active" 2>/dev/null | wc -l)"
    now="$( [ -f "$dir/sessions.log" ] && wc -l < "$dir/sessions.log" || echo 0 )"
    if [ "${now:-0}" -gt "${seen:-0}" ] || [ "${live:-0}" -gt 0 ]; then
      seen="$now"; idle=0; [ -z "$start" ] && start="$SECONDS"; shown=1; CONNECT_LOGGED=1
      _con_status "$(_con_line connected "$(_fmt_elapsed $((SECONDS-start)))")"
    elif [ "$shown" = 1 ]; then
      idle=$((idle+1)); [ "$idle" -ge 8 ] && { _con_status "$(_con_line finished)"; shown=0; idle=0; }
    fi
    sleep 1
  done
  _con_teardown
}

# Read-only second-window attach: the same console, no teardown of the real session.
watch_attach() {
  local dir; dir="$(session_dir "$NAME")"
  [ -d "$dir" ] || { warn "no support session is open right now."; exit 1; }
  ok "attached read-only to the $NAME support session — what the technician runs scrolls below."
  say "${D}(Ctrl-C just closes this view; it does NOT end the session.)${X}"
  NAME="$NAME" render_console 1
}
```

Add the smoke mode used by the test. In `main()`'s arg loop add `--console-frame) mode=conframe; shift;;`, and in the `case "$mode"` dispatch add:

```bash
    conframe) CON_ROWS="$(_con_rows)"; _con_setup; _con_status "$(_con_line waiting)"; _con_teardown;;
```

Finally, rewire `run_session` (`floo:588`). Replace:

```bash
  monitor & MONITOR_PID=$!
  if [ "$FLOO_PUBLIC" = 1 ]; then bind_watcher & BINDWATCH_PID=$!; fi
  # block until the tunnel or endpoint dies, or the user interrupts
  wait "$TUNNEL_PID" 2>/dev/null
```

with:

```bash
  if [ "$FLOO_PUBLIC" = 1 ]; then bind_watcher & BINDWATCH_PID=$!; fi
  render_console & MONITOR_PID=$!
  # block until the tunnel or endpoint dies, or the user interrupts
  wait "$TUNNEL_PID" 2>/dev/null
```

And in `teardown` (`floo:489`), restore the terminal first thing after `trap - …` so an interrupt mid-render leaves a clean screen — add after `trap - EXIT INT TERM HUP`:

```bash
  printf '\033[r\033[?25h' 2>/dev/null   # release any scroll region + show cursor
```

(`monitor()` is now unused by `run_session` but kept as the no-python fallback inside `render_console`; leave it in place.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/unit/render.sh`
Expected: PASS — scroll region set, waiting status painted, region reset on teardown; all earlier assertions still pass.

- [ ] **Step 5: Update the run_session hint text**

In `run_session` (`floo:585`), the line that says "open a second window and run this with --watch to see what they do" is now misleading (activity shows inline). Replace that `info …` line with:

```bash
  info "the technician's commands will appear below as they work. Ctrl-C ends the session."
```

- [ ] **Step 6: Commit**

```bash
git add floo test/unit/render.sh
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' commit -m "feat(console): merged live console (scroll region + status line) as default view

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: End-to-end loopback — markers in recording, command-log render, clean save

**Files:**
- Modify: `test/loopback.sh`

The existing loopback exercises the **exec/bot path** (`bin/floo-powder exec testbot`, §4) and confirms `MARKER_42` lands in the client recording at `$RUN/floo/testbot/recording/*.log` (`loopback.sh:140`). Build on exactly that: assert the exec command produced floo markers, that the renderer turns the raw recording into a `$ <command>` log, and — after Ctrl-C/teardown — that the **cleaned** recording in `~/.floo-last-session` is marker-free (the byte-identical-save invariant). TUI-collapse and interactive-hook emission are covered by the Task 3 / Task 4-5 unit tests (this loopback has no interactive operator shell — it uses `--no-shell` + `exec`).

Concrete variables already defined in `test/loopback.sh`: `$REPO` (repo root; client = `$REPO/floo`), `$RUN` (the client's XDG runtime dir; recordings under `$RUN/floo/testbot/recording`), `ok`/`bad` counters.

- [ ] **Step 1: Add the marker + render assertions after the recording check (after `loopback.sh:144`)**

Insert immediately after the §5 block that ends at `loopback.sh:144` (the `fi` closing "no client-side recording of the session"):

```bash
# ── 5b. the recording is command-level: floo markers present + renderable ────────────────
REC_GLOB=("$RUN"/floo/testbot/recording/*.log)
if grep -aq '1337;floo;cmd;' "${REC_GLOB[@]}" 2>/dev/null; then
  ok "recording carries floo command markers (exec path emits them)"
else
  bad "no floo command markers in the recording"
fi
rendered="$(cat "${REC_GLOB[@]}" 2>/dev/null | bash "$REPO/floo" --render 2>/dev/null)"
grep -q '^\$ echo MARKER_' <<<"$rendered" && ok "renderer turns the recording into a \$ command-log line" \
  || { bad "renderer produced no command line"; printf '%s\n' "$rendered" | head -5; }
```

- [ ] **Step 2: Add the cleaned-recording invariant assertion after teardown (after `loopback.sh:185`)**

The cleaned copy in `~/.floo-last-session/recording` is written by `teardown` (`floo:535-540`), which runs only after the client exits on Ctrl-C (§7). Insert after the cert check at `loopback.sh:185` (before the `echo` summary at `:187`):

```bash
# ── 8. the SAVED (cleaned) recording is marker-free — OSC stripped, raw forensic log intact ──
KEEP="$HOME/.floo-last-session/recording"
if ls "$KEEP"/*.log >/dev/null 2>&1; then
  grep -aq '1337;floo' "$KEEP"/*.log 2>/dev/null \
    && bad "floo markers leaked into the cleaned recording" \
    || ok "cleaned recording is marker-free (invisible OSC stripped on save)"
  grep -aq 'MARKER_42' "$KEEP"/*.log 2>/dev/null && ok "cleaned recording still contains the real output" || note "cleaned recording present but MARKER_42 not found (timing)"
else
  note "no ~/.floo-last-session recording saved (clean session path) — skipping cleaned-save check"
fi
```

Also extend the cleanup `rm -rf` line (`loopback.sh:44`) so the test doesn't leave the artifact behind — add `"$HOME/.floo-last-session"` to that `rm -rf` list.

- [ ] **Step 3: Run the loopback (both variants)**

Run: `bash test/loopback.sh && FLOO_INJECT_CHANGE=1 bash test/loopback.sh`
Expected: both PASS, including the new marker/render/cleaned-save assertions. The pre-existing assertions (pairing code in `client.log`, `unchanged`/`CHANGED` verdict, Ctrl-C revoke) must still pass — they prove the new `render_console` scroll-region/status output didn't disrupt the client's normal stdout or teardown. (Requires passwordless sudo + `bin/floo-powder ca-init`, per the `test/run-all.sh` header.)

- [ ] **Step 4: Run the whole suite**

Run: `bash test/run-all.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add test/loopback.sh
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' commit -m "test(console): e2e — markers in recording, command-log render, clean save

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 10: Degradation ladder — explicit no-python fallback

**Files:**
- Modify: `floo` (already handled in `render_console`; this task verifies + documents)
- Test: `test/unit/render.sh`

The fallback rungs were built in: non-bash/zsh shells launch a plain login shell (Task 7's `else` branch) so the renderer sees no markers and shows raw-stripped output (heuristic); no-python boxes fall back to `tail`/`monitor` (Task 8's `command -v python3` guard). This task adds a guard test so the no-python path can't silently regress.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/render.sh`, before the summary block:

```bash
echo "=== degradation: renderer is a no-op-safe filter without markers ==="
# a marker-less stream (what a non-bash/zsh shell produces) still renders as plain lines
out="$(render 'just plain output\nsecond line\n')"
grep -qx 'just plain output' <<<"$out" && grep -qx 'second line' <<<"$out" \
  && ok "marker-less stream renders as plain lines (heuristic rung)" || bad "plain fallback broken: [$out]"
```

- [ ] **Step 2: Run test to verify it passes (already implemented)**

Run: `bash test/unit/render.sh`
Expected: PASS — the renderer already passes plain text through. If it FAILS, the marker branch in Task 2 over-consumed non-marker input; fix the `re.match` guard so only `1337;floo;…` bodies are treated as markers.

- [ ] **Step 3: Confirm the no-python rung by forcing python absent**

Run:
```bash
PATH=/usr/bin bash -c 'command -v python3 >/dev/null && echo HAVE || echo NONE'
```
Expected: informational only. The code path is guarded by `command -v python3`; no assertion change needed. Document the rung in the spec is already done.

- [ ] **Step 4: Commit**

```bash
git add floo test/unit/render.sh
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' commit -m "test(console): guard the marker-less (heuristic) render rung

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 11: Release — version, changelog, README, embed check

**Files:**
- Modify: `VERSION`, `CHANGELOG.md`, `README.md`
- Verify: `scripts/embed.sh --check` (no relay change → must still pass)

- [ ] **Step 1: Bump the version (three sites)**

- `VERSION`: replace `0.4.0` with `0.5.0`.
- `floo`: the `FLOO_VERSION="0.4.0"` assignment → `0.5.0`.
- `bin/floo-powder`: the `FLOO_VERSION="0.4.0"` assignment → `0.5.0` (kept in lockstep even though powder is otherwise untouched).

Run: `grep -rn '0\.5\.0' VERSION floo bin/floo-powder`
Expected: one match per file.

- [ ] **Step 2: Verify the embedded relay did not drift**

Run: `bash scripts/embed.sh --check`
Expected: PASS (no `relay/*` change this release, so the embed is still byte-identical).

- [ ] **Step 3: Add the CHANGELOG entry**

Prepend under the top of `CHANGELOG.md` (match the existing entry format):

```markdown
## 0.5.0 — 2026-06-12

### Added
- **Merged live console (default view).** The client's single window now shows the
  operator's commands and output in real time — a scrolling command-log pane above a
  status line glued to the bottom row (waiting / connected+elapsed / finished, each
  with the Ctrl-C affordance). Single-terminal clients (e.g. Cockpit) no longer need a
  second window to see activity, and can make an informed Ctrl-C.
- Command boundaries are captured via injected bash/zsh hooks emitting invisible
  private-OSC markers; the exec/bot path emits the same markers. Full-screen TUI apps
  (vim, top, less) collapse to a one-line note rather than mirror.

### Notes
- The raw recording is byte-identical to before (markers are invisible OSC, already
  stripped on save). No relay or wire-protocol change; CA and quick (no-cert) modes are
  unaffected. Non-bash/zsh shells degrade to a heuristic line view; boxes without
  python3 fall back to the status line only.
- `floo --watch` still works as a read-only second-window attach (now reusing the
  same console).
```

- [ ] **Step 4: Update the README**

In `README.md`, in the "For the client" section, replace the line `` `floo --watch` (second terminal) shows live what they do. **Ctrl-C** ends it. `` with:

```markdown
While they're connected you see their commands and output scroll live in this same
window, with a status line pinned at the bottom; **Ctrl-C** ends it. (`floo --watch`
in a second terminal still gives the same read-only view if you prefer.)
```

Also bump the two version-pinned URLs that read `v0.4.0` to `v0.5.0` (the `floo-powder` curl line and any client one-liner), via:

Run: `grep -n 'v0\.4\.0' README.md`
Then edit each match to `v0.5.0`.

- [ ] **Step 5: Run the full suite one last time**

Run: `bash test/run-all.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add VERSION floo bin/floo-powder CHANGELOG.md README.md
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' commit -m "release: v0.5.0 — merged live console as the default client view

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

- [ ] Run `bash test/run-all.sh` → `ALL TESTS PASSED`.
- [ ] Run `bash -n floo && bash -n bin/floo-powder` → clean.
- [ ] Run `bash scripts/embed.sh --check` → PASS.
- [ ] Manual smoke (optional, on the operator box): start `floo --relay … --pin …`, connect with `floo-powder connect <code>`, run `ls` then `vim` then `:q`, confirm the client window shows `$ ls` + output, `▶ operator opened: vim`, `◀ closed`, status line ticking; Ctrl-C → clean teardown + revoke + readable recording path.
- [ ] Tag/push is a **separate explicit step** — do not push or tag without Vlad's go-ahead (floo is his public repo; direct push to `main`, no PR).
