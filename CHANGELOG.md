# Changelog
## 0.5.3 — 2026-06-17

- **Direct-command sessions (`ssh <handle> '<cmd>'`) showed empty `$` lines instead of the command.**
  Seen driving a stack update over floo: the live log was output with blank `$` headers. The v0.5.0
  exec marker was built from the piped stdin (`$in`) to unmask the `floo-powder exec` `bash -s`
  shuttle — but for a direct `ssh <handle> '<command>'` (the agents-deployed update flow) nothing is
  piped, so `$in` is empty and every command rendered as a bare `$`. Fix: the marker now uses
  `SSH_ORIGINAL_COMMAND` for a direct command and falls back to `$in` only for the `bash -s` shuttle.
  New recorder unit asserts the marker = the real command for BOTH styles (the loopback only ever
  exercised `floo-powder exec`).

## 0.5.2 — 2026-06-16

- **Quick (no-cert) connect hung** before opening the shell. The quick-mode liveness probe
  (`floo-powder connect` waits for the client to authorize its code-bound key) ran
  `ssh "$handle" true`, which forwarded the operator's terminal stdin; the client's recorder
  reads stdin to EOF before running a command, so an open terminal blocked the recorder — and
  the probe, and the whole connect — forever. (The quick loopback masked it by running connect
  with a closed stdin.) Fix: the probe is now `ssh -n … floo-probe`, a liveness token the
  client's recorder special-cases (exit silently, record nothing, never read stdin, no
  "connected" flicker). Loopback now drives connect with an **open** stdin as a regression guard.

## 0.5.1 — 2026-06-16

Fixes from first real-world use of the v0.5.0 console:

- **Live console showed no commands.** The pane tailed `recording/*.log` — a glob expanded when the
  session opens, before any recording file exists, so `tail -F` followed a literal that never appeared
  (status still flipped to "connected", but nothing scrolled). The recorder now writes a **fixed-name**
  `session.raw` that `tail -F` follows reliably; added a unit test that drives the live tail of a
  later-created stream (the gap that let this ship).
- **Each command appeared ~3×** in the readable log (raw shell prompt + typed-command echo *and* the
  `$ cmd` marker). The hook now emits a `prompt` marker and the renderer drops the inter-command
  prompt/echo region, so each command shows once as `$ <cmd>`. Marker-less (non-hooked) sessions still
  render in full; the raw `session.raw` still keeps every byte.
- **"technician finished" flapped** during a multi-step bot operation (each `exec` is a brief separate
  connection), nudging the client to close mid-update. The idle state no longer says "finished" — it
  reads "support session open · technician stepped away (still recording) — Ctrl-C only when you are
  done", and only after a longer idle so quick gaps don't trigger it.
- **Recording artifact naming flipped** to match intuition: **`session.log` is the readable command-log**
  (what you open), **`session.raw` is the complete raw record** (was `.log`/`.txt`).

## 0.5.0 — 2026-06-13

### Added
- **Merged live console (default view).** The client's single window now shows the
  operator's commands and output in real time — a scrolling command-log pane above a
  status line glued to the bottom row (waiting / connected+elapsed / finished, each
  with the Ctrl-C affordance). Single-terminal clients (e.g. Cockpit) no longer need a
  second window to see activity, and can make an informed Ctrl-C.
- Command boundaries are captured via injected bash/zsh hooks emitting invisible
  private-OSC markers; the `exec`/bot path emits the same markers (carrying the real
  piped script, not the `bash -s` shuttle). Full-screen TUI apps render inline (their
  collapsed screen content), never hidden — see Security.
- **Friend-to-friend over a public relay.** `floo --public --relay floo.kelstar.me
  --pin …` lets two people share recorded, revocable support with nothing to host — the
  operator connects with just the code. Self-hosting (CA mode) stays the default for
  anything ongoing.

### Security
- **Per-session marker nonce.** Every command marker is stamped with a secret
  per-session nonce; the renderer honours a marker only if the nonce matches. Operator
  command **output** can no longer forge a `$ command` line, hide a real command behind
  a forged full-screen app, or smuggle escape sequences onto the client's screen. The
  command label is fully control-sanitized; the renderer never suppresses output on a
  full-screen marker (suppression keyed on operator output could hide real output, so
  full-screen apps render inline); a forged alt-screen never blinds the parser to real
  markers. The live pane is a transparency aid for a cooperating operator, not a sandbox
  — see THREAT-MODEL residual #5.
- **bash command capture rewritten** as a distilled bash-preexec state machine: it reads
  the full typed line from history and is armed only between the end of `PROMPT_COMMAND`
  and the next command, so a custom `PROMPT_COMMAND` of ANY shape (string, **array** — the
  stock Fedora/RHEL default — or function) can no longer mislabel, duplicate, or hide the
  operator's real command, an empty Enter no longer emits a phantom command, and pipelines
  / compound commands are captured in full. With shell history disabled or
  `HISTCONTROL=ignorespace` it falls back to the first simple command rather than mislabel.
- Renderer hardened: cursor-column clamp + line wrap (no buffer balloon from a single
  cursor escape), 8-bit C1 controls stripped (not just C0/7-bit), bounded escape/OSC
  scanning (no O(n²)), no bare-ESC fragment leak, no leftover temp files.
- **The saved recording is now the complete raw byte stream** (`<stamp>.log`, the
  tamper-evident record — nothing dropped, so output a determined operator hid from the
  rendered view is still there), with a readable rendered `<stamp>.txt` written beside it.
  The rendered views (live pane + `.txt`) are terminal-faithful: like a terminal they do
  not display control-sequence bodies, so they are a transparency aid, not a containment
  boundary — see THREAT-MODEL residual #5.
- `floo --watch` is a read-only second-window attach; it reaps only its own pipeline on
  exit (scoped by child PID, so it can't disturb the client's own live pane).

### Notes
- No relay or wire-protocol change; CA and quick (no-cert) modes are unaffected. Non-bash/zsh
  shells degrade to a cleaned line view; boxes without python3 fall back to the status line.

## 0.4.0 — 2026-06-12
- **no-cert (quick) mode** — a client can open a code-only session that any operator takes with just the
  code, no operator CA. `floo --public` stands up a CA-less throwaway sshd (empty authorized_keys), shows a
  high-entropy base32 code, then polls the relay for the operator's ephemeral-key bind and authorizes the
  first whose `HMAC(code, opkey)` verifies. The code IS the credential against an untrusted relay → it's
  long (~65 bits). Strictly weaker than CA mode (a leaked code = access) and opt-in on every side.
- **operator auto-detects the mode**: `floo-powder connect <code>` resolves the session, reads its `quick`
  flag, and either mints a CA cert (CA mode) or binds an ephemeral key by code-proof (no-cert) — no new flag.
- **relay**: new `bindop`/`getop` verbs (store-all binds; the client filters by HMAC, so a junk bind can't
  squat a session); `register` carries an optional `quick=1`; opt-in via `install-relay.sh --allow-quick`
  (writes `/etc/floo/allow_quick`; default stays CA-only). New caps under allow-quick: max concurrent quick
  sessions (`FLOO_QUICK_MAX=20`) + a quick TTL (`FLOO_QUICK_TTL=1800s`). Per-IP throttling is the existing
  sshd `PerSourceMaxStartups`/`MaxAuthTries` + fail2ban (each register/bindop is a fresh gw handshake).
- The same relay serves both modes; routing (sid-keyed) is shared, only the auth binding differs.

## 0.3.2 — 2026-06-12
- `floo-powder relay-install`: stand up / refresh the relay daemon from the operator keys already in
  `~/.config/floo` (CA + relay host key), reusing the host key so the pin is unchanged. Idempotent;
  does NOT rewrite `relay.env` (unlike `init`). This is the clean primitive for a bootstrap/restore
  that already has the keys — e.g. the agents-deployed operator-setup install script, or a
  folder-free restore (`curl …/floo-powder -o … && floo-powder relay-install`). `init` now uses it.
- help (`-h`) no longer leaks non-comment lines past the header.

## 0.3.1 — 2026-06-12
- the embedded relay is now **readable**: floo-powder carries floo-route/floo-authkeys/install-relay.sh
  as verbatim bash (quoted heredocs), not base64. "Don't trust us — read us" now holds for the operator
  file too — `less floo-powder` shows exactly what `init` writes out and sudo-runs (it runs as root).
  (v0.3.0 embedded the same code as opaque base64, which defeated readability.) Smaller file, too.
- `test/unit/embed.sh` gains a guard that fails if the embed ever regresses to a base64 blob.

## 0.3.0 — 2026-06-12
- self-contained operator: `floo-powder` is now a single file with the relay (`floo-route`,
  `floo-authkeys`, `install-relay.sh`) embedded — no git clone needed. Operator onboarding is
  symmetric with the client: `curl …/bin/floo-powder -o floo-powder && sh floo-powder install && floo-powder init`
  (or `curl … | bash -s -- init`). `init` materializes the embedded relay when run standalone, or uses
  the live `relay/` files from a checkout.
- `floo-powder install` self-fetches the pinned tag when run piped (no on-disk file to symlink).
- `floo-powder relay-extract <dir>` writes the embedded relay scripts out (transparency / inspection).
- build: `scripts/embed.sh` regenerates the embedded payload from `relay/` (base64, drift-checked);
  `test/unit/embed.sh` (`embed.sh --check`) fails the suite if a `relay/` file is edited without re-embedding.

## 0.2.0 — 2026-06-12 (breaking: relay protocol)
- connect by CODE, not name: `floo-powder connect <code>`. Sessions key on a random non-secret sid;
  the operator resolves the code → sid → certs against it. No more name collisions across a fleet.
- the name survives only as an optional display **label** (agents-deployed keeps `ssh vital`).
- `floo-powder --relay <host> --pin <fp>`: point the operator at a relay you may not own, symmetric
  with the client — enables relay-on-a-separate-box and the two-friends topology.
- relay: `resolve` replaces `verify`; register/route/meta/deregister key on the sid; list shows the label.

## 0.1.1 — 2026-06-12
- recorder: set XDG_RUNTIME_DIR so `systemctl --user`/`journalctl --user` work over `exec`
- recorder: pass rsync/scp through a clean binary channel (was deadlocking + corrupting the protocol); the transfer is recorded as the command, not the byte stream


## 0.1.0 — 2026-06-11
First public release. Self-hostable, client-initiated, recorded, instantly-revocable remote console.

- `floo` (client): ad-hoc `curl|bash --relay/--operator-ca`, or `floo install` + `floo config import`
  for repeat support (multiple saved operators, `--operator` to pick). `--watch`, `--status`,
  `--version`, generic host identity (`--name`/`FLOO_NAME`/`FLOO_IDENTITY_HOOK`/hostname/user).
- `floo-powder` (operator): `init` (turnkey keys + relay + shareable one-liner/config blob),
  `connect` (blind pairing-code gate, ≤60-min cert), `exec`, `list`, `close`, `gc`.
- Relay: dedicated isolated `sshd` for a powerless `gw` account; cross-distro installer
  (dnf/apt/pacman/apk · firewalld/ufw/nft · SELinux guarded); DoS hardening (sshd MaxStartups/
  PerSource limits + optional fail2ban jail); `--uninstall` leaves zero leftovers.
- Trust model: CA-cert auth, pinned relay host key (anti-MITM), session recording (terminal-emulated,
  readable), before/after access-surface state-diff, Ctrl-C = full revoke, zero standing footprint.
