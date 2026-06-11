#!/usr/bin/env bash
# Built & run in production by the Agents Deployed team — https://agents-deployed.com
# install-relay.sh — stand up the floo relay on the OPERATOR's box.
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
#   sudo FLOO_RELAY_PORT=2222 ./install-relay.sh   # alt port (testing / when 443 is taken)
#   sudo ./install-relay.sh --uninstall
set -euo pipefail

PORT="${FLOO_RELAY_PORT:-443}"
SOCKDIR="/run/floo"
ETC="/etc/floo"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }

# ── distro abstraction (Fedora/RHEL · Debian/Ubuntu · Arch · Alpine) ──────────────────────
pkg_install() {
  if   command -v dnf     >/dev/null; then dnf install -y "$@"
  elif command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y "$@"
  elif command -v pacman  >/dev/null; then pacman -Sy --noconfirm "$@"
  elif command -v apk     >/dev/null; then apk add "$@"
  else return 1; fi
}
SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
open_port() {
  if   command -v firewall-cmd >/dev/null; then firewall-cmd --permanent --add-port="$1/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1
  elif command -v ufw          >/dev/null; then ufw allow "$1/tcp" >/dev/null 2>&1
  elif command -v nft          >/dev/null; then nft add rule inet filter input tcp dport "$1" accept 2>/dev/null || true
  fi
}
close_port() {
  if   command -v firewall-cmd >/dev/null; then firewall-cmd --permanent --remove-port="$1/tcp" 2>/dev/null || true; firewall-cmd --reload >/dev/null 2>&1 || true
  elif command -v ufw          >/dev/null; then ufw delete allow "$1/tcp" >/dev/null 2>&1 || true
  fi
}
ensure_gw_user() {
  id gw >/dev/null 2>&1 && return 0
  if command -v useradd >/dev/null; then useradd --system --create-home --home-dir /var/lib/floo --shell /bin/bash gw
  else adduser -S -D -H -h /var/lib/floo -s /bin/sh gw 2>/dev/null || adduser --system --home /var/lib/floo gw 2>/dev/null; mkdir -p /var/lib/floo; fi
}
ensure_nc() {
  command -v nc >/dev/null && return 0
  if   command -v dnf     >/dev/null; then pkg_install nmap-ncat
  elif command -v apt-get >/dev/null; then pkg_install netcat-openbsd
  elif command -v pacman  >/dev/null; then pkg_install openbsd-netcat
  elif command -v apk     >/dev/null; then pkg_install netcat-openbsd
  fi
  command -v nc >/dev/null || { echo "FATAL: 'nc' (netcat) not found and could not be installed — install it and re-run; the relay needs it."; exit 1; }
}

uninstall() {
  local up; up="$(cat "$ETC/port" 2>/dev/null || echo "$PORT")"
  # complete removal — leave ZERO leftovers, so a box can be wiped/moved cleanly. The only thing
  # deliberately NOT touched is ~/.config/floo (the operator's keys = durable access).
  systemctl disable --now floo-relay.service 2>/dev/null || true
  rm -f /etc/systemd/system/floo-relay.service /etc/tmpfiles.d/floo.conf
  rm -f /usr/local/bin/floo-route /usr/local/bin/floo-authkeys
  rm -rf "$ETC" "$SOCKDIR"
  systemctl daemon-reload
  close_port "$up"
  rm -f /etc/fail2ban/jail.d/floo-relay.local 2>/dev/null && command -v fail2ban-client >/dev/null 2>&1 && systemctl reload fail2ban 2>/dev/null || true
  id gw >/dev/null 2>&1 && { userdel -r gw 2>/dev/null || userdel gw 2>/dev/null || true; }
  if command -v semanage >/dev/null 2>&1; then
    semanage port -d -t ssh_port_t -p tcp "$up" 2>/dev/null || true
  fi
  echo "relay fully uninstalled — service, helpers, $ETC, $SOCKDIR, the gw user, SELinux label, and the firewall"
  echo "opening are all removed. Your operator keys in ~/.config/floo are untouched."
  exit 0
}
[ "${1:-}" = "--uninstall" ] && uninstall

echo "==> gw service account"
ensure_gw_user
# useradd locks the password (!), and sshd refuses a login to a locked account ("account is
# locked") even for publickey. '*' = not locked, but no usable password (password login stays
# impossible, and PasswordAuthentication no blocks it anyway). Idempotent.
usermod -p '*' gw

echo "==> dispatcher + authkeys helper"
install -m 0755 "$SELF_DIR/floo-route"    /usr/local/bin/floo-route
install -m 0755 "$SELF_DIR/floo-authkeys" /usr/local/bin/floo-authkeys
# nc is REQUIRED: the route pivot execs it, and socket liveness is probed with it. Install it
# per-distro if absent; ensure_nc fails loudly if it still can't be provided.
ensure_nc

echo "==> socket dir ($SOCKDIR) via tmpfiles (recreated on every boot — nothing persists across reboot)"
echo "d $SOCKDIR 0755 gw gw -" > /etc/tmpfiles.d/floo.conf
systemd-tmpfiles --create /etc/tmpfiles.d/floo.conf

echo "==> relay sshd config + dedicated host key (isolated from the box's primary sshd)"
mkdir -p "$ETC"; chmod 755 "$ETC"; echo "$PORT" > "$ETC/port"
# Use the operator's pre-generated relay host key (its PUBLIC half is pinned in floo as
# FLOO_RELAY_HOSTKEY) so the deployed relay's identity matches what every client verifies — this
# closes a relay-MITM. Resolve it from the invoking user's config; if absent, generate a fresh one
# and print its pubkey so floo can be updated to match.
if [ ! -f "$ETC/relay_hostkey" ]; then
  SRC="${FLOO_RELAY_HOSTKEY_SRC:-}"
  [ -z "$SRC" ] && [ -n "${SUDO_USER:-}" ] && SRC="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.config/floo/relay_hostkey"
  if [ -n "$SRC" ] && [ -f "$SRC" ]; then
    install -m600 "$SRC" "$ETC/relay_hostkey"; install -m644 "$SRC.pub" "$ETC/relay_hostkey.pub" 2>/dev/null || true
    echo "   using the operator's pre-pinned relay host key ($SRC)"
  else
    ssh-keygen -t ed25519 -f "$ETC/relay_hostkey" -N '' -q -C "floo-relay-host"
    echo "   ! generated a FRESH relay host key — embed its pubkey in floo FLOO_RELAY_HOSTKEY:"
    cat "$ETC/relay_hostkey.pub"
  fi
fi
chmod 600 "$ETC/relay_hostkey"
cat > "$ETC/relay_sshd_config" <<CFG
# floo relay — isolated sshd instance. ONLY the gw account, ONLY forwarding.
Port $PORT
ListenAddress 0.0.0.0
ListenAddress ::
HostKey $ETC/relay_hostkey
PidFile /run/floo-relay.pid
LogLevel VERBOSE
# DoS hardening: cap concurrent unauthenticated handshakes (global + per source), short budgets
MaxStartups 10:50:60
PerSourceMaxStartups 4
PerSourceNetBlockSize 24
LoginGraceTime 15
MaxAuthTries 3
AllowUsers gw
PermitRootLogin no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
# accept any offered key (no shared secret to publish); the gw account is powerless anyway
AuthorizedKeysFile none
AuthorizedKeysCommand /usr/local/bin/floo-authkeys %t %k
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
    ForceCommand /usr/local/bin/floo-route
CFG
"$SSHD_BIN" -t -f "$ETC/relay_sshd_config" && echo "   sshd config OK"

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
cat > /etc/systemd/system/floo-relay.service <<UNIT
[Unit]
Description=floo relay (rendezvous sshd for client support sessions)
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/usr/bin/systemd-tmpfiles --create /etc/tmpfiles.d/floo.conf
ExecStart=$SSHD_BIN -D -e -f $ETC/relay_sshd_config
Restart=on-failure
RestartSec=3
# the dispatcher writes session metas as gw; sshd needs root to bind $PORT + privsep
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now floo-relay.service

echo "==> opening $PORT/tcp"
open_port "$PORT"

# ── DoS hardening: a fail2ban jail for the public gw endpoint (best-effort; cleanly removable) ──
if command -v fail2ban-client >/dev/null 2>&1 && [ -d /etc/fail2ban ]; then
  mkdir -p /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/floo-relay.local <<JAIL
[floo-relay]
enabled      = true
port         = $PORT
filter       = sshd
backend      = systemd
journalmatch = _SYSTEMD_UNIT=floo-relay.service
maxretry     = 5
findtime     = 60
bantime      = 600
JAIL
  systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true
  echo "==> fail2ban jail 'floo-relay' enabled on :$PORT"
fi

echo
echo "relay up on :$PORT — host key fingerprint (clients pin this via accept-new on first dial):"
ssh-keygen -lf "$ETC/relay_hostkey.pub"
systemctl --no-pager --full status floo-relay.service | sed -n '1,4p' || true
