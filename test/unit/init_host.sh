#!/usr/bin/env bash
# Unit tests for floo-powder cmd_init's use of ifconfig.me: the response is untrusted network
# input that becomes RELAY_HOST (written to relay.env, handed to sshd/print_oneliner) — it must be
# validated as a bare hostname/IP before use, and fetched over HTTPS.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OP="$REPO/bin/floo-powder"
P=0; F=0
ok(){ echo "  PASS $1"; P=$((P+1)); }
bad(){ echo "  FAIL $1"; F=$((F+1)); }

STUBDIR="$(mktemp -d)"
trap 'rm -rf "$STUBDIR"' EXIT

run_init() {   # $1 = the body curl should return
  local H; H="$(mktemp -d)"
  printf '%s' "$1" > "$STUBDIR/curl_body"
  cat > "$STUBDIR/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in https://ifconfig.me) cat "$(dirname "$0")/curl_body"; exit 0;; esac; done
exit 0
STUB
  chmod +x "$STUBDIR/curl"
  env HOME="$H" FLOO_HOME="$H/.config/floo" FLOO_INIT_NO_RELAY=1 PATH="$STUBDIR:$PATH" "$OP" init 2>&1
  rm -rf "$H"
}

echo "=== cmd_init: ifconfig.me response is validated before use ==="

out="$(run_init 'evil;rm -rf /' )"
grep -qi "doesn't look like a host" <<<"$out" && ok "junk with a shell metacharacter: dies naming the problem" || bad "junk host: $out"

out="$(run_init 'bad host with spaces')"
grep -qi "doesn't look like a host" <<<"$out" && ok "junk with spaces: dies" || bad "junk host (spaces): $out"

out="$(run_init 'evil"quoted')"
grep -qi "doesn't look like a host" <<<"$out" && ok "junk with a quote: dies" || bad "junk host (quote): $out"

out="$(run_init '203.0.113.7')"
grep -qi "doesn't look like a host" <<<"$out" && bad "clean IPv4 was rejected: $out" || ok "clean IPv4 (203.0.113.7): accepted"
grep -qF '203.0.113.7' <<<"$out" && ok "clean IPv4: used in the one-liner" || bad "clean IPv4 not reflected in output"

# curl is called against HTTPS, not plain HTTP
grep -q 'curl -fsS --max-time 5 https://ifconfig.me' "$OP" && ok "fetches ifconfig.me over HTTPS" || bad "still fetches ifconfig.me over plain HTTP"

echo; echo "$P passed, $F failed"; [ "$F" -eq 0 ]
