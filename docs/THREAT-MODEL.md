# floo — threat model

## Assets

1. The **client box** (a client's OpenClaw VPS, running as the client's non-root user).
2. The operator's **private toolbox** (patches/plugins) — pushed during an upgrade; must never reach the
   wrong box.
3. The operator **CA private key** — the single credential that grants entry to every client box.

## Adversaries & what each protection buys

| Adversary | Goal | Protection |
|---|---|---|
| Internet attacker | shell on a client box | The box only listens on `localhost`; the sole inbound path is the relay socket, and the client sshd accepts **only** an operator-CA-signed cert (`AuthenticationMethods publickey`, `UsePAM no`, no passwords). No cert → no entry. |
| Botname squatter | make the operator connect to / push the toolbox to the attacker's box | The **pairing code** the client reads out-of-band must match the relay's copy before the operator proceeds; the host key is pinned from the same registration. A squatter shows a different code → operator aborts. |
| Network / relay-in-the-middle (DNS hijack of `relay.example.com`, on-path) | read/alter a session, or impersonate the relay to feed forged metadata | The operator's SSH terminates at the **client's** sshd; the relay only splices ciphertext (`nc -U` pivot) — it cannot read or inject. The client host key is pinned. **The relay's own host key is also pinned** — embedded in `floo` (`FLOO_RELAY_HOSTKEY`) and pinned operator-side at `ca-init` — so a hijacked relay presenting a different key is **rejected**, not trusted on first contact (closing the path where a MITM'd relay forges the pairing code + client host key). |
| Malicious/abusive relay client | use the relay as a proxy or pivot | The `gw` account is confined by the sshd `Match` block to a **reverse unix-socket forward only** — `AllowTcpForwarding remote` + `PermitListen none` block `-L` and `-R`-TCP; no shell, no pty, no agent/X11/tunnel; the sole command is the dispatcher. |
| A departed technician (the operator themselves) | retain standing access after a session | Access is the live foreground process; Ctrl-C/HUP/close tears down the endpoint + tunnel (process-group kill, no orphans) and deregisters. Nothing is enabled at boot. The before/after **state-diff** surfaces any keys/units/cron the operator added. |
| Confused or anxious client | decide whether to revoke while help is happening | The default client window shows a live command log — stamped with a per-session secret nonce so the operator's command *output* cannot forge or hide a command — plus a pinned Ctrl-C status line. Disclosure, not containment (see residual #5), but it removes the old need for a second `--watch` terminal. |

## What is explicitly NOT promised

- **Prevention of change by a connected operator.** A shell can change a machine. We promise
  **disclosure**: run-as-the-client's-user (not root), full session recording, and a before/after diff of
  the access surfaces, shown on exit. This is the honest framing — not "nothing persists."
- **Defence against a compromised operator CA private key.** It is the master key; it lives only on the
  operator box, in no repository. Its public half being published changes nothing (only the private half
  can mint a cert).

## Residual risks (accepted for v1, with rationale)

1. **`curl|bash` integrity.** v1 pins to a commit hash over HTTPS. A swapped script could embed a
   different CA key. Deferred hardening: a sha256 + signature published on a second channel, with a
   download→verify→read→run bootstrap. The risk is *integrity*, not secrecy, and is bounded by HTTPS +
   commit pinning today.
2. **Relay `gw` is an internet-facing accept-any-key endpoint.** Anyone can authenticate as `gw` — but
   `gw` is powerless (reverse-unix-socket + dispatcher only), so the worst case is registering/holding a
   name socket (a squat, defeated by the pairing code) or resource use. Mitigations in place: charset
   validation on every name, lazy GC of dead sessions, connectability-gated routing. Not yet added:
   rate-limiting / fail2ban on the relay sshd — worth adding before serving many clients.
3. **SIGKILL / power loss on the client** skips the graceful teardown, leaving a `localhost`-only sshd
   until reboot. It is **not reachable** (the tunnel and its relay socket are gone, so there is no inbound
   path), and a reboot clears it. Graceful exits (Ctrl-C / close / TERM / HUP) tear down fully.
4. **Recording covers the support channel, not the universe.** Non-interactive `exec` (audits, upgrades —
   where it matters) is fully tee-recorded and marked for the live command log. **Interactive** shells run
   as a *native* login shell with the SSH markers stripped so they can never auto-attach the
   operator's/client's shared tmux (a shell rc doing `[[ -n $SSH_CONNECTION ]] && exec tmux` would
   otherwise hijack — and a teardown could kill — that session). Where util-linux `script` is present,
   the pty is recorded; otherwise the Python relay records the pty if python3 is available. If neither is
   available, the disclosure for an interactive session degrades to the `sessions.log` entry + the
   before/after state-diff. Bash/zsh hooks add exact command boundaries (the bash hook reads the full
   typed line and handles any PROMPT_COMMAND shape; with history disabled / HISTCONTROL=ignorespace it
   falls back to the first simple command rather than mislabel); other shells still produce a
   cleaned output stream. Teardown kills the sshd by its own PID file, never a process-name pattern.
5. **The live command log is integrity-checked against output forgery, but is not a sandbox.** Each
   session mints a *secret per-session marker nonce*; the injected bash/zsh hooks and the `exec` recorder
   stamp every command marker with it, and the renderer honours a marker **only** if the nonce matches.
   Command **output** — which the operator fully controls — therefore cannot forge a `$ command` line,
   cannot hide a command or its output behind a fabricated full-screen app (the renderer never suppresses
   output on a full-screen marker — it renders everything — and a forged alt-screen never blinds it to
   nonce-valid markers), and cannot smuggle raw escape sequences onto the client's screen (the
   command label is stripped of all control sequences before display). What remains: an operator with an
   *interactive* shell runs as the client's own user and can read the session's own files (the recording,
   the hook rc) to recover the nonce, or simply unset the hooks / start an unhooked shell. So the **live**
   pane is trustworthy against output-borne forgery but is **not** a containment boundary against a
   determined operator — it is a transparency aid for a cooperating-but-watched operator. The **raw
   recording** (tee'd to the client's disk, marker-rendered and cleaned on save) remains the tamper-evident
   record, and the Ctrl-C revoke + before/after state-diff are unchanged.
6. **State-diff scope** is the three access surfaces (authorized_keys across readable homes, enabled
   systemd user+system units, user + system cron). It is a disclosure of *those* surfaces, not a full
   integrity scan; a deep `homenum-revelio` audit can be operator-pushed for more.

## Hardening applied after the adversarial review (2026-06-11)

A 5-dimension adversarial review (independent finders + per-finding verification) raised 20 issues;
16 were confirmed and fixed:
- **Relay host-key pinning** (the most important) — closes a relay-MITM that would otherwise defeat the
  pairing-code defense. Both client and operator pin the relay's host key; a mismatch is rejected.
- **`socket_live` fail-safe** — the relay GC now concludes "dead" only on a *definitive* connection
  refusal; any ambiguous probe (e.g. `nc` missing/errored) is treated as live, so a probe failure can
  never delete a live session. `install-relay.sh` hard-fails if `nc` is absent.
- **State-diff completeness** — added `/etc/crontab`, `/etc/cron.monthly`, `/etc/cron.yearly`.
- **Client workdir** — `umask 077` + symlink-refusal + fatal chmod close a `/dev/shm` TOCTOU.
- **Relay metas are 0600** (pairing codes not world-readable on the relay); register refuses to clobber
  a live session; the recorder flags an incomplete stdin capture; operator drop-in vars are quoted; the
  teardown "revoked" claim is tied to the verified endpoint-down.

## Why publishing the CA public key (and shipping accept-any-key) is safe

The security of the box rests on possession of the CA **private** key, not on secrecy of anything in the
repo. Publishing the CA *public* key lets a client verify exactly whom they authorise. Accepting any key
at the relay avoids publishing *any* private key (which would alarm a reader and scan as a leak) while the
`gw` account stays powerless. In both cases: **integrity of the published material matters; secrecy buys
nothing.**
