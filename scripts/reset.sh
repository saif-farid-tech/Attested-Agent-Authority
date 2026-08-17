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
lxc stop "$AAA_VM" >/dev/null 2>&1 || lxc stop "$AAA_VM" --force >/dev/null 2>&1 || true
lxc restore "$AAA_VM" "$AAA_SNAPSHOT"
log "cold-booting from the snapshot (regenerates the IMA log)…"
lxc start "$AAA_VM" >/dev/null 2>&1 || true
wait_vm_settled

# The fleet is not part of the VM snapshot: a host reboot leaves those three
# containers stopped, and the demo would then fail three acts later with the
# agent apparently unable to work (bug #16).
ensure_fleet_up

# Narration from a previous run must not leak into the next one's console.
clear_console_events

# Verify the restore actually produced a clean, passing state — reading it back
# is the only proof. A snapshot restore that didn't reboot would silently leave
# the tamper in place, and that is the whole bug this guard exists to catch.
if lxc exec "$AAA_VM" -- sh -c 'grep -q "harden self-modification" /etc/apparmor.d/harden' 2>/dev/null; then
  die "the tamper line is still in the profile after restore" \
      "the snapshot predates a clean baseline, or the restore did not take" \
      "make build   # retake the demo-ready snapshot from a clean baseline"
fi

# The premise of the next run: the agent must be able to write its own
# constraint. Cheap to check here, expensive to discover during ACT 5.
lxc exec "$AAA_VM" -- sh -c 'sudo -u harden test -w /etc/apparmor.d/harden' 2>/dev/null || \
  die "the harden user cannot write /etc/apparmor.d/harden" \
      "ACT 5 of the demo depends on that write succeeding" \
      "scripts/40-apparmor.sh && make rebaseline"

ok "restored '$AAA_SNAPSHOT' via cold boot — workload back to its measured, passing state"
ok "attestation will pass within one cycle; the verifier resumes funding the agent"
