# Changelog
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
