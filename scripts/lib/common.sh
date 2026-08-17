# shellcheck shell=bash
# scripts/lib/common.sh — logging, error trap, host guard, shared config.
#
# Every script in scripts/ sources this file first. It enforces the project's
# single most important rule: scripts run on the HOST, never inside an
# instance. If work must happen inside a VM or container, the script reaches
# in with `lxc exec` — the user never types a command in a guest shell.

# Bash only (bug #29). Every script sources this with `.` (POSIX) rather than
# `source` so that running one with `sh scripts/…` reaches this guard instead
# of collapsing into a pile of "source: not found" and "Bad substitution" —
# which is what it looked like when someone reasonably tried `sh` after a
# script appeared to hang.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "fail  this project's scripts are bash, not sh" >&2
  echo "      fix: bash $0    (or just: make <target>)" >&2
  exit 1
fi

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

# AAA_SETTLED_PROBE — the readiness test, run INSIDE the guest by
# `lxc exec … -- sh -c "$AAA_SETTLED_PROBE"`. Dash-compatible, no single
# quotes. It always PRINTS what it saw ("sshd=yes ima=2043") and exits 0 only
# when the VM is genuinely usable, so a timeout can report the truth instead
# of guessing between two causes.
#
# bug #27: this used to be `systemctl is-active ssh || systemctl is-active
# sshd`. On Ubuntu 22.10 and later — the demo VM is 24.04 — sshd is SOCKET
# ACTIVATED: ssh.socket holds port 22 and ssh.service stays "inactive" until a
# connection arrives, so that test was false on a perfectly healthy machine
# and every cold boot ended in "came up but never settled". Ask the question
# that actually matters: is anything listening on port 22?
#
# The two file paths it reads are overridable (AAA_IMA_LOG, AAA_PROC_NET_TCP)
# for one reason: tests/test_vm_probe.sh runs this exact string against stub
# files, so the check that gates every build is itself checked by 'make
# selftest' — on any machine, with no LXD and no VM.
AAA_SETTLED_PROBE='
sshd=no
for u in ssh.socket sshd.socket ssh.service sshd.service; do
  if systemctl is-active --quiet "$u" 2>/dev/null; then sshd=yes; break; fi
done
if [ "$sshd" = no ]; then
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -qE "[:.]22[[:space:]]"; then
    sshd=yes
  elif grep -qiE ":0016 [0-9A-F]+:[0-9A-F]+ 0A" ${AAA_PROC_NET_TCP:-/proc/net/tcp /proc/net/tcp6} 2>/dev/null; then
    sshd=yes
  fi
fi
ima=$(wc -l < "${AAA_IMA_LOG:-/sys/kernel/security/ima/ascii_runtime_measurements}" 2>/dev/null || echo 0)
ima=$(printf %s "$ima" | tr -dc 0-9)
[ -n "$ima" ] || ima=0
echo "sshd=$sshd ima=$ima"
[ "$sshd" = yes ] || exit 1
[ "$ima" -gt 10 ] || exit 1
exit 0
'

# vm_settled_state — what the probe currently sees, for diagnostics. Never fails.
vm_settled_state() {
  lxc exec "$AAA_VM" -- sh -c "$AAA_SETTLED_PROBE" 2>/dev/null || true
}

# wait_vm_settled — the LXD agent answering is NOT the same as the VM being
# usable. Attestation needs sshd listening and the IMA policy loaded; asking
# for those a few seconds too early is the difference between "the demo works"
# and "the demo works on the second try" (bug #17).
wait_vm_settled() {
  wait_vm_ready
  local tries=${1:-90} state=""
  for _ in $(seq 1 "$tries"); do
    if state=$(lxc exec "$AAA_VM" -- sh -c "$AAA_SETTLED_PROBE" 2>/dev/null); then
      return 0
    fi
    sleep 2
  done
  # Say which half is missing. "sshd=no" means nothing is listening on port 22;
  # "ima=0" (or a handful) means the policy did not load at boot.
  die "VM '$AAA_VM' came up but never settled (saw: ${state:-no answer from the guest})" \
      "it needs something listening on port 22 (ssh.socket counts) AND a populated IMA log" \
      "make doctor   # runs the same probe and names the failing piece"
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

# verifier_pids — the PIDs of live verifier.py processes, one per line.
#
# bug #28: `pgrep -f verifier/verifier.py` counted the same verifier twice.
# `make console` runs its recipe through `bash -c "… python3
# verifier/verifier.py & …"`, so the RECIPE SHELL's command line contains the
# pattern as well, and doctor reported "2 verifiers running — kill all but
# one" on a perfectly healthy machine (the verifier's PID lock, bug #22, makes
# a genuine second one impossible in the first place). Anchor the match at
# argv[0] so only the python process itself counts.
verifier_pids() {
  pgrep -f '^([^ ]*/)?python[0-9.]*( +-[^ ]+)* +[^ ]*verifier/verifier\.py' 2>/dev/null || true
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
