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
AAA_NET_CIDR="${AAA_NET_CIDR:-10.147.0.1/24}"
# Every address is derived from the bridge's subnet, so overriding
# AAA_NET_CIDR moves the whole demo together instead of half of it.
_aaa_gw=${AAA_NET_CIDR%/*}; _aaa_pfx=${_aaa_gw%.*}
AAA_VM_ADDR="${AAA_VM_ADDR:-$_aaa_pfx.10}"  # pinned; DHCP reassigns otherwise
# bug #16: the fleet's addresses are pinned too. The VM resolves fleet names
# from an /etc/hosts frozen into the demo-ready snapshot; if a container came
# back on a new DHCP lease, that file pointed at nothing and the agent could
# never reach the fleet — the demo "worked yesterday" and failed today.
declare -A AAA_FLEET_ADDR=(
  [web-01]="$_aaa_pfx.11"
  [db-01]="$_aaa_pfx.12"
  [gw-01]="$_aaa_pfx.13"
)
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

# vm_push SRC DST [MODE] [OWNER:GROUP] — push a file into the workload VM.
#
# bug #12 generalised: `lxc file push` copies the SOURCE file's mode and uid,
# and every caller here pushes from mktemp — mode 0600, owned by whoever ran
# the script. Anything the VM must read as another user therefore lands
# unreadable. Always state the mode you mean; never inherit mktemp's.
vm_push() {
  lxc file push --create-dirs "$1" "$AAA_VM$2"
  if [ -n "${3:-}" ]; then lxc exec "$AAA_VM" -- chmod "$3" "$2"; fi
  if [ -n "${4:-}" ]; then lxc exec "$AAA_VM" -- chown "$4" "$2"; fi
}

instance_exists() { lxc info "$1" >/dev/null 2>&1; }

# lxc_says PATTERN CMD... — true if the stdout of an lxc command contains the
# literal substring PATTERN. Capture-then-match; NEVER `lxc … | grep -q …`.
# Under `set -o pipefail`, grep -q closes the pipe on its first match and
# SIGPIPEs the still-streaming lxc process, so the pipeline reports failure
# even though the match SUCCEEDED. That false failure was a real bug: the CA
# trust was correctly configured, yet the verify step "failed" every time.
lxc_says() {
  local pat=$1; shift
  local out; out=$(lxc "$@" 2>/dev/null) || true
  [[ $out == *"$pat"* ]]
}

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

# wait_vm_settled — the LXD agent answering is NOT the same as the VM being
# usable. Attestation needs sshd listening and the IMA policy loaded; asking
# for those a few seconds too early is the difference between "the demo works"
# and "the demo works on the second try" (bug #17).
wait_vm_settled() {
  wait_vm_ready
  local tries=${1:-90}
  for _ in $(seq 1 "$tries"); do
    if lxc exec "$AAA_VM" -- sh -c '
         (systemctl is-active ssh >/dev/null 2>&1 ||
          systemctl is-active sshd >/dev/null 2>&1) &&
         [ "$(wc -l < /sys/kernel/security/ima/ascii_runtime_measurements)" -gt 10 ]
       ' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "VM '$AAA_VM' came up but never settled" \
      "sshd is not listening, or the IMA policy did not load at boot" \
      "make doctor   # names the failing piece"
}

# cold_boot_vm — a real power cycle, not a warm restart. The IMA measurement
# log lives in kernel memory: only a fresh boot regenerates it (bug #14).
cold_boot_vm() {
  lxc stop "$AAA_VM" >/dev/null 2>&1 || lxc stop "$AAA_VM" --force >/dev/null 2>&1 || true
  lxc start "$AAA_VM" >/dev/null 2>&1 || true
  wait_vm_settled
}

# ensure_fleet_up — the fleet containers are not part of the VM snapshot, so
# a host reboot leaves them stopped while everything else looks healthy. Start
# them and wait, rather than failing three acts later inside the demo.
ensure_fleet_up() {
  local host
  for host in "${AAA_FLEET[@]}"; do
    instance_exists "$host" || die "fleet host $host is missing" \
        "it is created by scripts/60-fleet.sh" "scripts/60-fleet.sh"
    lxc_says RUNNING info "$host" || lxc start "$host" >/dev/null 2>&1 || true
  done
  for host in "${AAA_FLEET[@]}"; do
    local ready=""
    for _ in $(seq 1 30); do
      if lxc exec "$host" -- true >/dev/null 2>&1; then ready=yes; break; fi
      sleep 2
    done
    [ -n "$ready" ] || die "fleet host $host did not become ready" \
        "the container is not answering" "lxc start $host && lxc info $host"
  done
}

# clear_console_events — drop narration left over from an earlier run. Without
# this the next verifier ingests the previous demo's acts and the console
# replays a show that is not happening (bug #18).
clear_console_events() { rm -f "$AAA_STATE/console-events.jsonl"; }

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
