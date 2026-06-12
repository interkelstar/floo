# Changelog
## 0.5.0 — 2026-06-13

### Added
- **Merged live console (default view).** The client's single window now shows the
  operator's commands and output in real time — a scrolling command-log pane above a
  status line glued to the bottom row (waiting / connected+elapsed / finished, each
  with the Ctrl-C affordance). Single-terminal clients (e.g. Cockpit) no longer need a
  second window to see activity, and can make an informed Ctrl-C.
- Command boundaries are captured via injected bash/zsh hooks emitting invisible
  private-OSC markers; the `exec`/bot path emits the same markers (carrying the real
  piped script, not the `bash -s` shuttle). Full-screen TUI apps collapse to a one-line
  note rather than mirror.
- **Friend-to-friend over a public relay.** `floo --public --relay floo.kelstar.me
  --pin …` lets two people share recorded, revocable support with nothing to host — the
  operator connects with just the code. Self-hosting (CA mode) stays the default for
  anything ongoing.

### Security
- **Per-session marker nonce.** Every command marker is stamped with a secret
  per-session nonce; the renderer honours a marker only if the nonce matches. Operator
  command **output** can no longer forge a `$ command` line, hide a real command behind
  a forged full-screen app, or smuggle escape sequences onto the client's screen (the
  command label is fully control-sanitized; a forged alt-screen never blinds the parser
  to real markers). The live pane is a transparency aid for a cooperating operator, not
  a sandbox — see THREAT-MODEL residual #5.
- **bash command capture rewritten** to read the full typed line from history, armed
  only after `PROMPT_COMMAND` completes — so a user's custom `PROMPT_COMMAND` (the stock
  Fedora/RHEL default) can no longer mislabel or hide the operator's real command, and
  pipelines / compound commands are captured in full.
- Renderer hardened: bounded escape/OSC scanning (no O(n²) on malformed input), no
  stray-fragment leak on a bare ESC inside an OSC, and no leftover temp files.

### Notes
- No relay or wire-protocol change; CA and quick (no-cert) modes are unaffected. The
  saved recording is the rendered command-log (markers become `$ command` lines, raw
  escapes stripped) via the same renderer the live pane uses. Non-bash/zsh shells
  degrade to a cleaned line view; boxes without python3 fall back to the status line.
- `floo --watch` still works as a read-only second-window attach, now reusing the
  same console.

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
