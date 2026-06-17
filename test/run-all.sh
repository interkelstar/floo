#!/usr/bin/env bash
# run-all.sh — every floo test. Needs passwordless sudo (for root-owned relay
# helper copies, mirroring production) and the operator CA (bin/floo-powder ca-init).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

echo "########## unit: relay dispatcher + authkeys ##########"
bash "$DIR/unit/dispatcher.sh" || rc=1
  bash "$DIR/unit/identity.sh" || rc=1
  bash "$DIR/unit/config.sh" || rc=1
  bash "$DIR/unit/init.sh" || rc=1
  bash "$DIR/unit/embed.sh" || rc=1
  bash "$DIR/unit/render.sh" || rc=1
  bash "$DIR/unit/recorder.sh" || rc=1
  bash "$DIR/unit/console.sh" || rc=1

echo; echo "########## loopback A: clean session (no surface change) ##########"
bash "$DIR/loopback.sh" || rc=1

echo; echo "########## loopback B: technician changes a surface (disclosure must fire) ##########"
FLOO_INJECT_CHANGE=1 bash "$DIR/loopback.sh" || rc=1

echo; echo "########## quick loopback: no-cert (code-only) session ##########"
bash "$DIR/quick-loopback.sh" || rc=1

echo; [ "$rc" = 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $rc
