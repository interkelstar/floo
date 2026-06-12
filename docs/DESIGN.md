# floo — design & wire contract

## The one invariant

The box never listens for inbound support. `floo` makes the box **dial out** to the relay, and
that single foreground process **is** the access grant. Kill it → access is gone. Nothing is enabled at
boot, so a reboot can't reopen it. Everything else (who may enter, recording, the client's watch view,
the state-diff, and the live command log) layers on top of: **no live dial-out → no access.**

## Components & roles

| Component | Where it runs | Role |
|---|---|---|
| `floo` | the **client** box, as the client's user | dial out, stand up a throwaway sshd gated by CA mode or quick mode, show the pairing code, render the live command log, record, tear down |
| relay (`install-relay.sh` → dedicated sshd + `gw`) | the **operator** box | dumb switchboard: maps a random session id → a client's live reverse socket; splices ciphertext |
| `floo-route` | relay, as `gw` (ForceCommand) | the only thing `gw` can do: register / meta / route / deregister / list |
| `floo-authkeys` | relay (AuthorizedKeysCommand) | accept any key (so no private key is published); the `Match` block makes `gw` powerless |
| `bin/floo-powder` | the **operator** box | ca-init / list / connect by code (pin host key, mint cert or bind a quick-mode key) / exec / close / gc |

## Identity

The relay route is a random 16-hex **session id**. The human-readable name is only a display label and
operator-side ssh alias; it is not an authenticator and is not trusted for uniqueness across a fleet.
Auth rests on the certificate/code proof and the pairing code.

`floo` resolves it via a generic fallback chain: `--name` / `FLOO_NAME` → an optional
`FLOO_IDENTITY_HOOK` (a script that prints the name — how a deployment plugs in its own naming, e.g. from
a provisioning manifest) → `hostname -s` → `id -un`.

## Two independent handshakes (keep them apart)

**Operator → box** ("is this really the operator?") = an **SSH certificate**. The client's throwaway
sshd trusts only the operator **CA public key** (`TrustedUserCAKeys`). To connect in CA mode, the
operator mints a **≤60-minute cert**, principal = the session id, signed by the CA private key (operator
box only, in no repo). The cert principal must appear in the client's `AuthorizedPrincipalsFile` and the
login user must be the client's Unix user (`loginuser`, carried in the registration). Cert expiry is the
backstop; the live process is the real revoke.

**Both ends → relay** ("is this the real relay, not a hijack of `relay.example.com`?") = a
**pinned relay host key**. Its public half is embedded in `floo` (`FLOO_RELAY_HOSTKEY`) and pinned
operator-side by `ca-init`; `install-relay.sh` deploys the matching private half as the relay's host
key. `accept-new` still onboards a genuinely-new relay, but a *mismatch* against the pin is refused —
without this, a MITM'd relay could forge the pairing code + client host key the operator relies on.

**Box → operator** ("is this my real box, not a squatter on my name?") = a **human pairing code**.
The client prints a code on its own screen and registers only its hash (plus its ephemeral host public
key) at the relay. `floo-powder connect <code>` resolves that code to exactly one live session; the host
key from the same registration is pinned (`UserKnownHostsFile` under `HostKeyAlias=<label>`), so a
confirmed code also authenticates the box's key. Cert or quick-mode code proof proves operator→box;
code+pin prove box→operator. Mutual.

## Wire contract (env-overridable; defaults in `()` )

- relay endpoint: `FLOO_RELAY_HOST` (`relay.example.com`), `FLOO_RELAY_PORT` (`443`),
  `FLOO_RELAY_USER` (`gw`), socket namespace `FLOO_RELAY_SOCK_DIR` (`/run/floo`),
  pinned relay host key `FLOO_RELAY_HOSTKEY` (embedded; env-overridable for tests).
- relay socket: `<sockdir>/<sid>.sock` (the client's reverse unix-socket forward).
- relay meta: `<sockdir>/<sid>.meta` (`code` hash, `loginuser`, `label`, `quick`, `registered`, `peer`, `hostkey`).
- dispatcher commands (`$SSH_ORIGINAL_COMMAND` under the `gw` ForceCommand):
  - `register <sid> <codehash> <loginuser> <label> [quick=1] <hostkey...>`
  - `resolve <codehash>` → `socket=live` + the meta fields + `sid`
  - `meta <sid>` → `socket=live|absent` + the meta fields
  - `route <sid>` → `exec nc -U <sockdir>/<sid>.sock` (the operator pivot)
  - `bindop <sid> <hmac> <operator-key...>` / `getop <sid>` for quick mode
  - `deregister <sid>` → remove socket + meta + quick binds (client teardown)
  - `list` → live/known sessions by label (dead ones GC'd)
- operator transport: `bin/floo-powder connect` writes `~/.ssh/floo.d/<name>.conf` with a
  `ProxyCommand ssh … gw@relay route <sid>`; then plain `ssh <name>` / `rsync … <name>:` work.

## Lifecycle

1. **Client** (`floo`): snapshot the access surface → write private workdir (`$XDG_RUNTIME_DIR/floo/<label>` or `$HOME/.local/state/floo/<label>`, mode-0700) → ephemeral ed25519 host key → throwaway `sshd_config` (CA-trusted certs by default, code-authorized key in quick mode) → start sshd under `setsid` (own process group) → generate a throwaway client key, `register` the random sid/codehash at the relay, open `ssh -N -R <sockdir>/<sid>.sock:127.0.0.1:<port> gw@relay` under `setsid` → print the pairing code → render the merged live console.
2. **Operator**: `connect <code>` resolves the sid, pins the client host key, mints a cert in CA mode or binds an ephemeral key in quick mode, drops the ssh-config include → `ssh`/`rsync`/`exec`.
3. **Recording + live view**: the recorder writes raw pty bytes to `recording/*.log`. Bash/zsh hooks and the exec path add invisible private OSC markers for `cmd`/`out`/`end`, each stamped with a **secret per-session nonce**; the client-side renderer honours a marker only if the nonce matches (so operator-controlled command *output* cannot forge or hide a command line), sanitizes the command label of all control sequences, and turns the stream into a clean command log above a pinned status line. Full-screen TUI apps are collapsed to "opened"/"closed" notes. The bash hook captures the full typed line from history, armed only after `PROMPT_COMMAND` runs, so a custom `PROMPT_COMMAND` cannot mislabel the command. The same renderer produces the saved recording, so live and saved views never drift.
4. **Teardown** (Ctrl-C / window close / any exit): release the terminal scroll region → `kill -- -PGID` the tunnel and sshd groups (reaps every forked child — no orphans) → best-effort `deregister` at the relay → confirm the local port is unbound → after-snapshot + diff → save a cleaned, marker-free recording and any change-diff to `~/.floo-last-session` → wipe the workdir.

## Two payloads on one substrate

- **Audit (read-only):** `floo-powder exec <name> < snapshot.sh` (the `openclaw-client-audit`
  recipe). Recorded and rendered live on the client; the operator gets the verdict.
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
- A scrollback UI with pause/search. The saved cleaned recording covers after-the-fact review; the live
  view stays deliberately simple.
