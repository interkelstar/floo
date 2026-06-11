#!/usr/bin/env bash
# run-all.sh — every agents-support test. Needs passwordless sudo (for root-owned relay
# helper copies, mirroring production) and the operator CA (bin/agents-support ca-init).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

echo "########## unit: relay dispatcher + authkeys ##########"
bash "$DIR/unit/dispatcher.sh" || rc=1

echo; echo "########## loopback A: clean session (no surface change) ##########"
bash "$DIR/loopback.sh" || rc=1

echo; echo "########## loopback B: technician changes a surface (disclosure must fire) ##########"
ASX_INJECT_CHANGE=1 bash "$DIR/loopback.sh" || rc=1

echo; [ "$rc" = 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $rc
