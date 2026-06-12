# floo merged live console — design

> Status: approved 2026-06-12. Target release: v0.5.0.

## Goal

Collapse floo's two-window split — the in-window `monitor()` status line plus the
separate `floo --watch` log attach — into **one default view**: a scrolling
command-log pane with a status line glued to the bottom of the client's single
terminal. A single-terminal client (e.g. Cockpit's web console) sees the operator
act in real time, command-by-command, and can make an *informed* Ctrl-C.

This is the live arm of floo's "disclosure, not prevention" promise: the client no
longer has to trust an after-the-fact recording — they watch it happen.

## Motivation

Today the client must open a *second* terminal and run `floo --watch` to see what
the technician does. Cockpit (and many minimal client environments) have exactly
one terminal, so in practice the client sees only `● a technician is connected`
and no activity. TeamViewer's whole reassurance is "I can see my screen while
you work." floo should offer the terminal equivalent in the one window it owns.

## Decisions locked in brainstorming

1. **Fidelity model: command log, not a live terminal mirror.** Show commands and
   their text output as clean scrolling lines. Full-screen TUI apps (vim, top,
   less) are *collapsed* to a one-line note, never mirrored. This is what makes a
   pinned status line possible at all (a raw mirror's absolute cursor moves and
   alt-screen switches would walk over a reserved bottom row).
2. **Capture method: injected shell hooks** emitting **invisible OSC markers**,
   with a **heuristic prompt/alt-screen parse** as the fallback for shells we don't
   have a hook recipe for.
3. **The merged console becomes the default** main-window view. `--watch` is kept
   as an explicit second-window read-only attach (now redundant for the common
   case but still valid for a separately-SSH'd client) and reuses the same renderer.
4. **Full-screen apps collapse to a one-liner**, never mirrored.

## Architecture

Four pieces, in dependency order.

### A. Marker grammar (the keystone)

The injected hooks must not `echo` plain text: the interactive recorder
(`script` / `relay.py`) mirrors the operator's pty to *both* their screen and the
log, so a plain marker line would be visible to the operator. Instead, markers are
emitted as **OSC control sequences**, which terminals do not render — invisible to
the operator, present in the byte stream for our parser. (This reuses the *invisible
OSC* mechanism that OSC 133 shell-integration is built on; we define our own private
sub-payload under a dedicated `floo` identifier rather than overload the standard
OSC 133 codes, so there is no ambiguity with a terminal that already speaks 133.)
Consequence: **no separate event file** — the markers ride invisibly
inside the existing raw recording.

The grammar (one uniform set across both the interactive and the exec/bot path):

All three are `ESC ] 1337 ; floo ; <kind> [; <arg>] BEL` (private OSC; `ESC` =
`\033`, `BEL` = `\007`):

| `<kind>` | `<arg>` | Meaning |
|---|---|---|
| `cmd` | `<b64-cmd>` | a command is about to run; arg = the command line, base64 (keeps newlines, `;`, and control bytes inside a command from breaking the marker) |
| `out` | — | the command's output begins (everything until `end` is output) |
| `end` | `<exit>` | command finished with the given exit code |

- **Interactive path:** an injected rcfile sets `bash` `DEBUG` trap +
  `PROMPT_COMMAND` (and `zsh` `preexec` + `precmd`) to emit command-start before a
  command runs and command-end after. output-start is emitted by the trap right
  after command-start.
- **Exec/bot path:** already has a clean command + output block (`floo:184`). It
  emits the same three markers around that block. No shell needed there.

### B. Renderer — `render_console()`

Runs in the client's main window (replaces `monitor()`, folds in `watch_attach()`).
It tails the recording log, parses the marker grammar, and prints clean lines into
a **DECSTBM scroll region**:

- `\033[1;<rows-1>r` reserves rows 1..rows-1 for the scrolling pane; the last row
  is the status line.
- On command-start: print `$ <command>` (decoded from base64) in the pane.
- Between output-start and command-end: print the output bytes, **stripped of OSC
  and other control sequences** so they scroll as plain lines and never escape the
  region. (Same strip logic as `clean_recordings`, applied live.)
- **Full-screen collapse:** when the output stream contains an alt-screen enter
  (`\033[?1049h`), suppress the raw app repaint and print `▶ operator opened:
  <command>`; on alt-screen exit (`\033[?1049l`) print `◀ closed`. The command that
  was running (from the most recent command-start) names the app.

`SIGWINCH` re-reads the terminal size, re-sets the scroll region, and repaints the
status line. Teardown restores the full scroll region (`\033[r`), shows the cursor,
and clears the status row.

### C. Status line

Pinned on the bottom row, repainted on every state change and on SIGWINCH. Three
states, each carrying the Ctrl-C affordance so the cut is always one keystroke away
in the client's eyeline:

- waiting: `◷ waiting for the technician to connect — Ctrl-C cancels`
- connected: `● technician connected · <elapsed> · Ctrl-C cuts the connection`
- finished: `○ technician finished — Ctrl-C to close, or wait if they reconnect`

State transitions reuse the existing signals `monitor()` already consumes: the
per-session line in `sessions.log` and the live PID markers in `active/` (written
by the recorder only after a real cert/code login, so liveness probes never trigger
a state change). `<elapsed>` ticks from the first connect.

### D. Degradation ladder

No hard new dependency; each rung is honest about what it shows:

1. **bash / zsh** → exact OSC markers (full fidelity command log).
2. **any other interactive shell** → heuristic parse: treat the shell prompt as a
   command delimiter and alt-screen toggles as TUI collapse. Approximate boundaries
   but functional.
3. **no `script` and no `python3`** → today's behavior: status line only, no
   command log (the recorder itself already can't run in this case).

## Data flow

```
operator's login shell
  │  (injected hooks emit OSC markers; output interleaved)
  ▼
ssh pty  ──►  record-session (script / relay.py)
                 │  tees raw bytes (markers invisible to operator) to recording/<stamp>.log
                 ▼
            reverse tunnel (unchanged) ── relay (dumb pivot, unchanged)
                 ▼
client's main window: render_console()
  │  tail -F recording/*.log → parse markers → strip control seq
  ▼
scroll-region pane (commands + output + TUI collapse)  +  pinned status line
  │
  ▼
client reads activity, presses Ctrl-C to revoke (unchanged teardown)
```

## Invariants preserved (must not regress)

- **Raw recording is byte-identical to today.** Markers are invisible OSC bytes
  inside the stream; `clean_recordings()` (`floo:414`) already strips OSC, so the
  saved `~/.floo-last-session` cleaned log is exactly what it is now.
- **No new network surface.** All rendering is local to the client box. The relay,
  the reverse tunnel, CA mode, and quick (no-cert) mode are untouched and behave
  identically.
- **Security model unchanged.** This is a *readability layer over the same raw
  bytes* for a cooperating-but-watched operator — not a containment control. A
  hostile operator could `unset` the hooks in a subshell; the renderer then degrades
  to heuristic/raw for that span while the **raw recording still captures every
  byte**. The cert/code gate, full recording, state-diff, and Ctrl-C revoke are
  exactly as before.
- **Operator sees nothing new.** Markers are non-rendering OSC; the operator's
  terminal is unchanged.
- **`register` wire protocol unchanged.** This feature is entirely client-local;
  it adds no relay command and no new register field, so deployed v0.2.0+ clients
  and the live relay are unaffected.

## Footprint

All changes are in the single `floo` client file, including its embedded `REC`
heredoc. No new files, no new runtime dependencies beyond what the recorder already
uses (`script` or `python3`, plus `base64` which is coreutils-standard). The
embedded relay in `bin/floo-powder` is **not touched** (no relay change), so
`scripts/embed.sh` is unaffected.

## Testing

Unit (drive the pieces directly, no sshd):

- Marker emission, exec/bot path: a piped command block produces command-start /
  output-start / command-end with the right base64 command and exit code.
- Marker emission, interactive path: a scripted bash session and a scripted zsh
  session each emit a well-formed marker per command.
- Parser: a recorded stream with markers renders to the expected `$ cmd` + output
  lines; OSC and color sequences are stripped from output.
- TUI collapse: a stream containing `\033[?1049h … \033[?1049l` renders
  `▶ operator opened: <cmd>` / `◀ closed` and suppresses the raw repaint.
- Heuristic fallback: a marker-less stream with a known prompt is split into
  plausible command/output lines.
- Status line: scroll-region set/teardown emits the right DECSTBM sequences;
  SIGWINCH repaints; teardown restores `\033[r` and the cursor.
- Invariant: `clean_recordings` output on a marker-bearing recording is identical
  to the same recording with markers removed (proves markers are stripped, raw
  forensic log unaffected).

Loopback (full single-host e2e, extends the existing recorded-session loopback):

- Default run (no `--watch`): operator connects, runs a few commands; the client's
  main window shows the command log + status line; Ctrl-C revokes.
- The same for an exec/bot operator (commands appear command-level).
- A full-screen app run by the operator collapses to the one-liner, status line
  intact.

## Out of scope (YAGNI)

- True terminal mirroring of TUI apps (explicitly rejected; collapse instead).
- Scrollback search / pause in the live view (the saved cleaned recording covers
  after-the-fact review).
- Any relay-side or wire-protocol change.
