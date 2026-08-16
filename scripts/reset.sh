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
lxc_says "$AAA_SNAPSHOT" info "$AAA_VM" || \
  die "snapshot $AAA_SNAPSHOT does not exist" \
      "it is taken by scripts/70-baseline.sh" "scripts/70-baseline.sh"

# The tamper lives in the RUNTIME IMA measurement log (kernel memory), not on
# disk — only a genuine reboot clears it. Restoring a *running* VM rolls back
# the disk but leaves that tampered log live, so attestation keeps failing and
# the demo can't restart. Stop first, restore the disk, then cold-boot: the
# fresh boot regenerates the measurement log, which is what actually undoes the
# tamper and returns the workload to its measured, passing state.
log "stopping VM for a clean restore…"
lxc stop "$AAA_VM" --force 2>/dev/null || true
lxc restore "$AAA_VM" "$AAA_SNAPSHOT"
log "cold-booting from the snapshot (regenerates the IMA log)…"
lxc start "$AAA_VM" 2>/dev/null || true
wait_vm_ready

# Verify the restore actually produced a clean, passing state — reading it back
# is the only proof. A snapshot restore that didn't reboot would silently leave
# the tamper in place, and that is the whole bug this guard exists to catch.
if lxc exec "$AAA_VM" -- sh -c 'grep -q "harden self-modification" /etc/apparmor.d/harden' 2>/dev/null; then
  die "the tamper line is still in the profile after restore" \
      "the snapshot predates a clean baseline, or the restore did not take" \
      "make build   # retake the demo-ready snapshot from a clean baseline"
fi
ok "restored '$AAA_SNAPSHOT' via cold boot — workload back to its measured, passing state"
ok "attestation will pass within one cycle; the verifier resumes funding the agent"
