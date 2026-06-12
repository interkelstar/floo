# Changelog
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
