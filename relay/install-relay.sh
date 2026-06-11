#!/usr/bin/env bash
# install-relay.sh — stand up the agents-support relay on the OPERATOR's box.
#
# The relay is the switchboard: a dedicated, isolated sshd instance (does NOT touch the
# box's primary sshd) listening on 443, serving only a powerless `gw` account. It maps a
# botname to a client's live reverse socket and pivots bytes between the operator and the
# client's own encrypted SSH endpoint. It never sees session plaintext.
#
# Provisions (same spirit as the operator's other personal infra, e.g. the SearXNG podman
# container): a gw user, the dispatcher + authkeys helper, a tmpfiles entry for the socket
# dir, the relay sshd config + host key, a systemd unit, and a firewall opening for 443.
#
#   sudo ./install-relay.sh                 # install/refresh (default port 443)
#   sudo ASX_RELAY_PORT=2222 ./install-relay.sh   # alt port (testing / when 443 is taken)
#   sudo ./install-relay.sh --uninstall
set -euo pipefail

PORT="${ASX_RELAY_PORT:-443}"
SOCKDIR="/run/agents-support"
ETC="/etc/agents-support"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }

uninstall() {
  # complete removal — leave ZERO leftovers, so a box can be wiped/moved cleanly. The only thing
  # deliberately NOT touched is ~/.config/agents-support (the operator's keys = durable access).
  systemctl disable --now agents-support-relay.service 2>/dev/null || true
  rm -f /etc/systemd/system/agents-support-relay.service /etc/tmpfiles.d/agents-support.conf
  rm -f /usr/local/bin/agents-support-route /usr/local/bin/agents-support-authkeys
  rm -rf "$ETC" "$SOCKDIR"
  systemctl daemon-reload
  if command -v firewall-cmd >/dev/null; then
    for p in "${PORT}" 443; do firewall-cmd --permanent --remove-port="${p}/tcp" 2>/dev/null || true; done
    firewall-cmd --reload 2>/dev/null || true
  fi
  id gw >/dev/null 2>&1 && { userdel -r gw 2>/dev/null || userdel gw 2>/dev/null || true; }
  if command -v semanage >/dev/null 2>&1; then
    for p in "${PORT}" 443; do semanage port -d -t ssh_port_t -p tcp "$p" 2>/dev/null || true; done
  fi
  echo "relay fully uninstalled — service, helpers, $ETC, $SOCKDIR, the gw user, SELinux label, and the firewall"
  echo "opening are all removed. Your operator keys in ~/.config/agents-support are untouched."
  exit 0
}
[ "${1:-}" = "--uninstall" ] && uninstall

echo "==> gw service account"
id gw >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/agents-support --shell /bin/bash gw
# useradd locks the password (!), and sshd refuses a login to a locked account ("account is
# locked") even for publickey. '*' = not locked, but no usable password (password login stays
# impossible, and PasswordAuthentication no blocks it anyway). Idempotent.
usermod -p '*' gw

echo "==> dispatcher + authkeys helper"
install -m 0755 "$SELF_DIR/agents-support-route"    /usr/local/bin/agents-support-route
install -m 0755 "$SELF_DIR/agents-support-authkeys" /usr/local/bin/agents-support-authkeys
# nc is REQUIRED: the route pivot execs it, and socket liveness is probed with it. A missing nc
# would break routing, so fail loudly at install rather than silently at session time.
command -v nc >/dev/null || { echo "FATAL: 'nc' (nmap-ncat/netcat) not found — install it and re-run; the relay needs it."; exit 1; }

echo "==> socket dir ($SOCKDIR) via tmpfiles (recreated on every boot — nothing persists across reboot)"
echo "d $SOCKDIR 0755 gw gw -" > /etc/tmpfiles.d/agents-support.conf
systemd-tmpfiles --create /etc/tmpfiles.d/agents-support.conf

echo "==> relay sshd config + dedicated host key (isolated from the box's primary sshd)"
mkdir -p "$ETC"; chmod 755 "$ETC"
# Use the operator's pre-generated relay host key (its PUBLIC half is pinned in support.sh as
# ASX_RELAY_HOSTKEY) so the deployed relay's identity matches what every client verifies — this
# closes a relay-MITM. Resolve it from the invoking user's config; if absent, generate a fresh one
# and print its pubkey so support.sh can be updated to match.
if [ ! -f "$ETC/relay_hostkey" ]; then
  SRC="${ASX_RELAY_HOSTKEY_SRC:-}"
  [ -z "$SRC" ] && [ -n "${SUDO_USER:-}" ] && SRC="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.config/agents-support/relay_hostkey"
  if [ -n "$SRC" ] && [ -f "$SRC" ]; then
    install -m600 "$SRC" "$ETC/relay_hostkey"; install -m644 "$SRC.pub" "$ETC/relay_hostkey.pub" 2>/dev/null || true
    echo "   using the operator's pre-pinned relay host key ($SRC)"
  else
    ssh-keygen -t ed25519 -f "$ETC/relay_hostkey" -N '' -q -C "agents-support-relay-host"
    echo "   ! generated a FRESH relay host key — embed its pubkey in support.sh ASX_RELAY_HOSTKEY:"
    cat "$ETC/relay_hostkey.pub"
  fi
fi
chmod 600 "$ETC/relay_hostkey"
cat > "$ETC/relay_sshd_config" <<CFG
# agents-support relay — isolated sshd instance. ONLY the gw account, ONLY forwarding.
Port $PORT
ListenAddress 0.0.0.0
ListenAddress ::
HostKey $ETC/relay_hostkey
PidFile /run/agents-support-relay.pid
LogLevel VERBOSE
AllowUsers gw
PermitRootLogin no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
# accept any offered key (no shared secret to publish); the gw account is powerless anyway
AuthorizedKeysFile none
AuthorizedKeysCommand /usr/local/bin/agents-support-authkeys %t %k
AuthorizedKeysCommandUser nobody
X11Forwarding no
AllowAgentForwarding no
PermitTunnel no
ClientAliveInterval 30
ClientAliveCountMax 4
Match User gw
    # NOTE: 'AllowTcpForwarding no' is a master switch that ALSO disables the stream-local
    # forward we need (verified on OpenSSH 10.2). So we permit only the narrowest set:
    AllowTcpForwarding remote          # blocks -L (relay-as-jump to other hosts)
    PermitListen none                  # blocks -R TCP listeners (no opening ports on the relay)
    AllowStreamLocalForwarding remote  # allows ONLY the client's reverse unix socket
    StreamLocalBindUnlink yes
    PermitTTY no
    ForceCommand /usr/local/bin/agents-support-route
CFG
/usr/sbin/sshd -t -f "$ETC/relay_sshd_config" && echo "   sshd config OK"

# SELinux: under systemd the relay runs in the confined sshd_t domain, which may bind only the
# ssh port (22). Our port (443 = http_port_t by default) is refused with EACCES until we label it
# as an ssh port. Idempotent, and reverted by --uninstall, so a wiped box is left clean.
if command -v semanage >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != Disabled ]; then
  if ! semanage port -l 2>/dev/null | grep -qE "^ssh_port_t\b.*\b${PORT}\b"; then
    echo "==> SELinux: labeling tcp/$PORT as ssh_port_t"
    semanage port -a -t ssh_port_t -p tcp "$PORT" 2>/dev/null \
      || semanage port -m -t ssh_port_t -p tcp "$PORT" 2>/dev/null \
      || echo "   ! could not relabel tcp/$PORT — the relay may fail to bind under SELinux"
  fi
fi

echo "==> systemd unit"
cat > /etc/systemd/system/agents-support-relay.service <<UNIT
[Unit]
Description=agents-support relay (rendezvous sshd for client support sessions)
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/usr/bin/systemd-tmpfiles --create /etc/tmpfiles.d/agents-support.conf
ExecStart=/usr/sbin/sshd -D -e -f $ETC/relay_sshd_config
Restart=on-failure
RestartSec=3
# the dispatcher writes session metas as gw; sshd needs root to bind $PORT + privsep
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now agents-support-relay.service

if command -v firewall-cmd >/dev/null; then
  echo "==> opening $PORT/tcp"
  firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null && firewall-cmd --reload >/dev/null
fi

echo
echo "relay up on :$PORT — host key fingerprint (clients pin this via accept-new on first dial):"
ssh-keygen -lf "$ETC/relay_hostkey.pub"
systemctl --no-pager --full status agents-support-relay.service | sed -n '1,4p' || true
