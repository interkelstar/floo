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
| Confused or anxious client | decide whether to revoke while help is happening | The default client window shows a live command log — stamped with a per-session secret nonce so the operator's command *output* cannot forge or hide a command — plus a pinned Ctrl-C status line, right in the same window they ran `floo` in. Disclosure, not containment (see residual #5). |

## What is explicitly NOT promised

- **Prevention of change by a connected operator.** A shell can change a machine. We promise
  **disclosure**: run-as-the-client's-user (not root), full session recording, and a before/after diff of
  the access surfaces, shown on exit. This is the honest framing — not "nothing persists."
- **Defence against a compromised operator CA private key.** It is the master key; it lives only on the
  operator box, in no repository. Its public half being published changes nothing (only the private half
  can mint a cert).

## Residual risks (accepted for v1, with rationale)

1. **`curl|bash` integrity.** The published install one-liners pin a **release tag** (e.g. `v0.7.1`)
   over HTTPS, and a repository ruleset makes `v*` tags **immutable** — it blocks force-move, update, and
   deletion — so a published tag cannot be silently repointed to different code. For strict cryptographic
   immutability you can instead pin a full **commit hash** (the operator one-liner honours
   `FLOO_PIN_COMMIT`). A swapped script could still embed a different CA key, so the residual is
   *integrity*, not secrecy — bounded by HTTPS + the immutable tag (or a pinned commit) today. Deferred
   hardening: a sha256 + signature published on a second channel, with a download→verify→read→run bootstrap.
2. **Relay `gw` is an internet-facing accept-any-key endpoint.** Anyone can authenticate as `gw` — but
   `gw` is powerless (reverse-unix-socket + dispatcher only), so the worst case is registering/holding a
   name socket (a squat, defeated by the pairing code) or resource use. Mitigations in place: charset
   validation on every name, lazy GC of dead sessions, connectability-gated routing. Not yet added:
   rate-limiting / fail2ban on the relay sshd — worth adding before serving many clients.
   **What you trust a relay operator for (esp. a PUBLIC relay you don't run).** The session SSH is
   end-to-end between the operator and the *client's own* sshd; the relay's pivot is an `nc -U` splice of
   ciphertext, so a relay operator **cannot read a session that connects normally** (it holds none of the
   ephemeral keys). The cleartext code never reaches the relay — only its SHA-256 hash (and, in quick mode,
   `HMAC(code, opkey)`), both one-way over a ~65-bit code. A malicious relay **cannot transparently MITM**:
   to relay onward to the real client it would have to authenticate *as the operator*, and it can't — in CA
   mode the operator proves possession of its ephemeral **private** key in the SSH key exchange, and the
   relay (splicing only ciphertext) can neither extract that private key nor reuse the cert without it, so
   it cannot complete a second publickey authentication to the real client; in quick mode the relay only
   ever holds the operator's *public* ephemeral key (and can't forge a valid `HMAC(code, ·)` for its own
   key without the code). The genuine residual: the relay is the **only source
   of the client's host key** (the operator pins whatever `resolve` returns — there's no out-of-band channel
   for it; only the *code* is read person-to-person). So a malicious relay can **impersonate the client** —
   redirect the operator's pivot to a relay-controlled sshd presenting a substituted host key — and capture
   what the **operator types**. But because it can't forward onward, this is an **incomplete, detectable
   eavesdrop**: the *real* client never shows "● technician connected" and records nothing, and the operator
   reaches a dead end. So a relay operator's actual powers are **denial of service**, **metadata** (IPs,
   timing, labels, session ids, the code *hash*), and at worst a *detectable* one-sided eavesdrop — never
   silent reading of a working session. For confidentiality against the relay host itself, self-host the
   relay (then you are the relay operator). Quick mode adds no CA second factor, so treat the **code as a
   credential**: an out-of-band code leak is full access until the window closes.
3. **SIGKILL / power loss on the client** skips the graceful teardown, leaving a `localhost`-only sshd
   until reboot. It is **not reachable** (the tunnel and its relay socket are gone, so there is no inbound
   path), and a reboot clears it. Graceful exits (Ctrl-C / close / TERM / HUP) tear down fully.
4. **Recording covers the support channel, not the universe.** Non-interactive `exec` (audits, upgrades —
   where it matters) is fully tee-recorded and marked for the live command log. The one thing not byte-
   recorded is a **genuine binary file transfer** (`scp`/`rsync --server`/`sftp-server`): its bidirectional
   binary protocol can't be tee'd without deadlocking, so it is recorded as the command line only (the
   *fact* of the transfer, disclosed to the live console through the nonce marker channel). That fast path
   is taken **only** for a genuine transfer invocation — a command that also chains or substitutes (`;` `&`
   `|` `` ` `` `$` `<` `>` newline), **or** that carries a command-executing option of the transfer binary
   itself (`scp -S`/`-o`, `rsync --rsh`/`--rsync-path`/`-e <prog>`), is NOT treated as a transfer and is
   fully teed — so an operator cannot run arbitrary unrecorded commands behind a transfer-looking prefix.
   (The benign capability token a real `rsync --server` sends, `-e.iLsfxC`, is distinguished from a
   program-bearing `-e` and still fast-paths.) Even for a genuine transfer the command **line** is recorded
   in full; only the binary byte stream is not. **Interactive** shells run
   as a *native* login shell with the SSH markers stripped so they can never auto-attach the
   operator's/client's shared tmux (a shell rc doing `[[ -n $SSH_CONNECTION ]] && exec tmux` would
   otherwise hijack — and a teardown could kill — that session). Where util-linux `script` is present,
   the pty is recorded; otherwise the Python relay records the pty if python3 is available. If neither is
   available, the disclosure for an interactive session degrades to the `sessions.log` entry + the
   before/after state-diff. Bash/zsh hooks add exact command boundaries (the bash hook reads the full
   typed line and handles any PROMPT_COMMAND shape; with history disabled / HISTCONTROL=ignorespace it
   falls back to the first simple command rather than mislabel; a bare function-definition line gets no
   `$`-label since bash fires no hook for it, but is still visible in the recorded keystrokes and cannot
   hide or mislabel a later command); other shells still produce a cleaned output stream. Teardown kills
   the sshd by its own PID file, never a process-name pattern.
5. **The live command log is integrity-checked against output forgery, but the rendered view is not a
   sandbox — the raw recording is the tamper-evident record.** Each session mints a *secret per-session
   marker nonce*; the bash/zsh hooks and the `exec` recorder stamp every command marker with it, and the
   renderer honours a marker **only** if the nonce matches. Command **output** — which the operator fully
   controls — therefore cannot forge a `$ command` line, and cannot smuggle raw escape sequences onto the
   client's screen (the command label and all output are stripped of control sequences, C0 and 8-bit C1,
   and the cursor column is clamped so no escape can balloon the buffer). The rendered views — the live
   pane and the saved readable `session.log` — render the session the way a **terminal** would: a terminal
   does not display control-sequence bodies (e.g. an OSC string), and neither do we, so a *determined*
   operator can obscure the **rendered** view (wrap output in a control sequence, unset the hooks, run an
   unhooked shell, or read the session's own files to recover the nonce). That is expected: the rendered
   view is a transparency aid for a cooperating-but-watched operator, **not** a containment boundary. The
   guarantee that survives a hostile operator is the **raw recording**: `~/.floo-last-session/recording/
   session.raw` is the exact tee'd byte stream with **nothing dropped** — every command and every byte of
   output, including anything hidden from the rendered view — so it is the after-the-fact tamper-evident
   record. (The `session.log` beside it is the readable render.) The Ctrl-C revoke + before/after state-diff are
   unchanged.
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
