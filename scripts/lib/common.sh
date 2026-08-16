# shellcheck shell=bash
# scripts/lib/common.sh — logging, error trap, host guard, shared config.
#
# Every script in scripts/ sources this file first. It enforces the project's
# single most important rule: scripts run on the HOST, never inside an
# instance. If work must happen inside a VM or container, the script reaches
# in with `lxc exec` — the user never types a command in a guest shell.

set -euo pipefail

# ---------------------------------------------------------------- project map
# One place for every name the project creates, so teardown and build agree.
AAA_VM="harden"                          # the workload VM (agent lives here)
AAA_NET="fleet0"                         # LXD bridge for the demo fleet
AAA_FLEET=(web-01 db-01 gw-01)           # fleet containers behind the CA
AAA_STATE="${AAA_STATE:-$HOME/attested-agent}"   # host-side verifier state
AAA_VM_STATE="/var/lib/harden"           # inside the VM: TPM contexts, agent
AAA_SNAPSHOT="demo-ready"                # taken by 70-baseline, used by demo
AAA_VM_ADDR="${AAA_VM_ADDR:-10.147.0.10}"   # pinned; DHCP reassigns otherwise
AAA_NET_CIDR="${AAA_NET_CIDR:-10.147.0.1/24}"
AAA_CONSOLE_PORT="${AAA_CONSOLE_PORT:-9000}"
# the python tools (verifier, diagnostic) read these from the environment
export AAA_STATE AAA_VM_ADDR

# ---------------------------------------------------------------- logging
_c_reset=$'\033[0m'; _c_dim=$'\033[2m'; _c_red=$'\033[31m'
_c_grn=$'\033[32m'; _c_ylw=$'\033[33m'
[ -t 1 ] || { _c_reset=; _c_dim=; _c_red=; _c_grn=; _c_ylw=; }

log()  { printf '%s[%s]%s %s\n'  "$_c_dim" "$(basename "${BASH_SOURCE[-1]}")" "$_c_reset" "$*"; }
ok()   { printf '%s  ok%s  %s\n' "$_c_grn" "$_c_reset" "$*"; }
warn() { printf '%swarn%s  %s\n' "$_c_ylw" "$_c_reset" "$*" >&2; }
# die WHAT WHY FIX — on failure say what failed, why, and the command that fixes it.
die() {
  printf '%sfail%s  %s\n' "$_c_red" "$_c_reset" "$1" >&2
  [ $# -ge 2 ] && printf '      why: %s\n' "$2" >&2
  [ $# -ge 3 ] && printf '      fix: %s\n' "$3" >&2
  exit 1
}

# ---------------------------------------------------------------- error trap
_aaa_trap() {
  local rc=$? line=$1
  printf '%sfail%s  %s:%s exited %d\n' "$_c_red" "$_c_reset" \
    "${BASH_SOURCE[-1]}" "$line" "$rc" >&2
  exit "$rc"
}
trap '_aaa_trap $LINENO' ERR

# ---------------------------------------------------------------- host guard
# Refuse to run inside any LXD instance (VM or container). Both expose the
# guest API socket at /dev/lxd/sock via lxd-agent, which makes this reliable
# without guessing from DMI strings.
guard_host() {
  # Escape hatch for CI and dry runs only. The demo itself cannot work in a
  # guest: no LXD, no KVM, no TPM. Never set this on the reference machine.
  if [ "${AAA_I_KNOW_THIS_IS_NOT_THE_HOST:-}" = "1" ]; then
    warn "host guard OVERRIDDEN (AAA_I_KNOW_THIS_IS_NOT_THE_HOST=1) — CI/dry-run only"
    return 0
  fi
  if [ -e /dev/lxd/sock ]; then
    die "running inside an LXD instance" \
        "every script in this project runs on the host and reaches into instances with 'lxc exec'" \
        "exit this shell, then re-run the script from the host"
  fi
  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container --quiet; then
    die "running inside a container" \
        "scripts must run on the host" \
        "exit the container and re-run from the host"
  fi
  case "$(hostname)" in
    "$AAA_VM"|web-01|db-01|gw-01)
      die "hostname '$(hostname)' is a project instance name" \
          "you appear to be inside a guest" \
          "exit this shell, then re-run from the host" ;;
  esac
}

# ---------------------------------------------------------------- helpers
need() {  # need CMD PACKAGE_HINT
  command -v "$1" >/dev/null 2>&1 || \
    die "required command '$1' not found" "it is a prerequisite of this script" \
        "sudo apt install ${2:-$1}"
}

# vm_exec [--user USER] CMD... — run a command inside the workload VM.
vm_exec() {
  local u=root
  if [ "${1:-}" = "--user" ]; then u=$2; shift 2; fi
  lxc exec "$AAA_VM" -- sudo -u "$u" -- "$@"
}

# vm_push SRC DST — push a file into the workload VM.
vm_push() { lxc file push --create-dirs "$1" "$AAA_VM$2"; }

instance_exists() { lxc info "$1" >/dev/null 2>&1; }

wait_vm_ready() {  # wait for the LXD agent inside the VM to answer
  local tries=${1:-60}
  for _ in $(seq 1 "$tries"); do
    if lxc exec "$AAA_VM" -- true >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  die "VM '$AAA_VM' did not become ready" \
      "the LXD agent inside the guest never answered" \
      "lxc console $AAA_VM  # watch the boot, then re-run this script"
}

require_script() {  # require_script FILE "provided by" — state prerequisites
  [ -e "$1" ] || die "missing prerequisite: $1" \
      "it is created by $2" "run $2 first"
}

# console_event KIND TEXT — narrate into the console via the verifier's
# drop-box. Best-effort: if the verifier isn't running, the line just waits.
console_event() {
  mkdir -p "$AAA_STATE"
  printf '{"kind":"%s","text":"%s"}\n' "$1" "$2" >> "$AAA_STATE/console-events.jsonl"
}
