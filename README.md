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

Only when you want help. Either run it ad-hoc:

```sh
curl -fsSL https://raw.githubusercontent.com/interkelstar/floo/<commit>/floo \
  | bash -s -- --relay relay.example.com --operator-ca 'ssh-ed25519 AAAA… op'
```

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

```sh
git clone https://github.com/interkelstar/floo && cd floo
bin/floo-powder install                  # symlink floo-powder (+ floo) into ~/.local/bin — then drop the bin/ prefix
floo-powder init                         # turnkey: keys + relay + prints the client one-liner & config blob

floo-powder list                     # clients with an open session (+ pairing code)
floo-powder connect <name>           # type the code the CLIENT reads you, get a shell
floo-powder exec <name> < audit.sh   # run a script non-interactively (recorded on the client)
floo-powder close <name>             # drop operator-side routing
```

`floo-powder init` prints the exact one-liner (and an importable config blob) to hand to clients. The
relay is a dedicated, isolated `sshd` serving a single powerless `gw` account; it splices ciphertext and
never sees your session. Cross-distro (Fedora/Debian/Ubuntu/Arch/Alpine); `--uninstall` leaves **zero**
leftovers (only your `~/.config/floo` keys stay — back those up, they *are* your access).

## How it works

`floo` (client) dials out to your relay and opens a cert-only throwaway `sshd`; `floo-powder connect`
verifies the pairing code (you type what the client reads, never seeing the relay's copy — so a squatter
is caught), pins the relay + client host keys, mints a ≤60-min cert, and connects end-to-end *through* the
relay to the client's own endpoint. Recording + before/after state-diff; Ctrl-C/close = full teardown.

Design & threat model: [`docs/DESIGN.md`](docs/DESIGN.md), [`docs/THREAT-MODEL.md`](docs/THREAT-MODEL.md).
Tests: `bash test/run-all.sh` (unit + a full single-host loopback proving cert-only entry, the
pairing-code gate, real Ctrl-C revoke, and the state-diff).

MIT licensed. The whole access mechanism is open on purpose — a client can read exactly what they grant.

---

Built and run in production by the **[Agents Deployed](https://agents-deployed.com)** team — we deploy
AI agents on dedicated machines for clients, and `floo` is how we provide secure, recorded, revocable
support to those boxes. Free to use; contributions welcome.
