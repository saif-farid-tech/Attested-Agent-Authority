#!/usr/bin/env bash
# 70-baseline.sh — exercise the agent, freeze the measured state into a
# signed allowlist, prove one full attestation, snapshot as demo-ready.
#
# Prerequisites: 30-tpm-keys.sh, 40-apparmor.sh, 50-agent.sh, 60-fleet.sh.
# Re-runnable at any time: this IS `make rebaseline` (bug #10 — editing the
# agent changes its IMA hash, so the allowlist must be regenerated after).

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh
source scripts/lib/detect.sh
guard_host
need lxc "lxd (snap)"
need gpg gnupg
require_script "$AAA_STATE/ak.pub"  scripts/30-tpm-keys.sh
require_script "$AAA_STATE/ssh_ca" scripts/60-fleet.sh
wait_vm_ready

# ---- make fleet names resolvable inside the VM -----------------------------
for host in "${AAA_FLEET[@]}"; do
  addr=$(detect_fleet_addr "$host")
  [ -n "$addr" ] || die "$host has no address" "fleet not up" "scripts/60-fleet.sh"
  vm_exec sh -c "grep -q ' $host\$' /etc/hosts || echo '$addr $host' >> /etc/hosts"
done
ok "fleet names resolvable inside the VM"

# ---- run the agent once so everything it touches gets measured -------------
# No certificate exists yet, so the pass reports NO AUTHORITY on every host —
# expected. What matters is that python, agent.py, config.json and the ssh
# client are all read/executed and therefore land in the IMA log.
vm_exec --user harden python3 "$AAA_VM_STATE/agent.py" || true
vm_exec apparmor_parser -r /etc/apparmor.d/harden   # ensure the profile is in the log too
ok "agent exercised; its dependencies are now in the IMA measurement log"

# ---- generate the allowlist (bug #5) ---------------------------------------
# IMA writes 'sha256:<hash>'; tpm2-tools and our verifier compare bare
# hashes. If the prefix is not stripped, NOTHING ever matches and every
# measurement reads as a violation. This helper regenerates it from the log.
regen_allowlist() {
  vm_exec sh -c \
    "awk '{split(\$4,h,\":\"); print h[2], \$5}' /sys/kernel/security/ima/ascii_runtime_measurements" \
    | sort -u > "$AAA_STATE/allowlist.txt"
}

# A provisional allowlist so the warm-up attestation below can run at all
# (its stage 1 refuses an empty allowlist).
regen_allowlist
[ -s "$AAA_STATE/allowlist.txt" ] || die "allowlist is empty" \
    "the IMA log produced no entries" \
    "lxc exec $AAA_VM -- head /sys/kernel/security/ima/ascii_runtime_measurements"

# Warm-up: run one full attestation and DISCARD the result. Its only job is to
# make the kernel measure the verifier's own read footprint — the attest login
# session, sudo, tpm2_quote and their libraries — so those land in the log
# before we freeze the allowlist. Without this, the first real attestation
# reads a few files that were not yet measured and flags them as violations.
log "warm-up attestation (captures the verifier's own footprint; result ignored)…"
python3 verifier/attest-once.py >/dev/null 2>&1 || true

# Now freeze the allowlist, footprint included.
regen_allowlist
entries=$(wc -l < "$AAA_STATE/allowlist.txt")
[ "$entries" -gt 0 ] || die "allowlist is empty after warm-up" \
    "unexpected — the IMA log emptied" \
    "lxc exec $AAA_VM -- head /sys/kernel/security/ima/ascii_runtime_measurements"
if [ "$entries" -gt 2000 ]; then
  warn "$entries allowlist entries — larger than the reference (~650–1100), but "
  warn "the broad FILE_CHECK policy explains it; attestation still works. See CORRECTIONS.md #3."
fi
ok "allowlist frozen: $entries entries"

# ---- sign it ---------------------------------------------------------------
gpg --yes --batch --armor --detach-sign \
    --output "$AAA_STATE/allowlist.txt.asc" "$AAA_STATE/allowlist.txt"
gpg --verify "$AAA_STATE/allowlist.txt.asc" "$AAA_STATE/allowlist.txt" 2>/dev/null || \
  die "allowlist signature does not verify" "gpg signing failed" \
      "gpg --list-secret-keys  # confirm a secret key exists, then re-run"
ok "allowlist signed: $AAA_STATE/allowlist.txt.asc"

# ---- prove one full attestation, then freeze -------------------------------
if python3 verifier/attest-once.py; then
  ok "full attestation cycle passed"
else
  rc=$?
  die "attestation did not pass (rc=$rc)" \
      "the baseline itself does not verify" \
      "python3 verifier/attest-once.py  # the diagnostic names the failing stage"
fi

lxc snapshot "$AAA_VM" "$AAA_SNAPSHOT" --reuse 2>/dev/null || {
  lxc delete "$AAA_VM/$AAA_SNAPSHOT" 2>/dev/null || true
  lxc snapshot "$AAA_VM" "$AAA_SNAPSHOT"
}
lxc_says "$AAA_SNAPSHOT" info "$AAA_VM" || \
  die "snapshot $AAA_SNAPSHOT missing" "lxc snapshot failed" \
      "lxc snapshot $AAA_VM $AAA_SNAPSHOT"
ok "snapshot '$AAA_SNAPSHOT' taken — 'make demo' can now replay in ~30 s"
ok "baseline complete — next: make verify, make console, make demo"
