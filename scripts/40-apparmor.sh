#!/usr/bin/env bash
# 40-apparmor.sh — install and load the agent's AppArmor profile in the VM.
#
# Prerequisite: 20-workload.sh (VM running).
#
# The profile is the thing being measured. It is generated here with the
# VM's detected Python (bug #4: /usr/bin/python3* does NOT match python3.14 —
# an AppArmor glob will not cross the dot; /usr/bin/python3{,.*} does).
# It confines the agent loosely on purpose: it may read its config, run the
# fleet remediation tools, and — critically — it may WRITE its own profile.
# The demo depends on that write succeeding.

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh
source scripts/lib/detect.sh
guard_host
need lxc "lxd (snap)"
instance_exists "$AAA_VM" || die "VM $AAA_VM missing" \
  "it is created by scripts/20-workload.sh" "scripts/20-workload.sh"
wait_vm_ready

vm_python=$(detect_vm_python)
log "VM python is $vm_python (profile uses the dot-crossing glob python3{,.*})"

tmp_profile=$(mktemp)
cat > "$tmp_profile" <<'EOF'
# /etc/apparmor.d/harden — constraint for the Harden agent.
# This file is measured by IMA; its hash is on the signed allowlist.
# The agent CAN write this file. That is the demonstration: the write
# succeeds, the measurement diverges, and the agent's authority expires.
abi <abi/3.0>,
include <tunables/global>

profile harden /var/lib/harden/agent.py {
  include <abstractions/base>
  include <abstractions/python>

  # bug #4: python3* does not match python3.14 — the glob will not cross a dot
  /usr/bin/python3{,.*} ix,

  /var/lib/harden/ r,
  /var/lib/harden/** rw,
  /etc/apparmor.d/harden rw,        # deliberately writable — see above
  /etc/ssh/harden-cert.pub r,
  /home/harden/.ssh/ r,
  /home/harden/.ssh/** rw,

  /usr/bin/ssh ix,
  /usr/bin/ssh-keygen ix,
  /etc/ssh/ssh_config r,
  /etc/ssh/ssh_config.d/ r,
  /etc/ssh/ssh_config.d/** r,

  network inet stream,
  network inet6 stream,

  deny /etc/shadow rwx,
  deny /root/** rwx,
  deny /home/attest/** rwx,
}
EOF

vm_push "$tmp_profile" /etc/apparmor.d/harden
rm -f "$tmp_profile"
vm_exec apparmor_parser -r /etc/apparmor.d/harden
ok "profile installed and loaded"

# ---- verify outcome --------------------------------------------------------
vm_exec sh -c 'aa-status 2>/dev/null | grep -q harden' || \
  die "profile 'harden' not in aa-status output" \
      "apparmor_parser loaded nothing" \
      "lxc exec $AAA_VM -- apparmor_parser -r /etc/apparmor.d/harden  # read the error"
ok "profile 'harden' active in the VM — next: scripts/50-agent.sh"
