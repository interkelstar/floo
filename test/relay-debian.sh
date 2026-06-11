#!/usr/bin/env bash
# Opt-in cross-distro check (requires podman): on Debian (no SELinux, apt, ufw/nft) verify the
# relay installer's deps resolve and the script + dispatcher syntax-check. Pipes the repo in via
# tar to avoid SELinux-labeled bind mounts.
set -uo pipefail
command -v podman >/dev/null || { echo "SKIP relay-debian (no podman)"; exit 0; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tar --exclude=.git -C "$REPO" -cf - . | podman run --rm -i docker.io/library/debian:stable bash -c '
  set -e
  mkdir -p /tmp/floo && tar -C /tmp/floo -xf - && cd /tmp/floo
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq openssh-server netcat-openbsd >/dev/null 2>&1
  bash -n relay/install-relay.sh && bash -n relay/floo-route && bash -n relay/floo-authkeys
  command -v nc >/dev/null && command -v sshd >/dev/null
  echo "DEBIAN-OK: installer + dispatcher syntax valid; sshd + nc present via apt"
' 2>&1 | tail -2
