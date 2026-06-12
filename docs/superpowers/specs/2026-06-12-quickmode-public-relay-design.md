# floo — quick mode + public relay (no-CA, code-binds-operator)

- **Date:** 2026-06-12
- **Status:** DESIGN ONLY — banked for a future version, not being built now.
- **Builds on:** v0.2.0 connect-by-code (sid routing). Quick mode is a *parallel auth path*, not a rewrite.

## Motivation

For a fleet/org, self-hosted relay + operator CA is right (strongest auth: a leaked code is harmless).
For **friend-to-friend "just help me right now"**, standing up a relay *and* a CA is friction. Goal: a
TeamViewer-grade casual path — a **public relay** anyone can dial (e.g. `floo.kelstar.me`), no per-operator
CA, no self-hosting. The client still accepts only **one** operator per session.

## The key realization

What makes a *public* relay awkward in CA mode is that the relay vouches for *one* operator (serves its CA
via `opconfig`). Quick mode removes operator identity from the relay entirely: the operator is bound to a
session **per-session, via the code, with a throwaway key**. The relay then holds *no* operator secrets —
only per-session ephemeral data — so a public, multi-tenant relay becomes safe and low-trust by
construction. (This is also the real answer to the earlier "multi-tenant deferred" question: quick mode IS
multi-tenant, because there's no per-operator state to namespace.)

## Model

The **code becomes the trust anchor** (like TeamViewer), but the operator authenticates with an *ephemeral*
key bound to the session by the code — not a long-lived password — so the relay can't impersonate and a
stolen ephemeral key dies with the session.

```
client (floo quick)                     relay (public, dumb broker)            operator (floo-powder quick)
  gen sid + CODE (high-entropy)
  register sid, sha256(CODE), label  ─────────────►  store session by sid
  show CODE to the user
                                                                      connect <CODE>  (--relay floo.kelstar.me --pin)
                                                     ◄───────────────  resolve sha256(CODE) → sid
                                          gen ephemeral keypair OPK
                                          auth = HMAC(CODE, OPK.pub)
                                       ◄───────────  bindop sid OPK.pub auth   (FIRST write wins)
  poll getop sid ──────────────────►  return (OPK.pub, auth)
  verify HMAC(CODE, OPK.pub)==auth
  → write OPK.pub to the throwaway
    sshd's authorized_keys; bind DONE
                                                                      ssh (key OPK) ─► route sid ─► client sshd
                                                                      accepted (OPK in authorized_keys) ✓
```

**Single operator per session falls out for free:** the client binds the *first* key whose HMAC verifies,
writes only that one key to `authorized_keys`, and stops polling — everyone else is rejected. The
legitimate operator wins the race by binding promptly (they just got the code).

## The code (this is the security-critical knob)

In quick mode the code IS the credential against an **untrusted** relay, and the relay sees
`HMAC(CODE, OPK.pub)`. So the code MUST resist *offline* brute-force by the relay → it must be **high
entropy**, unlike CA mode's 32-bit `XXXX-XXXX` (fine there because the code isn't the credential).
- Target ≥ 64 bits. Options: 12–13 base32 chars (`K7M2-P9QX-3JFW`), or a 5–6 word sequence from a
  wordlist (more memorable, ~55–66 bits). **Decision deferred** — pick when building; lean toward a
  word-sequence for "read it over the phone" ergonomics.
- The CA-mode code stays short; the two modes use different code generators.

## Protocol additions (relay `floo-route`)

Quick mode reuses `register`/`resolve`/`route`/`meta`/`deregister`/`list` (sid-keyed) and adds:
- `bindop <sid> <opkey> <auth>` — operator registers its ephemeral pubkey + code-proof. **First write
  wins** (refuse if a binding already exists), so an attacker can't overwrite the legit operator's bind.
  `opkey` validated as an ssh pubkey; `auth` as hex. Stored in the session meta (or `<sid>.bind`).
- `getop <sid>` — client fetches `(opkey, auth)` to verify + bind. (Public data; useless without the code.)
- `register` gains a `quick=1` marker so the client's later behavior (poll-for-bind vs use-CA) is set by
  the session, and so a CA-only relay can refuse quick sessions and vice-versa if desired.

The relay still **never** sees the code (only `sha256(code)` for resolve and `HMAC(code, opkey)` for the
proof — both brute-force-infeasible at ≥64-bit code) and never holds an operator identity.

## Client (`floo quick` / `--public`)

- Generate `CODE` (high-entropy) + `sid`. Register with `quick=1`, `sha256(CODE)`, label.
- Throwaway sshd in quick mode: **no** `TrustedUserCAKeys`; `AuthorizedKeysFile $WORKDIR/authorized_keys`
  (initially empty) — `PubkeyAuthentication yes`, `AuthenticationMethods publickey`, all the same
  hardening otherwise.
- After registering, **poll `getop sid`**; on a binding, verify `HMAC(CODE, opkey)==auth`; if good, write
  `opkey` to `authorized_keys` (atomic) and stop polling. sshd reads `authorized_keys` per-connection, so
  no reload needed. From here only that one operator key is accepted.
- Everything else (recording, state-diff, Ctrl-C teardown, `--watch`) is unchanged.

## Operator (`floo-powder quick connect <code>`)

- `resolve sha256(CODE)` → sid (+ label/loginuser/hostkey). Generate ephemeral `OPK` (ssh-ed25519).
- `auth = HMAC(CODE, OPK.pub)` (`openssl mac -macopt ...` / `openssl dgst -sha256 -hmac`).
- `bindop sid OPK.pub auth`. Then `ssh` with `OPK` (no cert) via `route sid`. Drop-in identical to CA mode
  but `IdentityFile=OPK`, no `CertificateFile`.
- Pin the client host key from the resolve meta (unchanged).

## Security analysis

| threat | CA mode | quick mode |
|---|---|---|
| leaked/overheard code | harmless (cert gates) | **= access** (code is the credential) — the TeamViewer trade |
| untrusted/malicious relay | can route, not auth | can route, **can't impersonate** (no code → can't forge `auth`); can't recover the code (≥64-bit) |
| eavesdropper on relay traffic | — | sees `sha256(code)`,`HMAC(code,opk)` → brute-force infeasible at ≥64-bit |
| second party with the code | — | first-binding race; legit operator binds promptly + relay rate-limits `bindop` |
| stolen operator key | CA key = persistent risk | ephemeral key dies with the session |

So quick mode is **strictly weaker than CA mode** (leaked code = access) and **must be opt-in**; CA +
self-hosted stays the default for fleets and anything sensitive. Quick mode is for casual, low-stakes,
"help me right now" with someone you'll also be on the phone/chat with.

## Public relay deployment (`floo.kelstar.me`)

- A relay instance run in **quick-only** mode (or both). It holds **no operator CA** — purely a per-session
  broker → low-value target, safe to expose. `install-relay.sh --public` (no operator CA published).
- Abuse controls (the relay is the only shared resource): per-source `bindop`/register rate-limits
  (extend the existing fail2ban/MaxStartups), a **max concurrent sessions** cap, and short session TTLs.
  Sessions are ephemeral + self-cleaning (the existing `gc_dead`).
- DNS: `floo.kelstar.me → <relay IP>`, grey-cloud (like `relay.agents-deployed.com`). Operators dial it
  with `--relay floo.kelstar.me --pin <published-fp>` (the pin is public — it just authenticates the relay
  host, not any operator).
- Anyone can also run their own public relay the same way; nothing ties it to one operator.

## Coexistence

- Default = CA mode (v0.2.0, unchanged). Quick mode is `floo quick` (client) + `floo-powder quick …`
  (operator), or a `--public`/`--quick` flag. A relay can serve CA-only, quick-only, or both.
- The sid-keyed routing layer is shared; only the **auth binding** differs (CA cert vs code-bound
  ephemeral key). That's why this is a parallel path, not a rewrite.

## Implementation feasibility (bash + ssh)

- HMAC: `openssl` (already a dep via ssh). `auth=$(printf '%s' "$OPKPUB" | openssl dgst -sha256 -hmac "$CODE" | awk '{print $NF}')`.
- Ephemeral key: `ssh-keygen -t ed25519`. Binding: write the pubkey line to `authorized_keys`.
- No new languages/tools. The client's poll loop mirrors the existing monitor/watch loops.

## Open decisions (resolve when building)

1. Code format/entropy (word-sequence vs base32; exact bit target).
2. `bindop` policy: first-write-wins (simpler) vs store-all + client-picks-first-valid (more robust to a
   griefing relay that drops the legit bind). Lean first-write-wins + relay rate-limit.
3. Whether quick mode also wants a relay-side per-session TTL distinct from CA mode.
4. Abuse caps for a truly public relay (max sessions, per-IP limits).

## Testing sketch (when built)

- Dispatcher: `bindop` first-write-wins; `getop` returns it; quick `register` flag.
- Loopback quick: client registers quick, operator binds with a code-proof, client verifies + writes
  authorized_keys, operator connects with the ephemeral key; a WRONG-code proof is rejected (HMAC fails);
  a SECOND operator after binding is refused.
- Real-box: two friend-pairs on one public relay simultaneously, no interference.
- Adversarial: a relay that knows `sha256(code)`+`HMAC` cannot connect (no ephemeral private key, can't
  forge auth without the code).
