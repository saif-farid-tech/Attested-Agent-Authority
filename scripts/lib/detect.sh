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

# detect_lxd_ext EXT [EXT…] — is ANY of these LXD API extensions present?
#
# The names are matched exactly, quotes included, against the api_extensions
# array in GET /1.0. Exactness is the whole point of bug #26: the vTPM
# extension is called `tpm_device_type`, and preflight asked for
# `"tpm_device"` — a name no LXD has ever published. The check therefore
# failed on every machine, on every version, forever, and since preflight
# gates `make build` the documented way in was permanently shut. A vTPM the
# script then went on to attach successfully.
detect_lxd_ext() {
  local json want
  json=$(lxc query /1.0 2>/dev/null) || return 1
  [ -n "$json" ] || return 1
  for want in "$@"; do
    case "$json" in *"\"$want\""*) return 0 ;; esac
  done
  return 1
}

# detect_lxd_vtpm — can this LXD attach a vTPM? `tpm_device_type` is the
# published name; the second is accepted only so a future rename cannot lock
# the build out again the way the first one did.
detect_lxd_vtpm() { detect_lxd_ext tpm_device_type tpm_device; }

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
