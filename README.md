# floo

**Temporary, recorded, instantly-revocable remote console access** — TeamViewer's convenience with a
bastion's security posture, for the terminal. You hand it to someone whose box you *don't* own.

A client types one command **only when they want help**. Their machine dials **out** to a relay you run
and stands up a throwaway SSH endpoint that **only you** can enter. While it's open they see a pairing
code and `● a technician is connected`; the whole session is **recorded to their own disk**. When they
press **Ctrl-C** it's over — the endpoint dies, the keys are wiped, and they're shown whether anything on
their box changed. Nothing is installed, nothing runs as root, nothing survives a reboot.

> Spell-themed: the relay is the *Floo Network*; a client `floo`s their hearth onto it, and the operator
> throws *floo powder* (`floo-powder`) to travel through to a box.

## Why not just `ssh`, ngrok, or Teleport?

- vs. **open a port + add a key**: that's standing inbound attack surface that survives reboots. `floo`
  has **zero standing footprint** — the live foreground process *is* the grant; closing it is the revoke.
- vs. **ngrok / tmate**: those share a terminal or tunnel ad-hoc; `floo` is cert-gated, recorded, and
  bracketed by an access-surface diff, designed for *supporting someone else's box*.
- vs. **Teleport / Boundary**: those are excellent fleet-access *platforms* you run a cluster for and
  enroll every node into. `floo` installs nothing on the client and assumes you **don't** own the fleet.
  If you reach dozens of clients or need compliance/RBAC, graduate to Teleport — that's the honest line.

## For the client

Only when you want help. Whoever's helping you hands you a one-line command — paste it, and read them
the pairing code it prints:

```sh
curl -fsSL https://raw.githubusercontent.com/interkelstar/floo/v0.1.0/floo \
  | bash -s -- --relay relay.example.com --pin 0123456789abcdef
```

The `--pin` is a short fingerprint of the operator's relay. `floo` verifies the relay against it, then
fetches the operator's key *from* the relay — so there are no long keys to paste (and nothing for a
terminal to fold and corrupt). The URL is a version tag, so you run exactly the code you can read at
`github.com/interkelstar/floo/tree/v0.1.0`.

…or, if you'll get support more than once, **install it and save your operator once**:

```sh
curl -fsSL https://…/floo -o floo && less floo && sh floo install   # read it, then install to ~/.local/bin
floo config import < operator-config.json                            # save your operator (relay + key)
floo                                                                 # any time you need help, just: floo
```

Read the pairing code back to whoever is helping you — they must repeat it before they can connect.
`floo --watch` (second terminal) shows live what they do. **Ctrl-C** ends it.

### Don't trust us — read us

`floo` is one readable Bash file.
- It **never** runs as root or asks for a password.
- Exactly **one** key can enter: the operator's published CA (you supply it as a flag or save it once —
  in plain sight). Only the matching private key, which lives only on the operator's machine, can mint a
  login. Per session, the operator's certificate is good for **≤60 minutes**.
- Access lasts only while the process is alive. Ctrl-C / closing the window revokes it.
- The session is **recorded** to your disk, and every change to your SSH keys, enabled services, or
  scheduled jobs is shown to you on exit (`~/.floo-last-session/`).

The honest promise is **disclosure, not prevention**: a shell can change a machine; what `floo` guarantees
is that it runs as *your* user, is recorded, and any change to your access surfaces is surfaced to you.

## For the operator

`floo-powder` is **one self-contained file** — the relay (`floo-route` + its installer) is embedded, so
there's nothing else to clone. Fetch it, read it, install it, and stand up your relay:

```sh
curl -fsSL https://raw.githubusercontent.com/interkelstar/floo/v0.3.0/bin/floo-powder -o floo-powder
less floo-powder                     # read exactly what you're about to run
sh floo-powder install               # install into ~/.local/bin (self-fetches if piped)
floo-powder init                     # turnkey: keys + stands up the embedded relay + prints the client one-liner
```

(One-shot, no install: `curl -fsSL https://…/bin/floo-powder | bash -s -- init`.)

```sh
floo-powder invite                   # reprint the one-liner to hand to whoever you're helping
floo-powder connect <code>           # the CODE the client reads you — resolves the session, you're in
floo-powder exec <handle> < audit.sh # run a script non-interactively (recorded on the client)
floo-powder close <handle>           # drop operator-side routing
floo-powder list                     # open sessions (label + id) — situational; you connect by code

# point at a relay you don't own (relay on a separate box, a friend's relay):
floo-powder --relay vps.example.com --pin <fp> connect <code>
```

`floo-powder init` prints the exact one-liner (and an importable config blob) to hand to clients. The
relay is a dedicated, isolated `sshd` serving a single powerless `gw` account; it splices ciphertext and
never sees your session. Cross-distro (Fedora/Debian/Ubuntu/Arch/Alpine); `--uninstall` leaves **zero**
leftovers (only your `~/.config/floo` keys stay — back those up, they *are* your access).

> **Developing floo?** `git clone … && cd floo && bin/floo-powder install` works too — `init` then uses
> the live `relay/` files instead of the embedded copy. After editing anything under `relay/`, run
> `scripts/embed.sh` to re-embed it into `bin/floo-powder` (the test suite's `embed.sh --check` fails on drift).

## How it works

`floo` (client) dials out to your relay and opens a cert-only throwaway `sshd`, registering under a random
session id with a one-time **code** it shows the client. `floo-powder connect <code>` resolves that code to
the session — so you reach the *genuine* client by construction (a squatter registered a different code, so
your code never resolves to them), with no name to collide across a fleet. It pins the relay + client host
keys, mints a ≤60-min cert (bound to that session id), and connects end-to-end *through* the relay.
Recording + before/after state-diff; Ctrl-C/close = full teardown.

Design & threat model: [`docs/DESIGN.md`](docs/DESIGN.md), [`docs/THREAT-MODEL.md`](docs/THREAT-MODEL.md).
Tests: `bash test/run-all.sh` (unit + a full single-host loopback proving cert-only entry, the
pairing-code gate, real Ctrl-C revoke, and the state-diff).

MIT licensed. The whole access mechanism is open on purpose — a client can read exactly what they grant.

---

Built and run in production by the **[Agents Deployed](https://agents-deployed.com)** team — we deploy
AI agents on dedicated machines for clients, and `floo` is how we provide secure, recorded, revocable
support to those boxes. Free to use; contributions welcome.
