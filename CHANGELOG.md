# Changelog
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
