# floo — no-cert (quick) mode: build design (v0.4.0)

- **Date:** 2026-06-12
- **Status:** APPROVED FOR BUILD.
- **Supersedes/builds on:** `2026-06-12-quickmode-public-relay-design.md` (the banked design-only
  exploration). This document is the buildable version, with two decisions from the design review folded in.
- **Builds on code:** v0.2.0 connect-by-code (sid routing) + v0.3.2 self-contained operator. No-cert mode is
  a **parallel auth path** alongside CA mode, not a rewrite.

## Goal

Let a floo client open a session that any operator can take **with only a code** — no operator CA, no prior
relationship (TeamViewer-grade casual support). The same relay that serves CA sessions can also broker these
no-cert sessions, gated behind an opt-in flag. The operator pastes a code and floo-powder picks the auth path
automatically.

## Two decisions from the design review (the deltas over the banked spec)

1. **No-cert is a posture of the existing relay, opt-in.** `install-relay.sh --allow-quick` turns it on; the
   default install stays **CA-only**. When on, the relay becomes an open SSH-rendezvous broker for no-cert
   sessions, so abuse caps are mandatory (below). This is deliberate, not default — the open-broker liability
   only exists when the operator chooses it.
2. **The relay's per-session flag is the source of truth for the mode**, not raw code length. The client
   registers a session as `quick=1` or not; `resolve` returns that flag; floo-powder branches on it. Code
   *format* differs by mode (short `XXXX-XXXX` for CA, long high-entropy for no-cert) as the client-side
   generator contract only — so the operator's pasted code still *looks* long-vs-short, but the binding can
   never desync from how the session was actually registered, and changing CA code length later can't silently
   break detection.

## The security model (unchanged from the banked spec, restated)

- **CA mode:** the code is a routing/pairing token; the CA-signed cert (against a CA the client pinned) is the
  real gate. A leaked code is harmless → 32-bit code is fine.
- **No-cert mode:** the **code is the credential** against an *untrusted* relay that sees `sha256(code)` (for
  resolve) and `HMAC(code, opkey)` (for the bind proof). The relay holds **no operator identity** — operators
  are bound per-session via the code + a throwaway key. So:
  - the code must resist offline brute-force by the relay → **≥64-bit entropy**;
  - a malicious relay can route but **cannot impersonate** (no code → can't forge `auth`) and cannot recover
    the code;
  - a stolen operator ephemeral key **dies with the session**.
- No-cert mode is **strictly weaker** than CA mode (leaked/overheard code = access) → opt-in on both ends; CA +
  self-hosted stays the default for fleets and anything sensitive.

## Component changes

### Relay — `floo-route` + `install-relay.sh`

- `install-relay.sh --allow-quick` writes `FLOO_ALLOW_QUICK=1` into the relay env (`/etc/floo/relay.env` or the
  existing env mechanism). Absent → relay **refuses** `register quick=1` and `bindop`/`getop` with a clean
  "quick mode not enabled on this relay" error. The CA path is untouched in either case.
- New verbs:
  - `bindop <sid> <opkey> <auth>` — operator registers its ephemeral pubkey + code-proof. **First write wins**:
    refuse if a binding already exists for the sid. Validate `opkey` as a single ssh pubkey line; validate
    `auth` as hex. Stored in session meta (or `<sid>.bind`).
  - `getop <sid>` — returns `opkey auth` for the client to verify + bind. Public data, useless without the code.
- `register` gains an optional `quick=1` marker; `resolve` returns the quick flag in its meta so the operator
  branches correctly.
- **Caps (active only under `--allow-quick`):**
  - max concurrent quick sessions: **20**
  - per-IP `register` + `bindop` rate-limit: **10 / minute**
  - quick session TTL: **30 minutes** (distinct from CA TTL; expired sessions reaped)
  - reuses the existing `gc_dead` cleanup; extends the existing fail2ban/MaxStartups posture for the rate-limit.

### Client — `floo --public`

- Trigger is a **flag** (`--public`), not a `floo quick` subcommand, so it composes with saved config and the
  existing one-liner. Reuses the saved/`--relay`+`--pin` relay; **no CA required**.
- Registers `quick=1` with a high-entropy code; shows the code to the user.
- Throwaway sshd in no-cert mode: **no `TrustedUserCAKeys`**; `AuthorizedKeysFile $WORKDIR/authorized_keys`
  starting **empty**; `PubkeyAuthentication yes`, `AuthenticationMethods publickey`, all other hardening
  unchanged (`PermitRootLogin no` → client must run non-root, as today).
- After registering, **poll `getop <sid>`**; on a binding, verify `HMAC(code, opkey)==auth`; if good, write
  `opkey` to `authorized_keys` **atomically** and stop polling. sshd reads `authorized_keys` per-connection →
  no reload. From then only that one operator key is accepted.
- Recording, before/after state-diff, `--watch`, Ctrl-C = full revoke / zero standing footprint: **unchanged**.
- **On-demand grant path:** an agents-deployed box that is normally a CA client runs `floo --public` against its
  *same* relay to hand a one-off session to a third-party operator who has no CA — that operator connects with
  only the code.

### Operator — `floo-powder connect <code>` (no new flag)

- `resolve sha256(code)` → sid **+ quick flag** (+ label/loginuser/hostkey, as today).
- **quick=1:** generate ephemeral `OPK` (`ssh-keygen -t ed25519`), compute
  `auth = printf '%s' "$OPKPUB" | openssl dgst -sha256 -hmac "$code" | awk '{print $NF}'`, `bindop sid OPK.pub
  auth`, then `ssh` with `IdentityFile=OPK`, **no `CertificateFile`**, via `route sid`.
- **quick=0:** today's CA-cert path, unchanged.
- Pin the client host key from the resolve meta (unchanged). You paste a code; powder picks the path.

## Code format

- **No-cert:** a **6-word sequence** from a bundled wordlist (~66 bits) — chosen for "read it over the phone"
  ergonomics over base32. Generator lives client-side.
- **CA:** unchanged `XXXX-XXXX` (32-bit).
- Format is the generator contract only; the **relay flag** still decides operator behavior.

## Coexistence

- Default = CA mode (v0.2.0/v0.3.2), unchanged. No-cert is `floo --public` (client) +
  automatic-on-`connect` (operator) + `--allow-quick` (relay).
- The sid-keyed routing layer (`register`/`resolve`/`route`/`meta`/`deregister`/`list`) is shared; only the
  **auth binding** differs (CA cert vs code-bound ephemeral key). That's why this is a parallel path.
- Embedded-relay discipline holds: `relay/*` stays canonical/unit-tested; `scripts/embed.sh` re-embeds into
  `floo-powder`; `embed.sh --check` keeps them from drifting.

## Testing

- **Dispatcher unit:** `bindop` first-write-wins (second bind refused); `getop` returns the binding;
  `register quick=1` refused when `FLOO_ALLOW_QUICK` is unset, accepted when set; `resolve` surfaces the flag.
- **Loopback quick:** client registers quick → operator binds with a valid code-proof → client verifies +
  writes `authorized_keys` → operator connects with the ephemeral key. A **wrong-code** proof is rejected (HMAC
  mismatch); a **second** operator after a successful bind is refused.
- **Real-box:** two friend-pairs on one `--allow-quick` relay simultaneously, no interference; a normally-CA
  agents-deployed box grants a one-off via `floo --public` to an operator with no CA.
- **Adversarial:** a relay that knows only `sha256(code)` + `HMAC(code,opkey)` cannot connect (no ephemeral
  private key, can't forge `auth` without the code).
- **Caps:** registering past max-concurrent is refused; per-IP rate-limit trips; a quick session past TTL is
  reaped.

## Versioning

- Ships as **v0.4.0** (new parallel auth path + relay verbs + client flag). Bump VERSION, CHANGELOG, re-embed,
  tag `v0.4.0` (immutable). The public client/operator one-liners pin the tag, as today.

## Out of scope (explicitly deferred)

- Any agents-deployed *agent-side* tooling to trigger `floo --public` on a deployed box (e.g. an agent tool
  "let my friend Bob help") — that's a downstream consumer concern, not floo core.
- A separate dedicated public relay host (`floo.kelstar.me`): the `--allow-quick` flag makes any relay capable;
  whether to also stand up a dedicated public box is an ops decision, not a code change.
- Client-identity gating of *who may open* a quick session on a relay (vs who may operate it): not needed for
  this version; the caps + opt-in flag are the guardrail.
