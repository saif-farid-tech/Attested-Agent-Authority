#!/usr/bin/env bash
# 70-baseline.sh — freeze the measured state into a signed allowlist, calibrate
# what legitimately varies, prove one full attestation, snapshot as demo-ready.
#
# Prerequisites: 30-tpm-keys.sh, 40-apparmor.sh, 50-agent.sh, 60-fleet.sh.
# Re-runnable at any time: this IS `make rebaseline` (bug #10 — editing the
# agent changes its IMA hash, so the allowlist must be regenerated after).
#
# Why this script reboots the VM three times
# ------------------------------------------
# The allowlist has to describe the state the demo RESTORES INTO, which is a
# cold boot from the snapshot. Freezing it from a warm, freshly-provisioned
# boot described a different machine: every later restart measured files this
# one never had, and attestation failed for reasons that had nothing to do
# with the agent. So: boot twice, attest twice, and let the differences
# between those identical runs teach us which paths are genuinely volatile
# (bug #15). Then snapshot from a stopped VM so the restore is filesystem
# consistent rather than crash consistent (bug #21) — and measure the boot
# that comes up FROM that snapshot, because that, not the build, is the
# machine the demo runs on (bug #30).

cd "$(dirname "$0")/.." || exit 1
. scripts/lib/common.sh
. scripts/lib/detect.sh
guard_host
need lxc "lxd (snap)"
need gpg gnupg
need python3 python3
require_script "$AAA_STATE/ak.pub"  scripts/30-tpm-keys.sh
require_script "$AAA_STATE/ssh_ca" scripts/60-fleet.sh
ensure_fleet_up
wait_vm_settled

CAL=$(mktemp -d)
trap 'rm -rf "$CAL"' EXIT

capture_log() {  # capture_log DEST — the VM's current IMA measurement log
  vm_exec sh -c 'cat /sys/kernel/security/ima/ascii_runtime_measurements' > "$1"
  [ -s "$1" ] || die "the IMA measurement log is empty" \
      "the policy did not load at boot" \
      "lxc exec $AAA_VM -- journalctl -b | grep -i ima"
}

sign_file() {  # sign_file PATH — detached-sign and prove the signature verifies
  gpg --yes --batch --armor --detach-sign --output "$1.asc" "$1"
  gpg --verify "$1.asc" "$1" 2>/dev/null || \
    die "signature for $(basename "$1") does not verify" "gpg signing failed" \
        "gpg --list-secret-keys  # confirm a secret key exists, then re-run"
}

# ---- make fleet names resolvable inside the VM -----------------------------
# Rewritten rather than appended-to: an entry left over from an earlier build
# would otherwise keep pointing the agent at an address nothing answers on.
# This happens BEFORE the calibration boots so the final content is what gets
# measured on both of them.
for host in "${AAA_FLEET[@]}"; do
  addr=$(detect_fleet_addr "$host")
  [ -n "$addr" ] || die "$host has no address" "fleet not up" "scripts/60-fleet.sh"
  vm_exec sh -c "sed -i '/[[:space:]]$host\$/d' /etc/hosts && echo '$addr $host' >> /etc/hosts"
done
ok "fleet names resolvable inside the VM (${AAA_FLEET[*]})"

# ---- never baseline a tampered profile -------------------------------------
# If a previous demo was interrupted between the tamper and its restore, the
# profile still carries a self-modification line. Baselining that would freeze
# the TAMPERED constraint into the allowlist and the snapshot — corrupting the
# clean state forever. Strip any such line so the baseline is always pristine.
if vm_exec sh -c 'grep -q "# harden self-modification" /etc/apparmor.d/harden' 2>/dev/null; then
  warn "profile carried a leftover tamper line — stripping it before baselining"
  vm_exec sh -c 'sed -i "/# harden self-modification/d" /etc/apparmor.d/harden'
  vm_exec apparmor_parser -r /etc/apparmor.d/harden
fi

# ---- calibration: two identical cold boots ---------------------------------
log "calibration 1/2: cold-booting the VM (this is what 'make demo' restores into)…"
cold_boot_vm
capture_log "$CAL/boot-a.log"
log "calibration 2/2: cold-booting again to see which paths move…"
cold_boot_vm
capture_log "$CAL/boot-b.log"
ok "captured two cold-boot measurement logs"

# ---- run the agent once so everything it touches gets measured -------------
# No certificate exists yet, so the pass reports NO AUTHORITY on every host —
# expected. What matters is that python, agent.py, config.json and the ssh
# client are all read/executed and therefore land in the IMA log.
vm_exec --user harden python3 "$AAA_VM_STATE/agent.py" || true
vm_exec apparmor_parser -r /etc/apparmor.d/harden   # ensure the profile is in the log too
ok "agent exercised; its dependencies are now in the IMA measurement log"

# ---- provisional allowlist so the warm-up attestations can run at all ------
# (stage 1 refuses an empty allowlist, and now also refuses an unsigned one.)
freeze() {  # freeze — regenerate allowlist + volatile list from every log captured
  python3 verifier/imalog.py allowlist "$AAA_STATE/allowlist.txt" "$CAL"/*.log
  python3 verifier/imalog.py volatile  "$AAA_STATE/volatile-paths.txt" "$CAL"/*.log
  sign_file "$AAA_STATE/allowlist.txt"
  sign_file "$AAA_STATE/volatile-paths.txt"
}
capture_log "$CAL/agent-run.log"
freeze

# ---- calibration: two consecutive attestations -----------------------------
# Some files only move when the verifier logs in — lastlog, wtmp, the journal.
# Two real cycles expose them; their results are discarded. Without this, the
# FIRST attestation passed and the second failed, every time.
log "calibration: warm-up attestation 1/2 (result ignored)…"
python3 verifier/attest-once.py >/dev/null 2>&1 || true
capture_log "$CAL/attest-a.log"
log "calibration: warm-up attestation 2/2 (result ignored)…"
python3 verifier/attest-once.py >/dev/null 2>&1 || true
capture_log "$CAL/attest-b.log"

# ---- freeze, for real ------------------------------------------------------
freeze
entries=$(wc -l < "$AAA_STATE/allowlist.txt")
volatile=$(grep -cv '^#' "$AAA_STATE/volatile-paths.txt" || true)
[ "$entries" -gt 0 ] || die "allowlist is empty after calibration" \
    "the IMA log produced no entries" \
    "lxc exec $AAA_VM -- head /sys/kernel/security/ima/ascii_runtime_measurements"
if [ "$entries" -gt 2000 ]; then
  warn "$entries allowlist entries — larger than the reference (~650–1100), but "
  warn "the broad FILE_CHECK policy explains it; attestation still works. See CORRECTIONS.md #3."
fi
ok "allowlist frozen and signed: $entries entries (provisional — the snapshot's own boot is still to come)"
ok "volatile paths calibrated and signed: ${volatile:-0} entr(y/ies) that legitimately vary"

# ---- snapshot from a stopped VM (bug #21) ----------------------------------
# A snapshot of a RUNNING VM is crash-consistent: the restore replays an ext4
# journal, cloud-init may redo work, and the measurements shift a little each
# time — the classic "works, then doesn't". Stopping first makes the restore
# byte-identical on every run.
log "stopping the VM to take a filesystem-consistent snapshot…"
lxc stop "$AAA_VM" >/dev/null 2>&1 || lxc stop "$AAA_VM" --force >/dev/null 2>&1 || true
lxc snapshot "$AAA_VM" "$AAA_SNAPSHOT" --reuse 2>/dev/null || {
  lxc delete "$AAA_VM/$AAA_SNAPSHOT" 2>/dev/null || true
  lxc snapshot "$AAA_VM" "$AAA_SNAPSHOT"
}
lxc_says "$AAA_SNAPSHOT" info "$AAA_VM" || \
  die "snapshot $AAA_SNAPSHOT missing" "lxc snapshot failed" \
      "lxc snapshot $AAA_VM $AAA_SNAPSHOT"
lxc start "$AAA_VM" >/dev/null 2>&1 || true
wait_vm_settled
ok "snapshot '$AAA_SNAPSHOT' taken with the VM stopped"

# ---- measure the boot the demo actually starts in (bug #30) ----------------
# Everything above describes the machine we BUILT. The demo never runs there:
# it runs in a cold boot FROM THE SNAPSHOT, which is what just came up. That
# boot reads files the build boots never had — journald opens a new segment,
# dmesg rotates — so freeze once more with this log included. The snapshot is
# already taken and does not change; only the inventory that describes it does.
capture_log "$CAL/snapshot-boot.log"
freeze
entries=$(wc -l < "$AAA_STATE/allowlist.txt")
volatile=$(grep -cv '^#' "$AAA_STATE/volatile-paths.txt" || true)
ok "allowlist re-frozen including the snapshot's own boot: $entries entries"
ok "volatile list: ${volatile:-0} entr(y/ies) — paths that move, and globs for"
ok "               directories whose filenames are generated at run time"

# Anything PROTECTED that moved is reported, never silently excused: the
# agent's constraint and its code are in that set, and a change there is
# exactly what this project exists to catch. Checked over every log captured,
# the snapshot's boot included.
moved=$(mktemp)
python3 verifier/imalog.py protected-moved "$moved" "$CAL"/*.log
if [ -s "$moved" ]; then
  warn "these protected paths changed DURING the baseline — they are NOT excused:"
  sed 's/^/        /' "$moved" >&2
  warn "if that was you editing the agent, re-run: scripts/50-agent.sh && make rebaseline"
fi
rm -f "$moved"

# ---- prove attestation from the exact state the demo starts in -------------
# This runs AFTER the snapshot on purpose: the thing that must verify is the
# state 'make demo' and 'make reset' restore into, not the state we happened
# to have while building it.
if python3 verifier/attest-once.py; then
  ok "full attestation cycle passed — from a cold boot of the demo-ready snapshot"
else
  rc=$?
  die "attestation did not pass (rc=$rc)" \
      "the baseline itself does not verify" \
      "python3 verifier/attest-once.py  # the diagnostic names the failing stage"
fi
ok "baseline complete — next: make verify, make console, make demo"
