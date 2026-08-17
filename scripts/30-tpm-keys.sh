#!/usr/bin/env bash
# 30-tpm-keys.sh — create EK/AK inside the VM's TPM, export the AK public
# key to the host, and prove the whole chain with one verified quote.
#
# Prerequisite: 20-workload.sh (VM running with a vTPM).
#
# This script ends at the project's hard milestone: tpm2_checkquote on the
# HOST verifying a quote produced INSIDE the VM. Everything after is plumbing.

cd "$(dirname "$0")/.." || exit 1
. scripts/lib/common.sh
. scripts/lib/detect.sh
guard_host
need lxc "lxd (snap)"
need tpm2_checkquote tpm2-tools
instance_exists "$AAA_VM" || die "VM $AAA_VM missing" \
  "it is created by scripts/20-workload.sh" "scripts/20-workload.sh"
wait_vm_ready
mkdir -p "$AAA_STATE"

AK_HANDLE=0x81010002   # persistent, so the AK survives reboots and snapshots

# ---- EK + AK inside the VM -------------------------------------------------
# bug #2: /var/lib/harden does not exist on a fresh image and tpm2_createek
# fails opaquely without it. mkdir -p first, always.
vm_exec mkdir -p "$AAA_VM_STATE/tpm"

if vm_exec sh -c "tpm2_getcap handles-persistent | grep -qi ${AK_HANDLE#0x}"; then
  log "AK already persisted at $AK_HANDLE"
else
  vm_exec sh -c "cd $AAA_VM_STATE/tpm &&
    tpm2_createek -c ek.ctx -G ecc -u ek.pub &&
    tpm2_createak -C ek.ctx -c ak.ctx -G ecc -g sha256 -s ecdsa -u ak.pub -n ak.name &&
    tpm2_evictcontrol -C o -c ak.ctx $AK_HANDLE"
  ok "created EK and AK; AK persisted at $AK_HANDLE"
fi

# export the AK public key (PEM) — this is the verifier's trust anchor
vm_exec sh -c "tpm2_readpublic -c $AK_HANDLE -f pem -o $AAA_VM_STATE/tpm/ak.pem"
lxc file pull "$AAA_VM$AAA_VM_STATE/tpm/ak.pem" "$AAA_STATE/ak.pub"
[ -s "$AAA_STATE/ak.pub" ] || die "AK export failed" \
  "$AAA_STATE/ak.pub is missing or empty" "re-run scripts/30-tpm-keys.sh"
ok "AK public key exported to $AAA_STATE/ak.pub"

# ---- the milestone: one quote, verified on the host ------------------------
nonce=$(od -An -tx1 -N20 /dev/urandom | tr -d ' \n')
vm_exec sh -c "cd $AAA_VM_STATE/tpm &&
  tpm2_quote -c $AK_HANDLE -l sha256:10 -q $nonce \
             -m quote.msg -s quote.sig -o quote.pcrs -g sha256 >/dev/null"
tmpd=$(mktemp -d)
for f in quote.msg quote.sig quote.pcrs; do
  lxc file pull "$AAA_VM$AAA_VM_STATE/tpm/$f" "$tmpd/$f"
done
if tpm2_checkquote -u "$AAA_STATE/ak.pub" -m "$tmpd/quote.msg" \
     -s "$tmpd/quote.sig" -f "$tmpd/quote.pcrs" -g sha256 -q "$nonce" >/dev/null; then
  rm -rf "$tmpd"
  ok "MILESTONE: host-side tpm2_checkquote verified a quote from inside the VM"
  ok "next: scripts/40-apparmor.sh"
else
  rm -rf "$tmpd"
  die "tpm2_checkquote failed" \
      "the quote from the VM did not verify against the exported AK" \
      "scripts/teardown.sh && make build  # stale TPM state from a previous run is the usual cause"
fi
