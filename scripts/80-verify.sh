#!/usr/bin/env bash
# 80-verify.sh — wrapper around the six-stage diagnostic.
#
# Exit codes pass straight through:
#   0 full pass · 2 attestation failure (the system working) · 1 setup failure

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh
guard_host
need python3 python3

log "running the six-stage diagnostic against $AAA_VM_ADDR"
rc=0
python3 verifier/attest-once.py || rc=$?
case $rc in
  0) ok "attestation PASSED" ;;
  2) warn "attestation FAILED — if you just ran the demo, this is the point" ;;
  *) warn "setup failure — the diagnostic printed the stage and the fix" ;;
esac
exit $rc
