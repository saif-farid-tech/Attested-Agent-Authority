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

# bug #20: AppArmor only ever RESTRICTS — it cannot grant what the ordinary
# file permissions deny. `lxc file push` preserves the mktemp source mode, so
# the profile used to land 0600 owned by whoever ran the build, and the
# unprivileged `harden` user could not write it no matter what the profile
# said. The tamper then failed with "DENIED", the demo aborted mid-act, and
# the one thing the whole project exists to show never happened. The agent's
# own constraint is owned by the agent: that IS the loaded gun on the mantel.
vm_push "$tmp_profile" /etc/apparmor.d/harden 0644 harden:harden
rm -f "$tmp_profile"
vm_exec apparmor_parser -r /etc/apparmor.d/harden
ok "profile installed (0644 harden:harden — deliberately writable) and loaded"

# ---- verify outcome --------------------------------------------------------
vm_exec sh -c 'aa-status 2>/dev/null | grep -q harden' || \
  die "profile 'harden' not in aa-status output" \
      "apparmor_parser loaded nothing" \
      "lxc exec $AAA_VM -- apparmor_parser -r /etc/apparmor.d/harden  # read the error"

# Assert the premise of the demonstration rather than assuming it: if the
# agent cannot write this file, ACT 5 has nothing to show and the build should
# say so now, not eight minutes into a recording.
vm_exec sh -c 'sudo -u harden test -w /etc/apparmor.d/harden' || \
  die "the harden user cannot write /etc/apparmor.d/harden" \
      "the demonstration depends on that write SUCCEEDING (see ACT 5)" \
      "lxc exec $AAA_VM -- ls -l /etc/apparmor.d/harden  # expect 0644 harden:harden"
ok "profile 'harden' active, and writable by the agent — next: scripts/50-agent.sh"
