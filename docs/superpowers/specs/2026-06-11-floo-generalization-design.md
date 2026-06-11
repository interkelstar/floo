# floo — generalize agents-support into a self-hostable remote-console tool

- **Date:** 2026-06-11
- **Status:** design approved (pending spec review)
- **Supersedes naming:** `agents-support` → `floo` (client) + `floo-powder` (operator)

## Goal

Turn the working, agents-deployed-specific `agents-support` into **`floo`** — a small, self-hostable,
spell-themed remote-console tool any operator can run for boxes they don't own. Keep the exact trust
model already built and reviewed (CA-cert auth, pairing code, pinned relay host key, recording +
state-diff, close = revoke, zero standing footprint). agents-deployed becomes the *first consumer*, not
the owner. No hosted SaaS — self-hosted relay only.

## Name & metaphor

The relay is the **Floo Network**. A client `floo`s their hearth onto the network to become reachable;
the operator throws **floo powder** to travel through the network to a box.

- **`floo`** — the client CLI (self-contained, `curl|bash`-able *and* installable).
- **`floo-powder`** — the operator CLI (connect / exec / list / close / gc / init).
- Two binaries on purpose: the client stays small and auditable ("read exactly what you run") even though
  one unified binary would be a nicer install. Trust > readability was the explicit call.

## Trust model — UNCHANGED

Identical to today's `agents-support` (see `docs/DESIGN.md`, `docs/THREAT-MODEL.md`): client dials OUT to
the relay, throwaway cert-only `sshd`, operator connects with a ≤60-min CA cert, pairing code (operator
types the code from the client's screen *without* seeing the relay's), pinned relay host key (closes
relay-MITM), recording + before/after access-surface state-diff, Ctrl-C/HUP = full revoke, nothing
installed/standing. The generalization changes *packaging and configuration*, not the security design.

## Components

### 1. `floo` — client CLI

A single self-contained script. Three usage modes, one trust model.

```
floo                         open a support session using the saved operator config
                             (if several saved, prompt which; if one, use it)
floo --relay H[:P] --operator-ca 'ssh-ed25519 …' [--relay-hostkey 'ssh-ed25519 …'] [--name N]
                             AD-HOC session with config passed inline (mode 1 / curl|bash)
floo install                 copy self into ~/.local/bin (mode 2: stop curl-ing every time)
floo config import [FILE|-]  save an operator config blob (paste or file/stdin)
floo config add NAME --relay … --operator-ca … [--relay-hostkey …]
floo config list             list saved operators
floo config remove NAME
floo --operator NAME         pick which saved operator to connect to
floo watch                   read-only live view of an in-progress session (was --watch)
floo status                  is a session open? (was --status)
floo --help | --version
```

- **Config store:** `~/.config/floo/operators/<name>.json` = `{ name, relay_host, relay_port,
  relay_hostkey, operator_ca }`. This blob is the full trust anchor a client needs; `floo-powder init`
  emits it, and the ad-hoc flags carry the same values.
- **Identity (the session name/route):** fallback chain `--name` → `$FLOO_NAME` → saved-config default →
  **identity hook** (see §4) → `hostname -s` → `id -un`. The name is only a label/route; auth is the cert
  + pairing code, never the name.
- Recording, state-diff, pairing code, `setsid` teardown, the tmux-isolation + terminal-emulator render of
  recordings — all carried over verbatim from current `support.sh`.

### 2. `floo-powder` — operator CLI

```
floo-powder init             turnkey: generate operator CA + relay key + relay HOST key; stand up the
                             relay (calls the relay installer); print BOTH (a) the ad-hoc client one-liner
                             and (b) the importable config blob to hand to clients.
floo-powder connect NAME     verify the code (typed blind), pin host key, mint ≤60-min cert, open a shell
   [--confirm CODE] [--no-shell]
floo-powder exec NAME        run stdin on the box non-interactively (bot/audit path)
floo-powder list | close NAME | gc
floo-powder --help | --version
```

- Operator state at `~/.config/floo/` (CA, relay key, relay host key, relay endpoint, `sessions/`).
- The `~/.ssh/floo.d/*.conf` include + drop-ins (was `agents-support.d`).

### 3. Relay — cross-distro + DoS-hardened

`relay/install-relay.sh` (run by `floo-powder init` or standalone), generalized:

- **Distro detection** → package install (`dnf`/`apt`/`pacman`/`apk`), `sshd` binary path, firewall
  (`firewalld`/`ufw`/`nftables` fallback), `gw` system-user creation, the SELinux `semanage` port relabel
  **guarded to SELinux-enforcing hosts** (revert on `--uninstall`), the `gw` password unlock.
- **DoS hardening** on the public `:443` `gw` endpoint: `sshd` `MaxStartups` / `PerSourceMaxStartups` /
  `LoginGraceTime` tightened, plus a `fail2ban` jail **or** an `nftables` connection-rate limit when
  `fail2ban` is absent. Guarded/optional where tooling is missing; documented residual otherwise.
- `--uninstall` still removes everything to zero leftovers (gw user, unit, helpers, SELinux label,
  firewall rule), keeping only `~/.config/floo` keys.
- Dispatcher (`floo-route`) + authkeys helper carried over; names de-`agents-support`-ed.

## agents-deployed stays a consumer

agents-deployed becomes "operator #1": its already-deployed relay + existing CA/keys, expressed as a saved
operator config. Its single special case (botname from `~/.openclaw/deployment.json`) becomes a thin,
optional **identity hook**: `floo` checks `$FLOO_IDENTITY_HOOK` (a path to a script that prints the name)
before falling back to hostname/`$USER`. agents-deployed ships that hook; **core `floo` has zero
agents-deployed code.** The deployed relay + published client one-liners keep working through the rename
via the migration step.

## Versioning & CLI conventions

- Semver in `VERSION`; `--version` on both binaries; per-subcommand `--help`; consistent exit codes;
  `floo`/`floo-powder` share a small usage/printing convention.
- README rewritten neutral (not agents-deployed-specific); `docs/DESIGN.md` + `docs/THREAT-MODEL.md`
  updated for the generic tool; a short "operator quickstart" (`floo-powder init` → share the one-liner)
  and "client quickstart" (`curl|bash` or `floo install` + `floo config import`).

## Launch — new clean-slate repo (decided)

Ship as a **new public repo `interkelstar/floo`**, not a rename — fresh branding, semver from `v0.1.0`,
and a **user-facing README written for a general audience** (not a port of agents-support's
agents-deployed-flavored docs). Clean slate is worth orphaning the (barely-public) `agents-support` pins.

1. New repo `interkelstar/floo` (MIT). README + `docs/` authored fresh for general operators/clients.
2. Carry operator keys `~/.config/agents-support` → `~/.config/floo` (operator access never lost).
3. Redeploy the relay under floo using the **same relay host key** → existing client pins stay valid.
4. agents-deployed re-points its client one-liner at `interkelstar/floo` and ships its identity hook.
5. `agents-support` repo reduced to a one-line "superseded by floo" pointer once clients are migrated; its
   old pinned one-liners keep working in the meantime (same relay + CA).

## Out of scope (explicitly deferred)

Hosted/SaaS relay, multi-protocol (k8s/db/web/RDP), central tamper-evident audit aggregation, RBAC /
approval workflows, a Windows client. These are the "adopt Teleport" line, not floo's.

## Testing

- Carry over the full existing suite (unit dispatcher + loopback clean/tamper + the recorder/monitor edge
  tests), renamed.
- Add: client config import/list/remove + `--operator` selection; `floo install`; `floo-powder init`
  end-to-end (generates config + one-liner + relay) on a throwaway; cross-distro relay install in at least
  one non-Fedora container (Debian) for the package/firewall/no-SELinux path; DoS-hardening config present.
- Keep the "test interactive/kill paths only in isolation, never with the operator box as the client"
  rule (lesson from the tmux incident).

## Suggested build sequence (for the plan)

1. Rename/restructure `agents-support` → `floo` + `floo-powder` (mechanical; keep tests green).
2. Generic identity (fallback chain + identity hook); drop deployment.json from core.
3. Client config store + `config` subcommands + `--operator` + `floo install`.
4. `floo-powder init` (turnkey) + emit one-liner/config blob.
5. Cross-distro relay install + guards.
6. DoS hardening.
7. Neutral docs + versioning + agents-deployed consumer wiring + migration.
