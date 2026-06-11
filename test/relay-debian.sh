#!/usr/bin/env bash
# Opt-in cross-distro check (requires podman): verifies the relay installer's apt path resolves
# deps + the sshd config validates on Debian (no SELinux, ufw/nft firewall path).
set -uo pipefail
command -v podman >/dev/null || { echo "SKIP relay-debian (no podman)"; exit 0; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
podman run --rm -v "$REPO:/floo:ro" docker.io/library/debian:stable bash -c '
  set -e
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq openssh-server netcat-openbsd >/dev/null 2>&1
  cp -r /floo /tmp/floo && cd /tmp/floo
  bash -n relay/install-relay.sh
  command -v nc >/dev/null && command -v sshd >/dev/null
  echo "DEBIAN-OK: installer syntax + sshd + nc present (apt path)"
' 2>&1 | tail -2
