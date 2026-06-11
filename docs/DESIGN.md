# floo — design & wire contract

## The one invariant

The box never listens for inbound support. `floo` makes the box **dial out** to the relay, and
that single foreground process **is** the access grant. Kill it → access is gone. Nothing is enabled at
boot, so a reboot can't reopen it. Everything else (who may enter, recording, the client's watch view,
the state-diff) layers on top of: **no live dial-out → no access.**

## Components & roles

| Component | Where it runs | Role |
|---|---|---|
| `floo` | the **client** box, as the client's user | dial out, stand up a throwaway cert-only sshd, show the pairing code, record, tear down |
| relay (`install-relay.sh` → dedicated sshd + `gw`) | the **operator** box | dumb switchboard: maps `name` → a client's live reverse socket; splices ciphertext |
| `floo-route` | relay, as `gw` (ForceCommand) | the only thing `gw` can do: register / meta / route / deregister / list |
| `floo-authkeys` | relay (AuthorizedKeysCommand) | accept any key (so no private key is published); the `Match` block makes `gw` powerless |
| `bin/floo-powder` | the **operator** box | ca-init / list / connect (verify code, pin host key, mint cert) / exec / close / gc |

## Identity

The **name** is the single natural key: the client's Unix login user, the relay socket name, the ssh
`Host` alias, and the cert principal. Keep it to a DNS-label charset (it routes a unix socket + an ssh
alias). The name is a *name/route*, never an authenticator — auth rests on the cert and the pairing code.

`floo` resolves it via a generic fallback chain: `--name` / `FLOO_NAME` → an optional
`FLOO_IDENTITY_HOOK` (a script that prints the name — how a deployment plugs in its own naming, e.g. from
a provisioning manifest) → `hostname -s` → `id -un`.

## Two independent handshakes (keep them apart)

**Operator → box** ("is this really the operator?") = an **SSH certificate**. The client's throwaway
sshd trusts only the operator **CA public key** (embedded in `floo`, `TrustedUserCAKeys`). To
connect, the operator mints a **≤60-minute cert**, principal = name, signed by the CA private key
(operator box only, in no repo). The cert principal must appear in the client's `AuthorizedPrincipalsFile`
and the login user must be the client's Unix user (`loginuser`, carried in the registration). Cert expiry
is the backstop; the live process is the real revoke.

**Both ends → relay** ("is this the real relay, not a hijack of `relay.example.com`?") = a
**pinned relay host key**. Its public half is embedded in `floo` (`FLOO_RELAY_HOSTKEY`) and pinned
operator-side by `ca-init`; `install-relay.sh` deploys the matching private half as the relay's host
key. `accept-new` still onboards a genuinely-new relay, but a *mismatch* against the pin is refused —
without this, a MITM'd relay could forge the pairing code + client host key the operator relies on.

**Box → operator** ("is this my real box, not a squatter on my name?") = a **human pairing code**.
The client prints `XXXX-XXXX` on its own screen and registers it (with its ephemeral host public key) at
the relay. `floo-powder connect` shows the operator the relay's copy; the operator confirms it matches
what the client read out-of-band **before** connecting or pushing anything. The host key from the same
registration is pinned (`UserKnownHostsFile` under `HostKeyAlias=<name>`), so a confirmed code also
authenticates the box's key. Cert proves operator→box; code+pin prove box→operator. Mutual.

## Wire contract (env-overridable; defaults in `()` )

- relay endpoint: `FLOO_RELAY_HOST` (`relay.example.com`), `FLOO_RELAY_PORT` (`443`),
  `FLOO_RELAY_USER` (`gw`), socket namespace `FLOO_RELAY_SOCK_DIR` (`/run/floo`),
  pinned relay host key `FLOO_RELAY_HOSTKEY` (embedded; env-overridable for tests).
- relay socket: `<sockdir>/<name>.sock` (the client's reverse unix-socket forward).
- relay meta: `<sockdir>/<name>.meta` (`code`, `loginuser`, `registered`, `peer`, `hostkey`).
- dispatcher commands (`$SSH_ORIGINAL_COMMAND` under the `gw` ForceCommand):
  - `register <name> <CODE> <loginuser> <hostkey...>`
  - `meta <name>` → `socket=live|absent` + the meta fields
  - `route <name>` → `exec nc -U <sockdir>/<name>.sock` (the operator pivot)
  - `deregister <name>` → remove socket + meta (client teardown)
  - `list` → live sessions (dead ones GC'd)
- operator transport: `bin/floo-powder connect` writes `~/.ssh/floo.d/<name>.conf` with a
  `ProxyCommand ssh … gw@relay route <name>`; then plain `ssh <name>` / `rsync … <name>:` work.

## Lifecycle

1. **Client** (`floo`): snapshot the access surface → write tmpfs workdir (`$XDG_RUNTIME_DIR/floo/<name>`, mode-0700) → ephemeral ed25519 host key → cert-only `sshd_config` → start sshd under `setsid` (own process group) → generate a throwaway client key, `register` at the relay, open `ssh -N -R <sockdir>/<name>.sock:127.0.0.1:<port> gw@relay` under `setsid` → print the pairing code → monitor the sshd log for connect/disconnect.
2. **Operator**: `list` → `connect <name>` (confirm the code, pin the host key, mint the cert, drop the ssh-config include) → `ssh`/`rsync`/`exec`.
3. **Teardown** (Ctrl-C / window close / any exit): `kill -- -PGID` the tunnel and sshd groups (reaps every forked child — no orphans) → best-effort `deregister` at the relay → confirm the local port is unbound → after-snapshot + diff → wipe the tmpfs workdir. The recording + any change-diff are copied to `~/.floo-last-session` first.

## Two payloads on one substrate

- **Audit (read-only):** `floo-powder exec <name> < snapshot.sh` (the `openclaw-client-audit`
  recipe). Recorded on the client; the operator gets the verdict.
- **Upgrade (mutating):** the toolbox is **pushed from the operator** after connecting
  (`rsync … <name>:`), never pulled — no repo credential ever lands on a client box. The upgrade
  replays a versioned, validated artifact (toolbox@tag + `_scripts` + `contract.sh` guards), not
  keystrokes; stop-on-drift if a guard fails.

## Notable engineering decisions (verified empirically on OpenSSH 10.2)

- **`AllowTcpForwarding no` is a master switch that ALSO disables stream-local forwarding.** To allow
  *only* the reverse unix socket while blocking TCP, the `gw` `Match` block uses
  `AllowTcpForwarding remote` + `PermitListen none` + `AllowStreamLocalForwarding remote`. (Verified:
  the unix-socket tunnel works; `-L` and `-R`-TCP are both refused.)
- **No `restrict` in the AuthorizedKeysCommand output** — `restrict` disables the stream-local *listen*
  the tunnel needs, and `port-forwarding` does not re-grant it. Confinement is the server-side `Match`
  block, which applies regardless of key options.
- **`StreamLocalBindUnlink yes` only clears a socket before the *next* bind**, not on disconnect — a
  killed tunnel leaves a *stale, unconnectable* socket file. So liveness is judged by **connectability**
  (`socket_live` probes via `nc -U`), the client **deregisters** on teardown, and the dispatcher GCs dead
  sockets lazily. (Security holds either way: a stale socket refuses connections.)
- **`AuthorizedKeysCommand` must be root-owned on a safe path** — hence it installs to `/usr/local/bin`.
- **The client runtime dir must be on a path sshd considers safe** (no world-writable ancestor) — hence
  `$XDG_RUNTIME_DIR` (= `/run/user/UID`, mode 0700), not `/dev/shm`.
- **The trap covers `INT TERM HUP`** so closing the terminal (SIGHUP) also revokes, not just Ctrl-C.
- **Relay-on-Fedora gotchas (verified live on the operator box):** (1) under systemd the relay runs
  confined as `sshd_t`, which may bind only the ssh port — binding `:443` (`http_port_t`) is refused
  until `install-relay.sh` relabels it (`semanage port -t ssh_port_t 443`), reverted on `--uninstall`;
  (2) `useradd --system` *locks* the `gw` password (`!`), and sshd refuses even a publickey login to a
  locked account, so the installer sets it `*` (not locked, no usable password); (3) Fedora's sshd warns
  `UsePAM no is not supported` but still honors cert auth for a non-locked account (proven end-to-end) —
  the warning is cosmetic. The whole relay is reboot-safe (systemd + a tmpfiles socket dir) and removes
  to zero leftovers (`--uninstall` drops the unit, helpers, `/etc/floo`, `/run/floo`,
  the `gw` user, the SELinux label, and the firewall opening; only `~/.config/floo` keys stay).

## Deliberately deferred (v1)

- `curl|bash` is pinned to a commit hash; a sha256 + signature published over a second channel, with a
  download→verify→read→run bootstrap, is a planned hardening (the residual risk is *integrity* of the
  fetched script, not secrecy).
- Full `homenum-revelio` reuse for a deep audit is operator-pushed during a session; `floo`'s
  built-in state-diff is the self-contained 3-surface (keys/units/cron) disclosure.
- Mirroring the bot's non-interactive `exec` into the client's live `--watch` pane (a `ForceCommand`
  tee) — worth it at product scale; the exec is still recorded + state-diffed today.
