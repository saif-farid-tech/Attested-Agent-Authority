#!/usr/bin/env bash
# 00-preflight.sh — validate the host. Changes nothing.
#
# Exits non-zero with a numbered list of what to fix. Every later script
# assumes preflight has passed.

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh
source scripts/lib/detect.sh
guard_host

problems=()
check() {  # check DESCRIPTION TEST... — record a numbered problem on failure
  local desc=$1 fix=$2; shift 2
  if "$@" >/dev/null 2>&1; then ok "$desc"
  else problems+=("$desc — fix: $fix"); warn "$desc"; fi
}

log "preflight: read-only checks, nothing will be modified"

check "lxd: 'lxc' command on PATH" \
      "sudo snap install lxd" \
      command -v lxc
check "lxd: daemon initialised and reachable" \
      "sudo lxd init --minimal" \
      lxc query /1.0
check "lxd: 'tpm_device' API extension (vTPM support)" \
      "sudo snap refresh lxd  # needs LXD >= 4.4" \
      detect_lxd_ext tpm_device
check "kvm: /dev/kvm present (VMs need hardware virtualisation)" \
      "enable VT-x/AMD-V in firmware; check 'kvm-ok' from cpu-checker" \
      test -e /dev/kvm
check "tpm2-tools: 'tpm2_checkquote' on PATH (verifier side)" \
      "sudo apt install tpm2-tools" \
      command -v tpm2_checkquote
check "gpg: a usable secret key for signing the allowlist" \
      "gpg --quick-generate-key 'attested-agent (allowlist signing)'" \
      sh -c 'gpg --list-secret-keys --with-colons 2>/dev/null | grep -q ^sec'
check "ssh-keygen: on PATH (SSH CA and certificates)" \
      "sudo apt install openssh-client" \
      command -v ssh-keygen
check "python3: on PATH (verifier and diagnostic run on the host)" \
      "sudo apt install python3" \
      command -v python3
ram_ok()  { [ "$(detect_free_ram_mb)" -ge 6144 ]; }
disk_ok() { [ "$(detect_free_disk_gb)" -ge 25 ]; }
check "ram: at least 6 GB available (VM gets 4 GB)" \
      "close applications, or add swap" \
      ram_ok
check "disk: at least 25 GB free on /" \
      "free space; the VM image and snapshot need ~20 GB" \
      disk_ok

if detect_host_tpm; then
  ok "host tpm: /dev/tpm0 present (informational — the demo uses the VM's vTPM)"
else
  warn "host tpm: none found (fine — the demo attests the VM's vTPM, but note LIMITS.md)"
fi

echo
if [ ${#problems[@]} -eq 0 ]; then
  ok "preflight passed — next: scripts/10-network.sh (or just 'make build')"
else
  echo "preflight found ${#problems[@]} problem(s):" >&2
  i=0
  for p in "${problems[@]}"; do i=$((i+1)); printf '  %d. %s\n' "$i" "$p" >&2; done
  exit 1
fi
