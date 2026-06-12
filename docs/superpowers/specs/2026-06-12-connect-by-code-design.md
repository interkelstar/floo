# floo — connect by code (drop the name as the routing key)

- **Date:** 2026-06-12
- **Status:** design, pending review
- **Release:** v0.2.0 (breaking protocol change — relay + client + operator upgrade together)

## Goal

Make the **pairing code the session identity**. The operator connects with `floo-powder connect <code>` —
no name to discover, no name collisions across a generic operator's fleet. The name survives only as an
optional human **label**. This is the TeamViewer model: the client reads you a number, you type it.

## Why

The name (`resolve_name` → hostname/…) was the relay routing key *and* the cert principal, but it's only
unique by luck (agents-deployed handed out unique botnames). A generic operator with two `fedora` boxes
collides — the relay refuses the second. The **code is already random and unique per session**, so route
on it instead. Verification also folds in: you type the code the client read you, which *is* the lookup,
so you land on their genuine session by construction (a squatter registered a different code → never your
match). No separate "verify" step.

## Identities (after this change)

| value | secret? | role |
|---|---|---|
| **code** `XXXX-XXXX` (32-bit) | yes (read aloud once) | the operator types it to `connect`; looks the session up |
| **codehash** = `sha256(code)` | no | what the relay stores/compares — code never stored in clear |
| **sid** (random 16-hex) | no | relay routing key, socket name, **cert principal**, ssh handle |
| **label** = `resolve_name` (optional) | no | human display in `list`/recordings; agents-deployed's botname via hook |

The code is **never** the cert principal or socket name (it's short; would leak via the cert). The **sid**
carries routing + auth; the code only ever appears as the human secret + its hash.

## Relay protocol (`floo-route`) — keyed by **sid**

- `register <sid> <codehash> <loginuser> <label> <hostkey…>` — `sid` `^[a-f0-9]{16}$`, `codehash`
  `^[a-f0-9]{64}$`, `label` `^([a-z0-9][a-z0-9-]{0,62})?$` (may be empty). Writes `$SOCKDIR/<sid>.meta`
  (codehash, loginuser, label, registered, peer, hostkey) + expects the `<sid>.sock` reverse socket.
  Refuse if `<sid>.sock` already live (sid is random → effectively never collides).
- `resolve <codehash>` — **NEW.** Linear-scan the live `.meta`s for a matching `codehash`; echo the
  matched session's `sid=…` + `socket=live` + `loginuser=…` + `label=…` + `hostkey=…` (NOT the codehash).
  No match → `deny "no live session for that code"`. This is the code→sid lookup *and* the verification.
- `route <sid>` / `meta <sid>` / `deregister <sid>` — unchanged shape, keyed by sid.
- `list` — echo `sid \t socket \t label \t registered` (no code/codehash). `opconfig` unchanged.
- **Dropped:** `verify` (resolve subsumes it).

Brute-force note: an attacker enumerating codehashes via `resolve` (2³² space, rate-limited by the relay's
MaxStartups/fail2ban) learns sids → can `route` to a client's sshd but still cannot authenticate (operator
CA cert remains the gate). Same exposure class as today's `list`; the cert is the real boundary.

## Client (`floo`)

- Generate `SID` (random 16-hex) + `CODE` (as today) at session start. `codehash = sha256(CODE)`.
- `LABEL = resolve_name` (the existing chain — now an optional label, not load-bearing).
- Session dir, host key, principals file, socket all keyed by **`SID`**. `principals` file = `SID`.
- `register "$SID" "$(codehash "$CODE")" "$(id -un)" "$LABEL" "$hostpub"`; reverse-forward `<SID>.sock`.
- Display the **code** to the user (unchanged UX). `deregister "$SID"` on teardown.
- `--pin` bootstrap unchanged (orthogonal — it's about trusting the relay, not the session id).

## Operator (`floo-powder`)

- `connect <code> [--no-shell]`:
  - `codehash = sha256(uppercased code)`; `relay_ssh resolve "$codehash"` → `sid`, socket, loginuser,
    label, hostkey. No match → abort ("no live session for that code — wrong code, or they closed it").
  - mint cert `-n <sid>`; pin the client hostkey under alias `<sid>`; drop-in `Host <sid>` (+ a second
    `Host <label>` alias **iff** `label` is set and no `<label>.conf` already exists, so agents-deployed
    keeps `ssh vital`); `ProxyCommand … route <sid>`.
  - print: `✓ connected — ssh <sid>` (and `(label: vital)` when present).
- `exec <handle>` / `close <handle>` — `<handle>` is the sid or the label (whichever the drop-in is under).
- `list` — show `LABEL` (or sid if no label) + socket + registered; the operator no longer needs it to
  connect (they have the code), it's situational only.
- **Dropped:** the separate blind-code prompt/compare in `connect` (resolve does it).

## Operator → relay connection (symmetric with the client)

The operator points at a relay **the same way a client does** — `floo-powder --relay <host> --pin <fp> …`
— defaulting to the local/`relay.env` relay. The operator verifies the relay's host key against the pin
(TOFU + compare), exactly like `floo`. No assumption that the operator *owns* or *is co-located with* the
relay: it's a network rendezvous both sides dial.

Topologies this enables:
- **Co-located (default):** `relay.env` points `floo-powder` at the local box. `floo-powder connect <code>`
  just works (today's behavior).
- **Relay on a separate box** (relay on a public-IP VPS, operator on a laptop behind NAT): operator runs
  `floo-powder --relay vps.example.com --pin <fp> connect <code>` (or saves it once). The relay holds only
  the operator's *public* CA + its host key; the CA private key never leaves the operator's machine.
- **Two friends:** A spins up a relay (own box or a VPS), shares the `floo` one-liner with B and points
  A's own `floo-powder` at the same relay+pin. B runs it, reads A the code, A `connect <code>`. Done.

A relay A stands up is *A's relay* (it serves A's CA via `opconfig`) even on rented infra — that works. A
genuinely shared relay serving *multiple distinct operators' CAs* is the multi-tenant case (deferred).

## Security

- Squatter: types-the-code-you-were-given → routes to the genuine client by construction. A squatter's
  session has a different code → never resolved by your code. ✓ (stronger than the explicit compare).
- Cert principal = sid (random, non-secret) → the code never rides in the cert. ✓
- Relay stores only `codehash`; `resolve`/`meta`/`list` never echo it. ✓ (carried from the v0.1 hash fix)
- The operator CA cert remains the sole auth gate; routing-layer knowledge (sid) grants no access.

## Migration / release (v0.2.0)

Breaking: a v0.1 client/operator can't talk to a v0.2 relay (register/route shapes differ). All three
upgrade together — operator redeploys the relay (`install-relay.sh`) and bumps the tag; clients run the
v0.2.0 one-liner. Sessions are ephemeral, so no in-flight compatibility is needed. Same relay host key →
`--pin` unchanged.

## Testing

- Dispatcher unit: `register <sid> …`; `resolve <codehash>` returns the right sid for a live session and
  denies a wrong/absent code; `resolve` never leaks the codehash; `list` shows label not code.
- Loopback: client registers by sid+codehash; operator `connect <code>` (capture the displayed code) →
  resolve → cert → pivot → recorded exec; wrong code → abort; Ctrl-C revoke drops the sid socket.
- Real-box: container client → `connect <code>` → audit → revoke; verify a second client with the **same
  hostname** now coexists (the collision that motivated this).
