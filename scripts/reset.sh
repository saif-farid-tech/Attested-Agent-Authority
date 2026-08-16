#!/usr/bin/env bash
# reset.sh — restore the workload VM to the post-build 'demo-ready' snapshot.
#
# Prerequisite: 70-baseline.sh took the snapshot.
# This undoes the tamper (the profile file returns to its measured state),
# so the next attestation passes and the verifier starts signing again.

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh
guard_host
need lxc "lxd (snap)"
instance_exists "$AAA_VM" || die "VM $AAA_VM missing" \
  "there is nothing to restore" "make build"
lxc info "$AAA_VM" | grep -q "$AAA_SNAPSHOT" || \
  die "snapshot $AAA_SNAPSHOT does not exist" \
      "it is taken by scripts/70-baseline.sh" "scripts/70-baseline.sh"

lxc restore "$AAA_VM" "$AAA_SNAPSHOT"
lxc start "$AAA_VM" 2>/dev/null || true
wait_vm_ready
ok "restored '$AAA_SNAPSHOT' — workload back to its measured, passing state"
