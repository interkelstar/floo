# floo no-cert (quick) mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a code-as-credential, no-CA support path to floo: a client opens a session any operator can take with only a high-entropy code, brokered by the same relay (opt-in `--allow-quick`), with the operator auto-detecting the mode.

**Architecture:** A parallel auth path alongside CA mode. The relay gains a per-session `quick` flag, `bindop`/`getop` verbs (store-all binds), an `allow_quick` gate, and two new caps (max-concurrent + TTL). The client gains `--public` (base32 code, no-CA throwaway sshd, poll-getop + HMAC-verify + write `authorized_keys`). The operator's `connect` branches on the resolved `quick` flag (ephemeral key + `HMAC(code,opkey)` proof instead of a CA cert). All routing (sid-keyed) is shared.

**Tech Stack:** Bash, OpenSSH (sshd/ssh/ssh-keygen), openssl (HMAC), coreutils (base32/od/sha256sum). No new languages.

**Spec:** `docs/superpowers/specs/2026-06-12-nocert-mode-build-design.md`

**Key invariants the engineer must preserve:**
- `relay/*` is canonical and unit-tested; `bin/floo-powder` carries an EMBEDDED verbatim copy. **After ANY edit to `relay/floo-route`, `relay/floo-authkeys`, or `relay/install-relay.sh`, run `scripts/embed.sh` (no args) to re-embed BEFORE committing**, or `test/unit/embed.sh` (`embed.sh --check`) fails.
- `register`'s arg parsing must stay **backward-compatible** with deployed v0.2.0 clients (host key currently slurped from arg 5). The `quick` flag is an OPTIONAL token at position 5 (`quick=0|1`); when absent, the host key still starts at arg 5.
- Code normalization: both client and operator uppercase the code before BOTH `sha256` (resolve) and `HMAC` (bind proof). base32 is already uppercase; apply uniformly anyway.
- Run `node --check`-equivalent for bash: `bash -n <file>` after each script edit before committing.
- Commit as Vlad: `git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' commit`. Push only at the end, after the whole suite is green and Vlad has seen it.

---

## File Structure

- `relay/floo-route` (modify) — quick-aware `register`; new `bindop`/`getop`; quick caps + helpers; `.binds` cleanup in `gc_dead`/`deregister`/prune.
- `relay/install-relay.sh` (modify) — `--allow-quick` writes `/etc/floo/allow_quick`; `--uninstall` removes it.
- `bin/floo-powder` (modify) — re-embedded relay (via `scripts/embed.sh`); `connect` quick branch.
- `floo` (modify) — `--public` flag, base32 code generator, no-CA endpoint, bind-watcher poll loop.
- `test/unit/dispatcher.sh` (modify) — quick register/bindop/getop/caps assertions.
- `test/quick-loopback.sh` (create) — end-to-end no-cert proof.
- `test/run-all.sh` (modify) — run the new loopback.
- `VERSION`, `CHANGELOG.md`, `README.md` (modify) — v0.4.0.

---

## Task 1: Relay dispatcher — quick-aware `register` + allow-quick gate + caps

**Files:**
- Modify: `relay/floo-route`
- Test: `test/unit/dispatcher.sh`

- [ ] **Step 1: Add config + helpers near the top of `relay/floo-route`**

In `relay/floo-route`, after the `CA_FILE=` line (currently line 22), add:

```bash
ALLOW_QUICK_FILE="${FLOO_ALLOW_QUICK_FILE:-/etc/floo/allow_quick}"   # marker written by install-relay.sh --allow-quick
QUICK_MAX="${FLOO_QUICK_MAX:-20}"        # cap on concurrent quick sessions
QUICK_TTL="${FLOO_QUICK_TTL:-1800}"      # quick session lifetime (seconds) before it's pruned
MAX_BINDS="${FLOO_QUICK_MAXBINDS:-64}"   # cap on stored operator binds per quick session (anti disk-fill)
allow_quick() { [ -f "$ALLOW_QUICK_FILE" ]; }
valid_authhex() { [[ "$1" =~ ^[a-f0-9]{64}$ ]]; }
```

Then, immediately AFTER the existing `gc_dead()` definition (currently line 46), add:

```bash
# count quick sessions whose socket is live (the concurrency cap is on ACTIVE sessions)
count_quick_live() {
  local n=0 m s; shopt -s nullglob
  for m in "$SOCKDIR"/*.meta; do
    [ "$(sed -n 's/^quick=//p' "$m")" = 1 ] || continue
    s="$(sed -n 's/^sid=//p' "$m")"
    socket_live "$SOCKDIR/$s.sock" && n=$((n+1))
  done
  echo "$n"
}
# reap quick sessions older than the TTL (CA sessions are untouched — they have no registered_epoch quick gate)
prune_quick_expired() {
  local now m e s; now="$(date +%s)"; shopt -s nullglob
  for m in "$SOCKDIR"/*.meta; do
    [ "$(sed -n 's/^quick=//p' "$m")" = 1 ] || continue
    e="$(sed -n 's/^registered_epoch=//p' "$m")"; [ -n "$e" ] || continue
    if [ $((now - e)) -gt "$QUICK_TTL" ]; then
      s="$(sed -n 's/^sid=//p' "$m")"; rm -f "$SOCKDIR/$s.sock" "$SOCKDIR/$s.meta" "$SOCKDIR/$s.binds"
    fi
  done
}
```

- [ ] **Step 2: Make `gc_dead` also remove the `.binds` file**

Replace the `gc_dead()` body (line 46) so it cleans the binds file too:

```bash
gc_dead() { local s="$1"; [ -e "$SOCKDIR/$s.sock" ] && ! socket_live "$SOCKDIR/$s.sock" && rm -f "$SOCKDIR/$s.sock" "$SOCKDIR/$s.meta" "$SOCKDIR/$s.binds"; return 0; }
```

- [ ] **Step 3: Make `register` quick-aware (backward-compatible) + write the quick meta**

In the `register)` case, replace the host-key slurp line:

```bash
    hostpub="${A[*]:5}";   [ -n "$hostpub" ]          || deny "missing host key"
```

with optional-quick-token parsing:

```bash
    # optional quick flag at position 5 (literal "quick=0|1"); else the host key starts at 5 (back-compat
    # with v0.2 clients that send no flag — their A[5] is "ssh-ed25519 …", which is NOT "quick=*").
    quick=0
    if [[ "${A[5]:-}" == quick=* ]]; then
      quick="${A[5]#quick=}"; [[ "$quick" =~ ^[01]$ ]] || deny "bad quick flag"; hostpub="${A[*]:6}"
    else
      hostpub="${A[*]:5}"
    fi
    [ -n "$hostpub" ] || deny "missing host key"
```

Then, right AFTER the host-key format check line (`case "$hostpub" in ssh-ed25519\ * … deny "bad host key" ;; esac`), add the quick gate + caps:

```bash
    if [ "$quick" = 1 ]; then
      allow_quick || deny "quick mode not enabled on this relay"
      prune_quick_expired
      [ "$(count_quick_live)" -lt "$QUICK_MAX" ] || deny "too many active quick sessions; try again shortly"
    fi
```

Finally, in the meta-writing block, add `quick` + `registered_epoch` lines. Change:

```bash
      echo "loginuser=$loginuser"
      echo "label=$label"
      echo "registered=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

to:

```bash
      echo "loginuser=$loginuser"
      echo "label=$label"
      echo "quick=$quick"
      echo "registered=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "registered_epoch=$(date +%s)"
```

- [ ] **Step 4: Keep `registered_epoch` out of operator-facing output**

In `resolve)`, change the metadata echo line:

```bash
      grep -vE '^(code|sid)=' "$m"   # loginuser, label, registered, peer, hostkey
```

to also hide the epoch (quick flag stays visible — the operator needs it):

```bash
      grep -vE '^(code|sid|registered_epoch)=' "$m"   # loginuser, label, quick, registered, peer, hostkey
```

In `meta)`, change:

```bash
    grep -v '^code=' "$SOCKDIR/$sid.meta"
```

to:

```bash
    grep -vE '^(code|registered_epoch)=' "$SOCKDIR/$sid.meta"
```

- [ ] **Step 5: Prune expired quick sessions on resolve + list too**

In `resolve)`, immediately after `valid_codehash "$ch" || deny "bad code hash"`, add:

```bash
    prune_quick_expired
```

In `list)`, immediately after `shopt -s nullglob` (the first line of the case), add:

```bash
    prune_quick_expired
```

- [ ] **Step 6: Syntax-check, re-embed, run dispatcher unit (expect existing tests still pass)**

```bash
cd ~/projects/floo
bash -n relay/floo-route && echo OK
scripts/embed.sh                      # re-embed into bin/floo-powder
bash test/unit/dispatcher.sh
```
Expected: `bash -n` prints OK; dispatcher unit still ends `… 0 failed` (existing assertions unaffected — register without a flag still works; the new meta lines don't break existing greps).

- [ ] **Step 7: Commit**

```bash
git add relay/floo-route bin/floo-powder
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' \
  commit -m "relay: quick-aware register (opt-in gate, max-concurrent + TTL caps)"
```

---

## Task 2: Relay dispatcher — `bindop` + `getop` verbs (store-all)

**Files:**
- Modify: `relay/floo-route`
- Test: `test/unit/dispatcher.sh`

- [ ] **Step 1: Write failing dispatcher assertions for bindop/getop**

In `test/unit/dispatcher.sh`, after the opconfig block (the two `opconfig` assertions ending at the `rm -f "$CAF"` line, currently line 58), add a quick-mode section. It needs a live socket + an allow-quick marker + a registered quick session:

```bash
echo "=== quick mode (bindop/getop, allow-quick gate, caps) ==="
QSID="b1c2d3e4f5061728"
QCODE="ABCD-EF01-2345-6"; QCH="$(printf '%s' "$QCODE" | sha256sum | cut -c1-64)"
OPKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAopkeyblob op-test"
AUTH="$(printf '%s' "$OPKEY" | openssl dgst -sha256 -hmac "$QCODE" | awk '{print $NF}')"
ALLOWQ="$(mktemp)"   # presence = quick enabled
qroute(){ SSH_ORIGINAL_COMMAND="$*" SSH_CONNECTION="1.2.3.4 5 6 7" FLOO_ALLOW_QUICK_FILE="$ALLOWQ" bash "$ROUTE"; }

# a live listener for the quick session
QL=""; nc -lkU "$SOCK/$QSID.sock" >/dev/null 2>&1 & QL=$!; sleep 0.4

# register is REFUSED for quick=1 when the allow-quick marker is absent
SSH_ORIGINAL_COMMAND="register $QSID $QCH kelstar qbox quick=1 $OPKEY" SSH_CONNECTION="1.2.3.4 5 6 7" \
  FLOO_ALLOW_QUICK_FILE=/nonexistent bash "$ROUTE" >/dev/null 2>&1 \
  && bad "quick register accepted with allow-quick OFF" || ok "quick register refused when allow-quick is off"

# with the marker present, quick register succeeds and records quick=1
qroute register "$QSID" "$QCH" kelstar qbox quick=1 $OPKEY >/dev/null 2>&1 \
  && grep -q '^quick=1' "$SOCK/$QSID.meta" && ok "quick register writes quick=1 meta" || bad "quick register failed"

# bindop appends a bind; getop returns it
qroute bindop "$QSID" "$AUTH" $OPKEY >/dev/null 2>&1 && ok "bindop accepted a well-formed bind" || bad "bindop rejected a valid bind"
grep -q "$AUTH" <<<"$(qroute getop "$QSID" 2>/dev/null)" && ok "getop returns the stored bind" || bad "getop did not return the bind"

# store-all: a second (griefer, junk-auth) bind is also stored, and getop returns BOTH
GARBAGE="$(printf '%064d' 0 | tr 0 d)"   # 64 hex chars, wrong auth
qroute bindop "$QSID" "$GARBAGE" "ssh-ed25519 AAAAgrieferblob grief" >/dev/null 2>&1
[ "$(qroute getop "$QSID" 2>/dev/null | wc -l)" -ge 2 ] && ok "store-all keeps multiple binds (client filters)" || bad "second bind not stored"

# bindop is refused for a non-quick session
qroute bindop "$SID" "$AUTH" $OPKEY >/dev/null 2>&1 && bad "bindop accepted on a non-quick session" || ok "bindop refuses a non-quick session"
# bindop validates the auth hex + the key
qroute bindop "$QSID" NOTHEX $OPKEY >/dev/null 2>&1 && bad "bindop accepted a non-hex auth" || ok "bindop rejects a malformed auth"
# getop on a session with no binds denies
qroute getop "$SID" >/dev/null 2>&1 && bad "getop returned binds for a session with none" || ok "getop denies when nothing is bound"

kill "$QL" 2>/dev/null; rm -f "$SOCK/$QSID.sock" "$SOCK/$QSID.binds" "$SOCK/$QSID.meta" "$ALLOWQ"
```

Run it — it must FAIL (verbs not implemented yet):

```bash
bash test/unit/dispatcher.sh; echo "exit=$?"
```
Expected: FAILs on the bindop/getop assertions (unknown command denies).

- [ ] **Step 2: Implement `bindop` + `getop` in `relay/floo-route`**

In `relay/floo-route`, add two new cases immediately BEFORE the `deregister)` case:

```bash
  bindop)
    sid="${A[1]:-}";  valid_sid "$sid"      || deny "bad sid"
    auth="${A[2]:-}"; valid_authhex "$auth" || deny "bad auth"
    opkey="${A[*]:3}"; [ -n "$opkey" ]      || deny "missing operator key"
    case "$opkey" in ssh-ed25519\ *|ssh-rsa\ *|ecdsa-*\ *) ;; *) deny "bad operator key" ;; esac
    [ -f "$SOCKDIR/$sid.meta" ] || deny "no such session"
    [ "$(sed -n 's/^quick=//p' "$SOCKDIR/$sid.meta")" = 1 ] || deny "not a quick session"
    allow_quick || deny "quick mode not enabled on this relay"
    socket_live "$SOCKDIR/$sid.sock" || { gc_dead "$sid"; deny "no live socket"; }
    # STORE-ALL (not first-write-wins): a junk bind can't squat the slot; the code-holder's
    # bind is found by the client among the inert ones. Cap the list to bound disk use.
    local n; n="$( [ -f "$SOCKDIR/$sid.binds" ] && wc -l < "$SOCKDIR/$sid.binds" || echo 0 )"
    [ "$n" -lt "$MAX_BINDS" ] || deny "too many bind attempts for that session"
    umask 077; printf '%s %s\n' "$auth" "$opkey" >> "$SOCKDIR/$sid.binds"
    log "bindop $sid"
    echo "bound $sid"
    ;;

  getop)
    sid="${A[1]:-}"; valid_sid "$sid" || deny "bad sid"
    [ -f "$SOCKDIR/$sid.binds" ] || deny "no operator bound yet"
    cat "$SOCKDIR/$sid.binds"
    ;;
```

Note: `local` is valid here only if the case runs inside a function — it does NOT (the dispatcher is top-level). Use a plain assignment instead:

```bash
    n="$( [ -f "$SOCKDIR/$sid.binds" ] && wc -l < "$SOCKDIR/$sid.binds" || echo 0 )"
```
(Drop the `local` keyword — top-level script scope.)

- [ ] **Step 3: Make `deregister` remove the `.binds` file**

In `deregister)`, change:

```bash
    rm -f "$SOCKDIR/$sid.sock" "$SOCKDIR/$sid.meta"
```

to:

```bash
    rm -f "$SOCKDIR/$sid.sock" "$SOCKDIR/$sid.meta" "$SOCKDIR/$sid.binds"
```

- [ ] **Step 4: Syntax-check, re-embed, run the unit test (expect PASS)**

```bash
bash -n relay/floo-route && echo OK
scripts/embed.sh
bash test/unit/dispatcher.sh
```
Expected: ends `… 0 failed`, including the new quick assertions.

- [ ] **Step 5: Commit**

```bash
git add relay/floo-route bin/floo-powder test/unit/dispatcher.sh
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' \
  commit -m "relay: bindop/getop verbs (store-all binds) + unit tests"
```

---

## Task 3: `install-relay.sh` — `--allow-quick` marker + uninstall cleanup

**Files:**
- Modify: `relay/install-relay.sh`
- Test: `test/unit/init.sh` (add a focused assertion) — see Step 1.

- [ ] **Step 1: Write a failing assertion that --allow-quick writes the marker**

Append to `test/unit/init.sh` (before its final `echo … passed` / exit). First read the file to match its `ok`/`bad` helper names; it follows the same `ok(){…}`/`bad(){…}` pattern. Add:

```bash
echo "=== install-relay --allow-quick marker (parse-only, no sudo) ==="
# We don't run the installer (it needs root); we assert the script CONTAINS the marker logic and
# that --uninstall removes it. Static checks keep this unit test rootless + deterministic.
INST="$ROOT/relay/install-relay.sh"   # ROOT is defined at the top of init.sh; if not, use the repo root var it already uses
grep -q 'allow_quick' "$INST" && ok "install-relay references the allow_quick marker" || bad "no allow_quick handling"
grep -q '\-\-allow-quick' "$INST" && ok "install-relay accepts --allow-quick" || bad "no --allow-quick flag"
grep -q 'rm -f .*allow_quick' "$INST" && ok "uninstall removes the allow_quick marker" || bad "uninstall leaves allow_quick"
```

If `init.sh` uses a different repo-root variable name than `ROOT`, reuse that one (open the file and check the header). Run it — must FAIL:

```bash
bash test/unit/init.sh; echo "exit=$?"
```

- [ ] **Step 2: Add `--allow-quick` parsing to `install-relay.sh`**

In `relay/install-relay.sh`, after the `PORT=…`/`SOCKDIR=…`/`ETC=…`/`SELF_DIR=…` block (currently lines 453-456) and BEFORE the `[ "$(id -u)" = 0 ]` root check, add a flag parse:

```bash
ALLOW_QUICK=0
for a in "$@"; do [ "$a" = "--allow-quick" ] && ALLOW_QUICK=1; done
```

This leaves `--uninstall` detection (`[ "${1:-}" = "--uninstall" ]`) intact since `--allow-quick` would be a different arg; if both are passed, uninstall still wins (it `exit`s).

- [ ] **Step 3: Write/remove the marker during install**

In `install-relay.sh`, just AFTER the `mkdir -p "$ETC"; chmod 755 "$ETC"; echo "$PORT" > "$ETC/port"` line (currently line 535), add:

```bash
# quick (no-CA) sessions are OFF unless explicitly enabled — the relay becomes an open rendezvous
# broker for them, so it's an opt-in posture. The dispatcher checks for this marker file.
if [ "$ALLOW_QUICK" = 1 ]; then
  : > "$ETC/allow_quick"; echo "==> quick (no-cert) sessions ENABLED (--allow-quick) — relay will broker code-only sessions"
else
  rm -f "$ETC/allow_quick"; echo "==> quick (no-cert) sessions disabled (default; pass --allow-quick to enable)"
fi
```

- [ ] **Step 4: Remove the marker on uninstall**

In the `uninstall()` function, the `rm -rf "$ETC" "$SOCKDIR"` line already removes `$ETC/allow_quick` (it's inside `$ETC`). To make the test's `rm -f .*allow_quick` grep pass AND be explicit, add before that line:

```bash
  rm -f "$ETC/allow_quick"
```

- [ ] **Step 5: Syntax-check, re-embed, run init unit (expect PASS)**

```bash
bash -n relay/install-relay.sh && echo OK
scripts/embed.sh
bash test/unit/init.sh
```
Expected: ends with 0 failures including the 3 new assertions.

- [ ] **Step 6: Commit**

```bash
git add relay/install-relay.sh bin/floo-powder test/unit/init.sh
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' \
  commit -m "install-relay: --allow-quick opt-in marker (+uninstall cleanup)"
```

---

## Task 4: Re-embed verification (embed drift guard stays green)

**Files:**
- Verify only: `bin/floo-powder`, `test/unit/embed.sh`

- [ ] **Step 1: Confirm the embed is in sync and readable**

The previous tasks each re-ran `scripts/embed.sh`. Confirm no drift and the embed unit passes (it checks readability + byte-identical reproduction of the now-quick-aware relay):

```bash
cd ~/projects/floo
scripts/embed.sh --check && echo "EMBED IN SYNC"
bash test/unit/embed.sh
```
Expected: `EMBED IN SYNC`; embed unit ends `… 0 failed`. The `relay-extract` byte-compare now reproduces the quick-aware `floo-route` exactly.

- [ ] **Step 2: (No commit unless drift found)**

If `--check` reported drift (a relay edit wasn't re-embedded), run `scripts/embed.sh`, then:

```bash
git add bin/floo-powder
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' commit -m "re-embed quick-aware relay into floo-powder"
```

---

## Task 5: Operator `connect` — auto-detect quick + ephemeral-key bind

**Files:**
- Modify: `bin/floo-powder` (the `cmd_connect` function, lines 85-140)

- [ ] **Step 1: Parse the resolved `quick` flag**

In `cmd_connect`, after the existing meta parse block, add a `quick` extraction. Change:

```bash
  sid="$(sed -n 's/^sid=//p' <<<"$meta")"
  loginuser="$(sed -n 's/^loginuser=//p' <<<"$meta")"
  label="$(sed -n 's/^label=//p' <<<"$meta")"
  hostkey="$(sed -n 's/^hostkey=//p' <<<"$meta" | awk '{print $1, $2}')"
```

to add `quick`:

```bash
  sid="$(sed -n 's/^sid=//p' <<<"$meta")"
  loginuser="$(sed -n 's/^loginuser=//p' <<<"$meta")"
  label="$(sed -n 's/^label=//p' <<<"$meta")"
  hostkey="$(sed -n 's/^hostkey=//p' <<<"$meta" | awk '{print $1, $2}')"
  local quick; quick="$(sed -n 's/^quick=//p' <<<"$meta")"
```

Also widen the `local` declaration line `local sid loginuser label hostkey` to include nothing extra (quick is declared inline above).

- [ ] **Step 2: Branch the cert-minting + drop-in on `quick`**

Replace this contiguous block (currently lines 119-137, from the `ssh-keygen … opkey` line through the `chmod 600 "$SSH_DROPIN_DIR/$handle.conf"` line):

```bash
  ssh-keygen -t ed25519 -f "$sdir/opkey" -N '' -q -C "op-$sid"
  ssh-keygen -s "$CA" -I "op-$sid-$(date -u +%Y%m%dT%H%M%SZ)" -n "$sid" -V +60m "$sdir/opkey.pub" >/dev/null
  echo "${D}minted a 60-minute certificate (principal=$sid)${X}"

  cat > "$SSH_DROPIN_DIR/$handle.conf" <<CONF
# floo-powder session $handle (sid $sid) — auto-managed, expires with the cert (≤60m). Safe to delete.
Host $handle
    HostName $handle
    HostKeyAlias $handle
    User $loginuser
    ProxyCommand ssh -p "$RELAY_PORT" -i "$RELAY_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$FLOO_HOME/relay_known_hosts" "$RELAY_USER@$RELAY_HOST" route "$sid"
    IdentityFile "$sdir/opkey"
    CertificateFile "$sdir/opkey-cert.pub"
    IdentitiesOnly yes
    UserKnownHostsFile "$sdir/known_hosts"
    StrictHostKeyChecking yes
    RequestTTY auto
CONF
  chmod 600 "$SSH_DROPIN_DIR/$handle.conf"
```

with a branched version (CA path unchanged; quick path = ephemeral key + HMAC bind, no `CertificateFile`):

```bash
  ssh-keygen -t ed25519 -f "$sdir/opkey" -N '' -q -C "op-$sid"
  local certline="" waitline=""
  if [ "$quick" = 1 ]; then
    command -v openssl >/dev/null 2>&1 || die "quick (no-cert) mode needs openssl for the code proof"
    local opkpub authproof
    opkpub="$(cat "$sdir/opkey.pub")"
    authproof="$(printf '%s' "$opkpub" | openssl dgst -sha256 -hmac "${code^^}" | awk '{print $NF}')"
    [ -n "$authproof" ] || die "could not compute the code proof"
    relay_ssh bindop "$sid" "$authproof" "$opkpub" >/dev/null \
      || die "the relay refused the operator bind — quick mode may be off on this relay, or too many binds."
    echo "${D}no CA: bound an ephemeral key to the session by code-proof (HMAC) — TeamViewer-style${X}"
    waitline=1   # the client authorizes our key after it verifies the proof; wait for it below
  else
    ssh-keygen -s "$CA" -I "op-$sid-$(date -u +%Y%m%dT%H%M%SZ)" -n "$sid" -V +60m "$sdir/opkey.pub" >/dev/null
    echo "${D}minted a 60-minute certificate (principal=$sid)${X}"
    certline="    CertificateFile \"$sdir/opkey-cert.pub\""
  fi

  cat > "$SSH_DROPIN_DIR/$handle.conf" <<CONF
# floo-powder session $handle (sid $sid) — auto-managed. Safe to delete.
Host $handle
    HostName $handle
    HostKeyAlias $handle
    User $loginuser
    ProxyCommand ssh -p "$RELAY_PORT" -i "$RELAY_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$FLOO_HOME/relay_known_hosts" "$RELAY_USER@$RELAY_HOST" route "$sid"
    IdentityFile "$sdir/opkey"
$certline
    IdentitiesOnly yes
    UserKnownHostsFile "$sdir/known_hosts"
    StrictHostKeyChecking yes
    RequestTTY auto
CONF
  chmod 600 "$SSH_DROPIN_DIR/$handle.conf"

  # quick mode: the client only authorizes our key after polling getop + verifying the HMAC. Wait
  # briefly so 'ssh' / exec don't race the authorization (the CA path is authorized the instant the cert exists).
  if [ -n "$waitline" ]; then
    local i
    for i in $(seq 1 15); do
      ssh -o BatchMode=yes -o ConnectTimeout=8 "$handle" true 2>/dev/null && break
      sleep 1
    done
  fi
```

Note: the `$certline` line expands to empty for quick mode, leaving a blank line in the config (harmless to ssh). The `${code^^}` is the same normalized code used in `codehash "${code^^}"` at resolve — so the client's `HMAC(norm(code),opkey)` matches.

- [ ] **Step 3: Syntax-check + smoke (help still renders, version intact)**

```bash
bash -n bin/floo-powder && echo OK
bin/floo-powder --version
```
Expected: OK; version prints (still `0.3.2` until Task 8 bumps it).

- [ ] **Step 4: Commit**

```bash
git add bin/floo-powder
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' \
  commit -m "floo-powder connect: auto-detect quick mode, bind ephemeral key by HMAC code-proof"
```

---

## Task 6: Client `floo` — `--public` (base32 code, no-CA endpoint, bind-watcher)

**Files:**
- Modify: `floo`

- [ ] **Step 1: Add the `--public` flag + a `norm` helper + relax the CA requirement**

In `floo`, add the flag default near the other `FLOO_*` defaults (after line 53, the `FLOO_RELAY_PIN=` line):

```bash
FLOO_PUBLIC="${FLOO_PUBLIC:-0}"     # --public: no-CA "quick" mode; the code IS the credential
```

Add a normalizer next to `codehash()` (after line 63):

```bash
norm() { printf '%s' "$1" | tr 'a-z' 'A-Z'; }   # uniform code casing for sha256 + HMAC on both ends
```

In `main()`'s arg loop, add a case (next to `--name`):

```bash
    --public) FLOO_PUBLIC=1; shift;;
```

In `main()`, the session-mode guard currently requires an operator CA:

```bash
      [ -n "$FLOO_RELAY_HOST" ] && [ -n "$FLOO_OPERATOR_CA" ] || { warn "no operator configured — pass --relay H --operator-ca KEY, or run 'floo config import' first."; exit 1; }
```

Replace it so public mode needs only a relay (no CA):

```bash
      if [ "$FLOO_PUBLIC" = 1 ]; then
        [ -n "$FLOO_RELAY_HOST" ] || { warn "no relay configured — pass --relay H[:P] (and --pin FP), or import a config."; exit 1; }
        command -v openssl >/dev/null 2>&1 || { warn "public mode needs openssl (for the code proof) — install it."; exit 1; }
      else
        [ -n "$FLOO_RELAY_HOST" ] && [ -n "$FLOO_OPERATOR_CA" ] || { warn "no operator configured — pass --relay H --operator-ca KEY, or run 'floo config import' first."; exit 1; }
      fi
```

Also, `--pin` must STILL pin the relay host key in public mode (anti-MITM on the rendezvous) but must NOT fetch a CA (there is none). The call site at line 654 stays as-is (in public mode `FLOO_OPERATOR_CA` is empty, so `bootstrap_from_relay` is invoked):

```bash
  if [ -n "$FLOO_RELAY_PIN" ] && [ -z "$FLOO_OPERATOR_CA" ] && [ -n "$FLOO_RELAY_HOST" ]; then bootstrap_from_relay; fi
```

Instead, make `bootstrap_from_relay` return early in public mode — after it has verified the pin and set `FLOO_RELAY_HOSTKEY`, but before the `opconfig` CA fetch. In `bootstrap_from_relay`, right after the line:

```bash
  FLOO_RELAY_HOSTKEY="ssh-ed25519 $blob"   # pin verified → trust this relay host key for the session
```

insert:

```bash
  if [ "$FLOO_PUBLIC" = 1 ]; then ok "relay verified (pin matches) — no-cert mode, no operator key to fetch."; return 0; fi
```

This way `floo --public --relay H --pin FP` pins the relay host key via the pin (so `build_endpoint`'s host-key requirement is satisfied and a relay-MITM is rejected) without fetching any CA. Passing `--relay-hostkey` directly, or `FLOO_ALLOW_TOFU=1`, also satisfies `build_endpoint` as today.

- [ ] **Step 2: base32 code generator in `pairing_code()`**

Replace `pairing_code()` (lines 277-281):

```bash
pairing_code() {
  # short human code the operator must read back to you; binds the relay record to THIS run
  PAIRCODE="$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n' | tr 'a-f' 'A-F')"
  PAIRCODE="${PAIRCODE:0:4}-${PAIRCODE:4:4}"
}
```

with a mode-aware version:

```bash
pairing_code() {
  if [ "$FLOO_PUBLIC" = 1 ]; then
    # NO-CERT MODE: the code IS the credential against an untrusted relay, so it must be high-entropy
    # (>=64 bits). 13 base32 chars ~= 65 bits; fall back to 16 hex (64 bits) where base32 is absent.
    local raw
    if command -v base32 >/dev/null 2>&1; then
      raw="$(head -c9 /dev/urandom | base32 | tr -dc 'A-Z2-7' | cut -c1-13)"
    else
      raw="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n' | tr 'a-f' 'A-F')"
    fi
    PAIRCODE="$(printf '%s' "$raw" | sed 's/.\{4\}/&-/g; s/-$//')"   # group every 4 chars
  else
    # CA MODE: the cert is the gate, so a short 32-bit pairing token is fine.
    PAIRCODE="$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n' | tr 'a-f' 'A-F')"
    PAIRCODE="${PAIRCODE:0:4}-${PAIRCODE:4:4}"
  fi
}
```

- [ ] **Step 3: No-CA throwaway sshd in `build_endpoint()`**

In `build_endpoint()`, the function currently (line 119) writes the operator CA at the very top, then later generates `SID` (line 132) and writes `principals`. Restructure so the auth artifacts are chosen by mode. Replace the top of `build_endpoint` (lines 118-119):

```bash
  mkdir -p "$WORKDIR/recording"
  printf '%s\n' "$FLOO_OPERATOR_CA" > "$WORKDIR/operator_ca.pub"
```

with just:

```bash
  mkdir -p "$WORKDIR/recording"
```

Then, after the `SID=…` and `printf '%s\n' "$SID" > "$WORKDIR/principals"` lines (line 132-133) and the `ssh-keygen … hostkey` line (134), insert the auth-artifact + sshd-auth-block selection:

```bash
  if [ "$FLOO_PUBLIC" = 1 ]; then
    : > "$WORKDIR/authorized_keys"; chmod 600 "$WORKDIR/authorized_keys"   # filled in by bind_watcher after HMAC-verify
    AUTH_BLOCK="PubkeyAuthentication yes
AuthenticationMethods publickey
AuthorizedKeysFile $WORKDIR/authorized_keys"
  else
    printf '%s\n' "$FLOO_OPERATOR_CA" > "$WORKDIR/operator_ca.pub"
    AUTH_BLOCK="PubkeyAuthentication yes
AuthenticationMethods publickey
TrustedUserCAKeys $WORKDIR/operator_ca.pub
AuthorizedPrincipalsFile $WORKDIR/principals
AuthorizedKeysFile /nonexistent"
  fi
```

Then in the `sshd_config` heredoc, replace these five lines:

```bash
PubkeyAuthentication yes
AuthenticationMethods publickey
TrustedUserCAKeys $WORKDIR/operator_ca.pub
AuthorizedPrincipalsFile $WORKDIR/principals
AuthorizedKeysFile /nonexistent
```

with the single placeholder:

```bash
$AUTH_BLOCK
```

(The surrounding hardening — `UsePAM no`, `PasswordAuthentication no`, `PermitRootLogin no`, `ForceCommand`, no-forwarding, etc. — is identical in both modes and stays as-is.)

- [ ] **Step 4: Register with the quick flag**

In `register_and_tunnel()`, change the register call (line 298):

```bash
  if ! relay_ssh register "$SID" "$(codehash "$PAIRCODE")" "$(id -un)" "$NAME" "$hostpub"; then
```

to normalize the code + pass `quick=1` in public mode:

```bash
  local qflag=""; [ "$FLOO_PUBLIC" = 1 ] && qflag="quick=1"
  if ! relay_ssh register "$SID" "$(codehash "$(norm "$PAIRCODE")")" "$(id -un)" "$NAME" $qflag "$hostpub"; then
```

(`$qflag` is unquoted so it vanishes when empty; in CA mode this is byte-identical to today's call. Using `norm` here matches the operator's `codehash "${code^^}"`.)

- [ ] **Step 5: The bind-watcher (public mode only) — poll getop, verify HMAC, authorize**

Add a new function after `monitor()` (after line 343):

```bash
# PUBLIC MODE: the operator binds an ephemeral key + a code-proof at the relay; we poll for binds,
# verify HMAC(code, opkey) == auth (only the code-holder can forge it), and authorize the FIRST that
# verifies — skipping inert griefer binds. sshd reads authorized_keys per-connection, so no reload.
bind_watcher() {
  local got line auth opkey calc authorized=0
  while kill -0 "$TUNNEL_PID" 2>/dev/null; do
    if [ "$authorized" = 0 ]; then
      got="$(relay_ssh getop "$SID" 2>/dev/null)" || { sleep 2; continue; }
      while IFS=' ' read -r auth opkey; do
        [ -n "$auth" ] && [ -n "$opkey" ] || continue
        calc="$(printf '%s' "$opkey" | openssl dgst -sha256 -hmac "$(norm "$PAIRCODE")" | awk '{print $NF}')"
        if [ "$calc" = "$auth" ]; then
          printf '%s\n' "$opkey" > "$WORKDIR/authorized_keys.tmp"; chmod 600 "$WORKDIR/authorized_keys.tmp"
          mv "$WORKDIR/authorized_keys.tmp" "$WORKDIR/authorized_keys"   # atomic swap; live per-connection
          ok "operator verified by the code — they can connect now."
          authorized=1; break
        fi
      done <<<"$got"
    fi
    sleep 2
  done
}
```

Note: `opkey` here is the full pubkey string (`ssh-ed25519 AAAA… op-<sid>`) — `read -r auth opkey` puts the first token in `auth` and the REST (spaces preserved) in `opkey`, exactly matching what the operator HMAC'd (`cat opkey.pub`).

- [ ] **Step 6: Launch the bind-watcher in `run_session()` for public mode**

In `run_session()`, where `monitor & MONITOR_PID=$!` is started (line 528), add the bind-watcher for public mode. Replace:

```bash
  monitor & MONITOR_PID=$!
```

with:

```bash
  monitor & MONITOR_PID=$!
  if [ "$FLOO_PUBLIC" = 1 ]; then bind_watcher & BINDWATCH_PID=$!; fi
```

Add `BINDWATCH_PID=""` to the global declaration line (line 114-115, the `WORKDIR=""; SSHD_PID=""; …` block). And in `teardown()` (after the `MONITOR_PID` kill, line 443), add:

```bash
  [ -n "${BINDWATCH_PID:-}" ] && kill "$BINDWATCH_PID" 2>/dev/null
```

- [ ] **Step 7: Tweak the user-facing copy for public mode (honesty)**

In `run_session()`, the block that prints "your box is now reachable… ONLY by the operator's published key" (lines 519-523) is CA-specific. Make it mode-aware. Replace:

```bash
  ok "your box is now reachable by the operator — and ONLY by the operator's published key."
  say ""
  say "  ${B}Read this code back to whoever is helping you:${X}   ${B}$PAIRCODE${X}"
  say "  ${D}They must repeat it before connecting. If their copy doesn't match, do NOT proceed —${X}"
  say "  ${D}it means someone else is trying to answer. Just close this window.${X}"
```

with:

```bash
  if [ "$FLOO_PUBLIC" = 1 ]; then
    ok "your box is reachable in NO-CERT mode — the code below is the ONLY thing that grants access."
    say ""
    say "  ${B}Give this code ONLY to the person you want to help you:${X}   ${B}$PAIRCODE${X}"
    say "  ${D}Anyone who learns this code can connect. It's long on purpose. Don't post it anywhere;${X}"
    say "  ${D}read it to one person you trust. Close this window the moment you're done.${X}"
  else
    ok "your box is now reachable by the operator — and ONLY by the operator's published key."
    say ""
    say "  ${B}Read this code back to whoever is helping you:${X}   ${B}$PAIRCODE${X}"
    say "  ${D}They must repeat it before connecting. If their copy doesn't match, do NOT proceed —${X}"
    say "  ${D}it means someone else is trying to answer. Just close this window.${X}"
  fi
```

- [ ] **Step 8: Update `usage()` to document `--public`**

In `usage()` (the embedded heredoc), add a line under the session usages:

```bash
  floo --public            open a NO-CERT session (code-only; any operator with the code, no CA)
```

- [ ] **Step 9: Syntax-check + smoke**

```bash
bash -n floo && echo OK
floo --help | grep -q -- --public && echo "help documents --public"
```
Expected: OK; help line present.

- [ ] **Step 10: Commit**

```bash
git add floo
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' \
  commit -m "floo: --public no-cert mode (base32 code, CA-less endpoint, HMAC bind-watcher)"
```

---

## Task 7: End-to-end quick loopback test

**Files:**
- Create: `test/quick-loopback.sh`
- Modify: `test/run-all.sh`

- [ ] **Step 1: Write `test/quick-loopback.sh`**

Model it on `test/loopback.sh` (same relay-sshd setup with `ptyrun.py`), but: enable allow-quick on the relay, run the client with `--public`, drive the operator with auto-detected quick connect, and assert a wrong-code operator is NOT authorized. Create `test/quick-loopback.sh`:

```bash
#!/usr/bin/env bash
# quick-loopback.sh — end-to-end proof of NO-CERT (quick) mode on one host, no root-CA needed.
# Stands up the relay with --allow-quick (marker), runs the real client with --public, and the real
# operator connect (auto-detected quick path). Asserts: the operator reaches the box with ONLY the
# code (ephemeral key bound by HMAC), a WRONG code never authorizes, and Ctrl-C still revokes.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \e[32mPASS\e[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \e[31mFAIL\e[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
note(){ printf '\e[2m  · %s\e[0m\n' "$1"; }

OPHOME="$HOME"
WORK="$(mktemp -d /dev/shm/floo-qlb.XXXX)"
THOME="$WORK/home"; SOCK="$WORK/sock"; RELAY="$WORK/relay"
RUN="/run/user/$(id -u)/floo-qlb-$$"
ALLOWQ="$WORK/allow_quick"; : > "$ALLOWQ"     # the --allow-quick marker, handed to the dispatcher via SetEnv
mkdir -p "$THOME/.ssh" "$RUN" "$SOCK" "$RELAY"; chmod 700 "$THOME/.ssh" "$RUN"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
ME="$(id -un)"
CLIENT_PID=""; RELAY_PID=""; PTYRUN_PID=""
HELPBIN="/usr/local/lib/floo-qlb-$$"

cleanup() {
  [ -n "$PTYRUN_PID" ] && kill -TERM "$PTYRUN_PID" 2>/dev/null
  [ -n "$CLIENT_PID" ] && { kill -INT "$CLIENT_PID" 2>/dev/null; kill -TERM "$CLIENT_PID" 2>/dev/null; }
  sleep 0.5
  [ -n "$RELAY_PID" ] && kill -TERM "-$RELAY_PID" 2>/dev/null
  pkill -f "$WORK" 2>/dev/null
  sudo rm -rf "$HELPBIN" 2>/dev/null
  rm -rf "$WORK" "$RUN" 2>/dev/null
  for f in "$HOME"/.ssh/floo.d/qbox.conf "$HOME"/.config/floo/sessions/qbox; do rm -rf "$f" 2>/dev/null; done
  sed -i '/127.0.0.1/d' "$HOME/.config/floo/relay_known_hosts" 2>/dev/null || true
}
trap cleanup EXIT
sudo install -d -m755 -o root -g root "$HELPBIN"
sudo install -m755 -o root -g root "$REPO/relay/floo-route" "$REPO/relay/floo-authkeys" "$HELPBIN/"

echo "=== floo QUICK (no-cert) loopback (port $PORT, user $ME) ==="

# ── relay with allow-quick wired in via SetEnv (the dispatcher reads FLOO_ALLOW_QUICK_FILE) ──
ssh-keygen -t ed25519 -f "$RELAY/hostkey" -N '' -q
cat > "$RELAY/sshd_config" <<CFG
Port $PORT
ListenAddress 127.0.0.1
HostKey $RELAY/hostkey
PidFile $RELAY/pid
LogLevel VERBOSE
UsePAM no
PasswordAuthentication no
AuthorizedKeysFile none
AuthorizedKeysCommand $HELPBIN/floo-authkeys %t %k
AuthorizedKeysCommandUser $ME
AllowUsers $ME
SetEnv FLOO_RELAY_SOCK_DIR=$SOCK FLOO_ALLOW_QUICK_FILE=$ALLOWQ
Match User $ME
    AllowTcpForwarding remote
    PermitListen none
    AllowStreamLocalForwarding remote
    StreamLocalBindUnlink yes
    PermitTTY no
    ForceCommand FLOO_RELAY_SOCK_DIR=$SOCK FLOO_ALLOW_QUICK_FILE=$ALLOWQ $HELPBIN/floo-route
CFG
/usr/sbin/sshd -t -f "$RELAY/sshd_config" || { echo "relay config invalid"; exit 1; }
setsid /usr/sbin/sshd -D -e -f "$RELAY/sshd_config" >"$RELAY/log" 2>&1 &
RELAY_PID=$!
sleep 0.6
kill -0 "$RELAY_PID" 2>/dev/null && ok "relay (allow-quick) is up on :$PORT" || { bad "relay did not start"; cat "$RELAY/log"; exit 1; }

# ── client in --public mode ──
PTYRUN_LOG="$WORK/client.log" PTYRUN_PIDFILE="$WORK/client.pid" \
  python3 "$REPO/test/ptyrun.py" \
    env -i HOME="$THOME" PATH="$PATH" XDG_RUNTIME_DIR="$RUN" TERM=xterm \
    FLOO_NAME=qbox FLOO_RELAY_HOST=127.0.0.1 FLOO_RELAY_PORT="$PORT" \
    FLOO_RELAY_USER="$ME" FLOO_RELAY_SOCK_DIR="$SOCK" \
    FLOO_RELAY_HOSTKEY="$(cat "$RELAY/hostkey.pub")" \
    bash "$REPO/floo" --public &
PTYRUN_PID=$!
for i in $(seq 1 30); do [ -s "$WORK/client.pid" ] && break; sleep 0.1; done
CLIENT_PID="$(cat "$WORK/client.pid" 2>/dev/null)"

for i in $(seq 1 50); do ls "$SOCK"/*.sock >/dev/null 2>&1 && ls "$SOCK"/*.meta >/dev/null 2>&1 && break; sleep 0.2; done
SID="$(sed -n 's/^sid=//p' "$SOCK"/*.meta 2>/dev/null | head -1)"
{ [ -n "$SID" ] && grep -q '^quick=1' "$SOCK/$SID.meta"; } && ok "client registered a quick session (sid ${SID:0:8}…)" || { bad "no quick registration"; cat "$WORK/client.log"; }

# the displayed code (base32, grouped) — long, uppercase, with dashes
CODE=""; for i in $(seq 1 50); do CODE="$(grep -oE '[A-Z2-7]{4}(-[A-Z2-7]{1,4})+' "$WORK/client.log" | head -1)"; [ -n "$CODE" ] && break; sleep 0.2; done
[ -n "$CODE" ] && [ "${#CODE}" -ge 14 ] && ok "client showed a high-entropy code ($CODE)" || bad "no/short public code shown"

# ── a WRONG code must NOT authorize (operator binds garbage; client never writes it) ──
if env -i HOME="$OPHOME" PATH="$PATH" FLOO_HOME="$OPHOME/.config/floo" \
    FLOO_RELAY_HOST=127.0.0.1 FLOO_RELAY_PORT="$PORT" FLOO_RELAY_USER="$ME" \
    "$REPO/bin/floo-powder" connect --confirm WRON-GCOD-EXXX-X --no-shell >"$WORK/wrong.log" 2>&1; then
  bad "operator connect with a WRONG code reported success"
else
  ok "operator connect with a wrong code fails to authorize"
fi

# ── the CORRECT code: operator auto-detects quick, binds an ephemeral key, gets in ──
env -i HOME="$OPHOME" PATH="$PATH" FLOO_HOME="$OPHOME/.config/floo" \
    FLOO_RELAY_HOST=127.0.0.1 FLOO_RELAY_PORT="$PORT" FLOO_RELAY_USER="$ME" \
    "$REPO/bin/floo-powder" connect --confirm "$CODE" --no-shell >"$WORK/connect.log" 2>&1 \
  && ok "operator connect (quick, code-bound ephemeral key) succeeded" \
  || { bad "operator quick connect failed"; cat "$WORK/connect.log"; }

OUT="$(env -i HOME="$OPHOME" PATH="$PATH" FLOO_HOME="$OPHOME/.config/floo" \
    FLOO_RELAY_HOST=127.0.0.1 FLOO_RELAY_PORT="$PORT" FLOO_RELAY_USER="$ME" \
    "$REPO/bin/floo-powder" exec qbox 2>"$WORK/exec.err" <<<'echo QMARK_$((6*7))' )"
grep -q 'QMARK_42' <<<"$OUT" && ok "operator ran a command over the no-cert pivot (HMAC-bound key)" \
  || { bad "exec over the quick pivot failed"; echo "$OUT"; cat "$WORK/exec.err"; tail -15 "$RUN"/floo/qbox/sshd.log 2>/dev/null; }

# ── Ctrl-C still revokes ──
note "delivering Ctrl-C to the public client…"
kill -TERM "$PTYRUN_PID" 2>/dev/null
for i in $(seq 1 50); do kill -0 "$CLIENT_PID" 2>/dev/null || break; sleep 0.2; done
kill -0 "$CLIENT_PID" 2>/dev/null && { bad "public client did not exit on Ctrl-C"; kill -KILL "$CLIENT_PID" 2>/dev/null; } || ok "public client exited on Ctrl-C (revoke ran)"
CLIENT_PID=""
for i in $(seq 1 15); do [ -S "$SOCK/$SID.sock" ] || break; sleep 0.2; done
[ -S "$SOCK/$SID.sock" ] && bad "relay socket still present after revoke" || ok "relay socket released (close = revoke)"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
```

Make it executable:

```bash
chmod +x test/quick-loopback.sh
```

- [ ] **Step 2: Run it (expect PASS)**

```bash
cd ~/projects/floo
bash test/quick-loopback.sh
```
Expected: `… 0 failed`. If the operator-connect step times out, check that `bind_watcher` is writing `authorized_keys` (inspect `$RUN/floo/qbox/authorized_keys` during a manual run) and that the HMAC strings match on both ends (casing).

- [ ] **Step 3: Wire it into `run-all.sh`**

In `test/run-all.sh`, after the loopback B block (line 19), add:

```bash
echo; echo "########## quick loopback: no-cert (code-only) session ##########"
bash "$DIR/quick-loopback.sh" || rc=1
```

- [ ] **Step 4: Run the whole suite**

```bash
bash test/run-all.sh
```
Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add test/quick-loopback.sh test/run-all.sh
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' \
  commit -m "test: end-to-end no-cert (quick) loopback + wire into run-all"
```

---

## Task 8: Version bump, CHANGELOG, README, final re-embed + full suite

**Files:**
- Modify: `VERSION`, `floo` (`FLOO_VERSION`), `bin/floo-powder` (`FLOO_VERSION`), `CHANGELOG.md`, `README.md`

- [ ] **Step 1: Bump versions to 0.4.0**

```bash
cd ~/projects/floo
printf '0.4.0\n' > VERSION
```

In `floo`, change `FLOO_VERSION="0.2.0"` → `FLOO_VERSION="0.4.0"`.
In `bin/floo-powder`, change `FLOO_VERSION="0.3.2"` → `FLOO_VERSION="0.4.0"`.

(Client and operator versions converge at 0.4.0 — they ship together for this feature.)

- [ ] **Step 2: CHANGELOG entry**

Prepend to `CHANGELOG.md` (after the `# Changelog` header line):

```markdown
## 0.4.0 — 2026-06-12
- **no-cert (quick) mode** — a client can open a code-only session that any operator takes with just the
  code, no operator CA. `floo --public` stands up a CA-less throwaway sshd (empty authorized_keys), shows a
  high-entropy base32 code, then polls the relay for the operator's ephemeral-key bind and authorizes the
  first whose `HMAC(code, opkey)` verifies. The code IS the credential against an untrusted relay → it's
  long (~65 bits). Strictly weaker than CA mode (a leaked code = access) and opt-in on every side.
- **operator auto-detects the mode**: `floo-powder connect <code>` resolves the session, reads its `quick`
  flag, and either mints a CA cert (CA mode) or binds an ephemeral key by code-proof (no-cert) — no new flag.
- **relay**: new `bindop`/`getop` verbs (store-all binds; the client filters by HMAC, so a junk bind can't
  squat a session); `register` carries an optional `quick=1`; opt-in via `install-relay.sh --allow-quick`
  (writes `/etc/floo/allow_quick`; default stays CA-only). New caps under allow-quick: max concurrent quick
  sessions (`FLOO_QUICK_MAX=20`) + a quick TTL (`FLOO_QUICK_TTL=1800s`). Per-IP throttling is the existing
  sshd `PerSourceMaxStartups`/`MaxAuthTries` + fail2ban (each register/bindop is a fresh gw handshake).
- The same relay serves both modes; routing (sid-keyed) is shared, only the auth binding differs.
```

- [ ] **Step 3: README — document `floo --public` + `--allow-quick`**

In `README.md`, add a short subsection after the existing client/operator usage describing no-cert mode: the `--allow-quick` relay flag, `floo --public` on the client, that the operator just runs `connect <code>` as usual, and the explicit weaker-trust caveat (leaked code = access; opt-in; CA mode stays default). Keep it to ~10 lines, matching the README's existing tone. (Open `README.md` and match its heading style; place it under the operator/relay section.)

- [ ] **Step 4: Final re-embed + full suite + syntax checks**

```bash
cd ~/projects/floo
scripts/embed.sh --check || scripts/embed.sh
bash -n floo && bash -n bin/floo-powder && bash -n relay/floo-route && bash -n relay/install-relay.sh && echo "ALL SYNTAX OK"
floo --version            # floo 0.4.0 …
bin/floo-powder --version # floo-powder 0.4.0 …
bash test/run-all.sh
```
Expected: `ALL SYNTAX OK`; both versions 0.4.0; `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add VERSION floo bin/floo-powder CHANGELOG.md README.md
git -c user.name='Vlad Gaevsky' -c user.email='kelstar95@gmail.com' \
  commit -m "v0.4.0: no-cert (quick) mode — version, CHANGELOG, README, re-embed"
```

---

## Final verification (after all tasks)

- [ ] Run the full suite once more: `bash test/run-all.sh` → `ALL TESTS PASSED`.
- [ ] `scripts/embed.sh --check` → in sync (embedded relay = canonical relay, quick-aware).
- [ ] `git log --oneline` shows the 0.4.0 series of commits, all authored as Vlad.
- [ ] **Do NOT push or tag yet** — surface the result to Vlad for review; pushing the public repo + the immutable `v0.4.0` tag is the outward, irreversible step and waits for his go.

---

## Notes / deferred (do not build here)

- No agents-deployed agent-side trigger for `floo --public` on a deployed box (downstream consumer concern).
- No dedicated public relay host stand-up (`floo.kelstar.me`) — `--allow-quick` makes any relay capable; standing one up is an ops decision.
- No client-identity gating of *who may open* a quick session (the caps + opt-in flag are the guardrail).
- Real-box multi-pair test on a live `--allow-quick` relay is a post-merge ops validation, not part of this plan's automated suite.
