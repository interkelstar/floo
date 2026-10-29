#!/usr/bin/env bash
# Static unit test: on SELinux hosts relay/install-relay.sh labels the socket dir so sshd can
# create the client's reverse socket there. Without it /run/floo stays var_run_t and every session
# fails with "unix_listener: cannot bind to path /run/floo/<sid>.sock: Permission denied"
# (2026-10-29, public relay: avc denied { create } sshd_session_t -> var_run_t sock_file).
# INSTALLER may be overridden to prove the test red on an older installer.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="${INSTALLER:-$REPO/relay/install-relay.sh}"
P=0; F=0
ok(){ printf '  \e[32mPASS\e[0m %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  \e[31mFAIL\e[0m %s\n' "$1"; F=$((F+1)); }

echo "=== install-relay.sh: SELinux label for the socket dir ==="
# shellcheck disable=SC2016  # literal $SOCKDIR is what the installer source contains
grep -qF 'semanage fcontext -a -t user_tmp_t "$SOCKDIR(/.*)?"' "$INSTALLER" \
  && ok "adds an fcontext rule labelling \$SOCKDIR user_tmp_t" \
  || bad "no 'semanage fcontext -a -t user_tmp_t \"\$SOCKDIR(/.*)?\"' in the installer"
# shellcheck disable=SC2016
grep -qF 'semanage fcontext -m -t user_tmp_t "$SOCKDIR(/.*)?"' "$INSTALLER" \
  && ok "falls back to -m when the rule already exists (idempotent re-run)" \
  || bad "no -m fallback for an existing fcontext rule"
# shellcheck disable=SC2016
grep -qF 'restorecon -R "$SOCKDIR"' "$INSTALLER" \
  && ok "relabels the existing dir with restorecon" \
  || bad "no restorecon -R \"\$SOCKDIR\" after the fcontext rule"
# shellcheck disable=SC2016
grep -qF 'semanage fcontext -d "$SOCKDIR(/.*)?"' "$INSTALLER" \
  && ok "--uninstall removes the fcontext rule" \
  || bad "--uninstall leaves the fcontext rule behind"
# the label must not be gated behind 'Enforcing' only: a Permissive box flipped to Enforcing later
# would break, so it rides the same 'semanage present and SELinux not Disabled' branch as the port.
awk '/^if command -v semanage .*"\$SE" != Disabled/{b=1} b&&/semanage fcontext -a/{print "in"; exit} b&&/^fi$/{exit}' "$INSTALLER" | grep -q in \
  && ok "fcontext rule lives in the semanage block (Enforcing and Permissive)" \
  || bad "fcontext rule is not inside the 'semanage present, SELinux not Disabled' block"

echo; echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ]
