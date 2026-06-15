# floo

**Temporary, recorded, instantly-revocable remote console access** — TeamViewer's convenience with a
bastion's security posture, for the terminal. You hand it to someone whose box you *don't* own.

A client types one command **only when they want help**. Their machine dials **out** to a relay you run
and stands up a throwaway SSH endpoint that **only you** can enter. While it's open they see a pairing
code, then your commands and output scroll live in that same window; the whole session is **recorded to
their own disk**. When they press **Ctrl-C** it's over — the endpoint dies, the keys are wiped, and
they're shown whether anything on their box changed. Nothing is installed, nothing runs as root, nothing
survives a reboot.

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
curl -fsSL https://raw.githubusercontent.com/interkelstar/floo/v0.5.1/floo \
  | bash -s -- --relay relay.example.com --pin 0123456789abcdef
```

The `--pin` is a short fingerprint of the operator's relay. `floo` verifies the relay against it, then
fetches the operator's key *from* the relay — so there are no long keys to paste (and nothing for a
terminal to fold and corrupt). The URL is a version tag, so you run exactly the code you can read at
`github.com/interkelstar/floo/tree/v0.5.1`.

…or, if you'll get support more than once, **install it and save your operator once**:

```sh
curl -fsSL https://…/floo -o floo && less floo && sh floo install   # read it, then install to ~/.local/bin
floo config import < operator-config.json                            # save your operator (relay + key)
floo                                                                 # any time you need help, just: floo
```

Read the pairing code back to whoever is helping you — they must repeat it before they can connect.
While they're connected you see their commands and output scroll live in this same window, with a
status line pinned at the bottom; **Ctrl-C** ends it. (`floo --watch` in a second terminal still
gives the same read-only view if you prefer.)

### What you'll see

The live view is a command log, not a screen-share. Each command appears as `$ command` followed by
its text output, rendered through a small terminal emulator that strips control sequences (so nothing
the operator runs can take over the status row). Full-screen tools (`vim`, `less`, `top`) render inline
as their collapsed screen content — they are deliberately **not** hidden or summarized away, because any
"collapse on a full-screen marker" keyed off operator output could be used to hide real output from you.
On exit, the session is saved under `~/.floo-last-session/recording/`: **`session.log` is the readable
command-log** (what you open), and **`session.raw` is the complete raw recording** (the exact bytes — the
tamper-evident record, holding everything even if a determined operator obscured the rendered view).

### Don't trust us — read us

`floo` is one readable Bash file.
- It **never** runs as root or asks for a password.
- Exactly **one** key can enter: the operator's published CA (you supply it as a flag or save it once —
  in plain sight). Only the matching private key, which lives only on the operator's machine, can mint a
  login. Per session, the operator's certificate is good for **≤60 minutes**.
- Access lasts only while the process is alive. Ctrl-C / closing the window revokes it.
- The session is shown live, **recorded** to your disk, and every change to your SSH keys, enabled
  services, or scheduled jobs is shown to you on exit (`~/.floo-last-session/`).

The honest promise is **disclosure, not prevention**: a shell can change a machine; what `floo` guarantees
is that it runs as *your* user, is recorded, and any change to your access surfaces is surfaced to you.

## For the operator

`floo-powder` is **one self-contained file** — the relay (`floo-route`, `floo-authkeys`, and its
installer) is embedded as **plain, readable bash** (verbatim heredocs, not opaque blobs), so there's
nothing else to clone and you can audit exactly what gets root. Fetch it, read it, install it, stand up
your relay:

```sh
curl -fsSL https://raw.githubusercontent.com/interkelstar/floo/v0.5.1/bin/floo-powder -o floo-powder
less floo-powder                     # read it — incl. the embedded relay that `init` sudo-runs, inline + readable
sh floo-powder install               # install into ~/.local/bin (self-fetches if piped)
floo-powder init                     # turnkey: keys + stands up the embedded relay + prints the client one-liner
```

`floo-powder relay-extract <dir>` writes the embedded relay scripts out if you'd rather read or diff
them as separate files.

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

When you open an interactive shell, the client sees a live command log in their `floo` window. Bash and
zsh sessions get exact command boundaries through invisible, nonce-stamped shell markers (the bash hook
reads the full typed line and is robust to any `PROMPT_COMMAND` shape; if the operator has shell history
disabled or `HISTCONTROL=ignorespace`, it falls back to the first simple command rather than mislabel).
Other shells still show a cleaned output stream. Non-interactive `floo-powder exec` uses the same markers.

`floo-powder init` prints the exact one-liner (and an importable config blob) to hand to clients. The
relay is a dedicated, isolated `sshd` serving a single powerless `gw` account; it splices ciphertext and
never sees your session. Cross-distro (Fedora/Debian/Ubuntu/Arch/Alpine); `--uninstall` leaves **zero**
leftovers (only your `~/.config/floo` keys stay — back those up, they *are* your access).

> **Developing floo?** `git clone … && cd floo && bin/floo-powder install` works too — `init` then uses
> the live `relay/` files instead of the embedded copy. After editing anything under `relay/`, run
> `scripts/embed.sh` to re-embed it into `bin/floo-powder` (the test suite's `embed.sh --check` fails on drift).

## No-cert ("quick") mode — code-only, no CA

For a one-off where there's no operator relationship — TeamViewer-style "just help me right now" — a client can
open a session that **any** operator takes with only a code, no CA:

```bash
# relay (opt-in — turns the relay into an open rendezvous broker for code-only sessions):
sudo ./install-relay.sh --allow-quick        # default install stays CA-only

# client:
floo --public --relay <host> --pin <fp>      # shows a long base32 code; no operator CA needed

# operator (no new flag — connect auto-detects the mode from the session):
floo-powder --relay <host> --pin <fp> connect <code>
```

In this mode **the code IS the credential** (it's long — ~65 bits — on purpose): the client authorizes the
single operator key whose `HMAC(code, key)` matches, so only the code-holder gets in, and a junk bind can't
squat the session. This is **strictly weaker than CA mode** — anyone who learns the code can connect — so it's
**opt-in on every side** and CA mode stays the default. Recording, state-diff, and Ctrl-C = revoke are unchanged.
Caps under `--allow-quick`: max concurrent quick sessions + a short session TTL (per-IP throttling is the relay
sshd's existing per-source limits + fail2ban).

### Friend-to-friend — nothing to host, use the public relay

Helping a friend (or getting help) and neither of you wants to run a relay? Use the **public floo relay** at
`floo.kelstar.me` — a free, no-cert rendezvous you can point at right out of the box:

```bash
# the person who needs help (the client) runs this and reads back the code it prints:
curl -fsSL https://raw.githubusercontent.com/interkelstar/floo/v0.5.1/floo \
  | bash -s -- --public --relay floo.kelstar.me --pin df2b83ff925f89bd

# the person helping (the operator) installs floo-powder once, then connects with that code:
floo-powder --relay floo.kelstar.me --pin df2b83ff925f89bd connect <code>
```

The `--pin df2b83ff925f89bd` is the relay's host-key fingerprint (public — it's how `floo` verifies it's
reaching the real relay and not a MITM). The **code is the only secret**: read it to the *one* person you
mean to let in, and close the window when you're done. Everything else is identical to a self-hosted
session — the helper gets a shell, you watch the live command log, the session is recorded to your disk, and
Ctrl-C revokes. For anything ongoing or sensitive, stand up your own relay (one command, above) and use CA
mode; the public relay is a courtesy for one-off "just help me right now" moments.

## How it works

`floo` (client) dials out to your relay and opens a throwaway `sshd`, registering under a random
session id with a one-time **code** it shows the client. In CA mode the endpoint accepts only an
operator-CA-signed cert; in quick mode it accepts the single operator key proven by the code.
`floo-powder connect <code>` resolves that code to
the session — so you reach the *genuine* client by construction (a squatter registered a different code, so
your code never resolves to them), with no name to collide across a fleet. It pins the relay + client host
keys, mints a ≤60-min cert (bound to that session id), and connects end-to-end *through* the relay.
The client's window renders a live command log from the local recording; on teardown the complete raw
recording (`session.raw`) is saved as the tamper-evident record, with a readable rendered `session.log` beside it
+ the before/after state-diff. Ctrl-C/close = full teardown.

Design & threat model: [`docs/DESIGN.md`](docs/DESIGN.md), [`docs/THREAT-MODEL.md`](docs/THREAT-MODEL.md).
Tests: `bash test/run-all.sh` (unit + a full single-host loopback proving cert-only entry, the
pairing-code gate, real Ctrl-C revoke, and the state-diff).

MIT licensed. The whole access mechanism is open on purpose — a client can read exactly what they grant.

---

Built and run in production by the **[Agents Deployed](https://agents-deployed.com)** team — we deploy
AI agents on dedicated machines for clients, and `floo` is how we provide secure, recorded, revocable
support to those boxes. Free to use; contributions welcome.
