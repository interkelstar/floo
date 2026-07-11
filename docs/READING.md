# Reading floo — how to audit this code in ~20 minutes

floo's whole pitch is *"read exactly what you run"*: the client is one bash file
fetched from an immutable git tag, and the operator CLI carries its relay-side
code inline as visible heredocs. That promise only means something if reading it
is actually practical. This is the map.

Every section referenced below is a `# ─── … ───` banner you can jump to with
your editor's search. Line numbers are deliberately not used — banners survive
refactors, line numbers don't.

## The 3 files that matter, in reading order

| File | Lines | What it is |
|------|-------|------------|
| `floo` | ~1100 | The client — the thing a stranger runs on their box. Read this first: it's the trust-critical file. |
| `bin/floo-powder` | ~860 | The operator CLI. Roughly the **second half is the embedded relay payload** (see below), so the "real" CLI is ~330 lines. |
| `relay/floo-route` + `relay/floo-authkeys` | ~230 | The relay-side dispatcher + auth hook — canonical source of the embedded payload. |

Supporting cast: `scripts/embed.sh` (regenerates the payload; `--check` fails on
drift), `relay/install-relay.sh` (relay box bootstrap), `test/` (unit suites +
two full loopback end-to-end runs).

## Pass 1 — the client (`floo`), ~10 minutes

Read it top to bottom; the banners are the outline:

1. **The disclosure** — the *only* public key that can enter, printed to the
   user before anything runs. This is the core of the trust model: start here.
2. **Where to dial out** — relay address resolution (env-overridable; that's
   how the loopback tests run everything against 127.0.0.1).
3. **Attack-surface snapshot** — the honest self-description printed to the
   user. Check that it matches what the code actually does; that's the audit.
4. **Build the throwaway SSH endpoint** — the heart. A single-purpose `sshd`
   in tmpfs (nothing touches durable disk), locked to one key/cert, with
   forced recording. This is the longest section; budget half your time here.
5. **No-cert bind** — quick mode's code-proof (HMAC) check before authorizing
   an operator's ephemeral key. The griefer-bind unit test targets exactly this.
6. **Live renderer / terminal frame / shell hooks / command-log** — UX around
   the session: everything the helped person sees, and the readable log that's
   written alongside the raw recording.
7. **Teardown: the revoke** — Ctrl-C, close, any exit → key gone, sshd gone,
   tmpfs gone. Verify there is no exit path that skips it.

## Pass 2 — the operator CLI (`bin/floo-powder`), ~5 minutes

The first ~330 lines are seven small sections (relay plumbing → operator CA →
session commands → invites → relay lifecycle → foreign-relay pin verification).
Skim them; the security-relevant bits are the CA section and the `--pin`
verification.

Then you hit:

```
# ── BEGIN EMBEDDED RELAY PAYLOAD ──
```

Roughly the second half of the file is code-as-string-literals **on purpose**:
`less floo-powder` must show the exact bytes that will run as root on the
relay. Don't audit the heredocs directly — audit `relay/` (same content,
syntax-highlighted, unit-tested) and trust the drift check:

```sh
scripts/embed.sh --check   # CI and test/run-all.sh fail if they ever diverge
```

## Pass 3 — the relay (`relay/`), ~5 minutes

- `floo-route` — the forced command for every connection to the relay's `gw`
  user. Sessions register here; operators list/connect through here. It is the
  entire relay attack surface: ~200 lines.
- `floo-authkeys` — the `AuthorizedKeysCommand` hook: decides which keys may
  talk to `floo-route` at all. 29 lines.
- `install-relay.sh` — systemd + sshd_config the relay runs under. Check the
  sshd options match what `floo-route` assumes.

## Verifying the promise mechanically

```sh
shellcheck -S warning floo bin/floo-powder relay/* scripts/embed.sh   # clean
scripts/embed.sh --check                                              # no payload drift
bash test/run-all.sh          # unit suites + CA loopback + quick loopback, end to end
```

The loopback tests are the strongest audit shortcut: they stand up a real
relay + real client + real operator on 127.0.0.1 and assert the visible
security properties (wrong code rejected, griefer bind refused, sessions
recorded, Ctrl-C revokes, socket released).

## Companion docs

- [DESIGN.md](DESIGN.md) — why it's shaped this way.
- [THREAT-MODEL.md](THREAT-MODEL.md) — what it defends against, and what it
  deliberately does not.
