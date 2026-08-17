#!/usr/bin/env bash
# 20-workload.sh — launch the workload VM: secure boot, vTPM, IMA, users.
#
# Prerequisites: 00-preflight.sh passed, 10-network.sh created $AAA_NET.
#
# Everything happens from the host via `lxc exec` / `lxc file push`.
# The user never opens a shell inside the VM.

cd "$(dirname "$0")/.." || exit 1
. scripts/lib/common.sh
. scripts/lib/detect.sh
guard_host
need lxc "lxd (snap)"
lxc network show "$AAA_NET" >/dev/null 2>&1 || \
  die "network $AAA_NET missing" "it is created by scripts/10-network.sh" \
      "scripts/10-network.sh"

mkdir -p "$AAA_STATE"

# ---- launch ---------------------------------------------------------------
if instance_exists "$AAA_VM"; then
  log "instance $AAA_VM already exists"
else
  lxc init ubuntu:24.04 "$AAA_VM" --vm \
    -c security.secureboot=true \
    -c limits.cpu=2 -c limits.memory=4GiB \
    --network "$AAA_NET"
  ok "created VM $AAA_VM (secure boot on, 2 vCPU, 4 GiB)"
fi

# vTPM device (requires the tpm_device_type API extension checked in preflight)
if lxc config device get "$AAA_VM" vtpm path >/dev/null 2>&1; then
  log "vTPM device already attached"
else
  # If this fails the LXD is too old for the tpm device type. Say so here —
  # preflight's job is to catch it first, but a wrong check there once made
  # this the real gate (bug #26), and a bare ERR-trap line number told nobody.
  lxc config device add "$AAA_VM" vtpm tpm || \
    die "could not attach a vTPM to $AAA_VM" \
        "this LXD does not support the 'tpm' device type (API extension tpm_device_type)" \
        "sudo snap refresh lxd   # then re-run scripts/20-workload.sh"
  ok "attached vTPM device"
fi

# ---- pin the address (bug #7: DHCP reassigns on every rebuild) -------------
# The NIC's LXD device name is discovered, not assumed — and note the guest
# will still name the interface something like enp5s0, never eth0.
# !found (not 'print;exit') so awk reads to EOF and never SIGPIPEs lxc
nicdev=$(lxc config show "$AAA_VM" --expanded | \
         awk '/^  [a-z0-9]+:$/{d=$1} /type: nic/ && !found {gsub(":","",d); print d; found=1}')
[ -n "$nicdev" ] || die "could not find the VM's NIC device" \
    "the instance has no nic in its expanded config" \
    "lxc config show $AAA_VM --expanded  # then re-run"
if [ "$(lxc config device get "$AAA_VM" "$nicdev" ipv4.address 2>/dev/null)" = "$AAA_VM_ADDR" ]; then
  log "address already pinned to $AAA_VM_ADDR (device $nicdev)"
else
  lxc config device override "$AAA_VM" "$nicdev" ipv4.address="$AAA_VM_ADDR" 2>/dev/null || \
    lxc config device set "$AAA_VM" "$nicdev" ipv4.address="$AAA_VM_ADDR"
  ok "pinned $AAA_VM to $AAA_VM_ADDR on device $nicdev"
fi

lxc_says RUNNING info "$AAA_VM" || { lxc start "$AAA_VM"; log "starting VM…"; }
wait_vm_ready

# ---- quality of life: apport off (bug #9) ---------------------------------
vm_exec sh -c 'systemctl disable --now apport >/dev/null 2>&1 || true
               [ -f /etc/default/apport ] && sed -i "s/enabled=1/enabled=0/" /etc/default/apport || true'
ok "apport disabled in the VM (crash noise would ruin recordings)"

# ---- packages -------------------------------------------------------------
# openssh-server is in the cloud image, but it is also the transport the whole
# attestation depends on — assert it rather than assume it, exactly as
# 60-fleet.sh does for the containers.
vm_exec sh -c 'export DEBIAN_FRONTEND=noninteractive
               command -v tpm2_quote >/dev/null && command -v aa-status >/dev/null &&
               command -v sshd >/dev/null || {
                 apt-get update -q && apt-get install -qy tpm2-tools apparmor-utils python3 openssh-server; }'
ok "VM packages present: tpm2-tools, apparmor-utils, python3, openssh-server"

# ---- users ----------------------------------------------------------------
# harden : the agent's own account (constrained by the AppArmor profile)
# attest : the verifier's SSH login; passwordless sudo so the verifier can
#          read the IMA log and drive the TPM without a password prompt
vm_exec sh -c 'id harden >/dev/null 2>&1 || useradd -m -s /bin/bash harden
               id attest >/dev/null 2>&1 || useradd -m -s /bin/bash attest
               printf "attest ALL=(ALL) NOPASSWD:ALL\n" > /etc/sudoers.d/attest
               chmod 0440 /etc/sudoers.d/attest'
ok "users harden (agent) and attest (verifier login, passwordless sudo)"

# verifier's SSH key for reaching the workload — project-local, never ~/.ssh
if [ ! -f "$AAA_STATE/workload_ed25519" ]; then
  ssh-keygen -q -t ed25519 -N '' -C 'verifier->workload' -f "$AAA_STATE/workload_ed25519"
  ok "generated verifier SSH key at $AAA_STATE/workload_ed25519"
fi
vm_exec sh -c 'mkdir -p /home/attest/.ssh && chmod 700 /home/attest/.ssh'
vm_push "$AAA_STATE/workload_ed25519.pub" /home/attest/.ssh/authorized_keys 0600 attest:attest
vm_exec sh -c 'chown -R attest:attest /home/attest/.ssh'
ok "verifier key authorised for attest@$AAA_VM_ADDR"

# ---- IMA policy (bugs #1 and #3) ------------------------------------------
# /etc/ima does not exist on a fresh image — mkdir -p first. And we use a
# custom policy ONLY; putting ima_policy=tcb on the kernel line as well
# contradicts it and yields an unusably large allowlist.
tmp_policy=$(mktemp)
cat > "$tmp_policy" <<'EOF'
# attested-agent-authority — IMA measurement policy (custom; no ima_policy=tcb)
# Skip pseudo/volatile filesystems so the allowlist stays signal, not noise.
dont_measure fsmagic=0x9fa0
dont_measure fsmagic=0x62656572
dont_measure fsmagic=0x64626720
dont_measure fsmagic=0x1021994
dont_measure fsmagic=0x73636673
dont_measure fsmagic=0x27e0eb
dont_measure fsmagic=0x63677270
# Measure every executable and executable mapping, and every file root reads.
# The last rule is what catches /etc/apparmor.d/harden when apparmor_parser
# loads it — the agent's constraint becomes part of the measured state.
measure func=BPRM_CHECK mask=MAY_EXEC
measure func=MMAP_CHECK mask=MAY_EXEC
measure func=FILE_CHECK mask=MAY_READ uid=0
EOF
vm_exec mkdir -p /etc/ima
# Did the policy actually change? That, not the presence of a log, is what
# decides whether a reboot is needed below.
policy_changed=1
if vm_exec test -f /etc/ima/ima-policy 2>/dev/null; then
  old_policy=$(mktemp)
  lxc file pull "$AAA_VM/etc/ima/ima-policy" "$old_policy" 2>/dev/null || true
  cmp -s "$old_policy" "$tmp_policy" && policy_changed=0
  rm -f "$old_policy"
fi
vm_push "$tmp_policy" /etc/ima/ima-policy 0644 root:root
rm -f "$tmp_policy"
ok "IMA policy installed at /etc/ima/ima-policy (loaded by systemd at boot)"

# Make sure no stale ima_policy=tcb sits on the kernel command line.
if vm_exec sh -c 'grep -q "ima_policy=tcb" /etc/default/grub /proc/cmdline 2>/dev/null'; then
  vm_exec sh -c 'sed -i "s/ima_policy=tcb//g" /etc/default/grub && update-grub -q'
  warn "removed conflicting ima_policy=tcb from the kernel line (bug #3)"
fi

# ---- reboot so the policy takes effect from early boot ---------------------
# bug #19: this used to skip the reboot whenever the log was merely NON-EMPTY.
# A VM that has never loaded a policy still has exactly one line in that log —
# the boot_aggregate the kernel always writes — so the test was true on a
# fresh build, the reboot was skipped, the policy never loaded, and the check
# below then failed the FIRST build with "IMA measurement log is empty".
# Reboot when the policy changed, or when the log holds nothing but the
# boot aggregate.
measured=$(vm_exec sh -c 'wc -l < /sys/kernel/security/ima/ascii_runtime_measurements' 2>/dev/null || echo 0)
if [ "$policy_changed" -eq 0 ] && [ "${measured:-0}" -gt 10 ]; then
  log "IMA policy unchanged and $measured measurements present — no reboot needed"
else
  log "cold-booting VM so the IMA policy applies from boot…"
  cold_boot_vm
fi

# ---- verify outcome --------------------------------------------------------
detect_vm_tpm || die "no TPM device inside the VM" \
    "the vtpm device did not surface as /dev/tpm0" \
    "lxc config device show $AAA_VM  # confirm the tpm device, then lxc restart $AAA_VM"
count=$(vm_exec sh -c 'wc -l < /sys/kernel/security/ima/ascii_runtime_measurements')
[ "$count" -gt 10 ] || die "IMA measurement log is empty" \
    "the policy did not load at boot" \
    "lxc exec $AAA_VM -- journalctl -b | grep -i ima  # then re-run this script"

addr=$(detect_vm_addr); iface=$(detect_vm_iface)
[ "$addr" = "$AAA_VM_ADDR" ] || warn "VM answers on $addr, pin is $AAA_VM_ADDR — restart once more to apply"
ok "workload ready: kernel $(detect_vm_kernel), $(detect_vm_python), iface $iface, $count IMA measurements"
ok "next: scripts/30-tpm-keys.sh"
