# shellcheck shell=bash
# scripts/lib/detect.sh — detect rather than assume.
#
# The reference build (Ubuntu on a ThinkPad T480) broke several assumptions:
# the VM kernel was 7.0.0-28-generic, the VM Python was 3.14 (not 3.12), and
# the VM interface was enp5s0 (not eth0). Every value here is discovered at
# run time; the reference values are documented, never hardcoded.

# ---- host ------------------------------------------------------------------

detect_host_tpm() {   # exits 0 if a real TPM char device is present
  [ -c /dev/tpm0 ] || [ -c /dev/tpmrm0 ]
}

detect_lxd_ext() {    # detect_lxd_ext EXTENSION — is an LXD API extension present?
  lxc_says "\"$1\"" query /1.0
}

detect_free_ram_mb() { awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo; }

detect_free_disk_gb() { df -BG --output=avail / | tail -1 | tr -dc '0-9'; }

# ---- workload VM (queried over lxc exec, never assumed) --------------------

detect_vm_kernel() { vm_exec uname -r; }

# The newest python3.x on PATH inside the VM. On the reference build this is
# python3.14 — which is why the AppArmor profile must use /usr/bin/python3{,.*}
# (an AppArmor glob does not cross the dot in "python3.14").
detect_vm_python() {
  vm_exec sh -c 'for p in $(ls /usr/bin/python3* 2>/dev/null | sort -V -r); do
                   case "$p" in *-config) continue;; esac
                   [ -x "$p" ] && { basename "$p"; exit 0; }
                 done; echo python3'
}

# First non-loopback interface inside the VM. enp5s0 on the reference build;
# eth0 is exactly the kind of assumption this file exists to kill.
detect_vm_iface() {
  vm_exec sh -c "ip -o link show | awk -F': ' '\$2 != \"lo\" {print \$2; exit}'"
}

detect_vm_addr() {    # current IPv4 of the detected interface
  local iface; iface=$(detect_vm_iface)
  vm_exec sh -c "ip -4 -o addr show dev '$iface' | awk '{split(\$4,a,\"/\"); print a[1]; exit}'"
}

detect_vm_tpm() {     # vTPM visible inside the VM?
  vm_exec sh -c '[ -c /dev/tpm0 ] || [ -c /dev/tpmrm0 ]'
}

detect_fleet_addr() { # detect_fleet_addr NAME — IPv4 of a fleet container
  # NR==1 (not 'print;exit') so awk reads to EOF and never SIGPIPEs lxc
  lxc list "$1" -c 4 -f csv | awk 'NR==1{print $1}'
}
