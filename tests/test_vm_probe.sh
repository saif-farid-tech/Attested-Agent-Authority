#!/usr/bin/env bash
# test_vm_probe.sh — the host-side gates, tested on any machine.
#
#   bash tests/test_vm_probe.sh        (also run by 'make selftest')
#
# These three checks decide whether a build may proceed at all, and each of
# them has already shut the project down once by answering "no" about a
# perfectly healthy machine:
#
#   #26  preflight looked for an LXD API extension named "tpm_device". The
#        real name is "tpm_device_type", so 'make preflight' and 'make build'
#        could not pass on any version of LXD, ever.
#   #27  the readiness probe demanded an ACTIVE ssh.service, which Ubuntu
#        24.04 never has: sshd is socket-activated. Every cold boot — build,
#        rebaseline, and ACT 0 of every demo — died on it.
#   #28  doctor counted verifiers with a pattern that also matches the shell
#        'make console' runs the verifier from, and reported two.
#
# All three are pure string logic. Nothing here needs LXD, a VM or a TPM.

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh
source scripts/lib/detect.sh
set +e                       # assertions handle their own failures
trap - ERR

fails=0
STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT
PATH="$STUB/bin:$PATH"; mkdir -p "$STUB/bin"

pass() { printf '  ok  %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$3', got '$2')"; fi; }

stub() {  # stub NAME BODY — put a fake command at the front of PATH
  printf '#!/bin/sh\n%s\n' "$2" > "$STUB/bin/$1"
  chmod 755 "$STUB/bin/$1"
}

probe() {  # run the guest-side probe with stubbed surroundings; echo its verdict
  local out rc
  out=$(AAA_IMA_LOG="$STUB/ima.log" AAA_PROC_NET_TCP=/dev/null \
        sh -c "$AAA_SETTLED_PROBE" 2>/dev/null); rc=$?
  echo "$out rc=$rc"
}

printf '\nreadiness probe (bug #27 — socket-activated sshd)\n'

# A populated IMA log, so the sshd half is what varies below.
seq 1 40 > "$STUB/ima.log"

# Ubuntu 24.04 as it actually is: ssh.service inactive, ssh.socket holding
# port 22. The old check asked `systemctl is-active ssh` and gave up here.
stub systemctl 'for a in "$@"; do case $a in ssh.socket) exit 0;; esac; done; exit 3'
stub ss 'echo "LISTEN 0 4096 *:22 *:*"'
check "socket-activated sshd counts as ready" "$(probe)" "sshd=yes ima=40 rc=0"

# Same machine, older layout: a persistent ssh.service.
stub systemctl 'for a in "$@"; do case $a in ssh.service) exit 0;; esac; done; exit 3'
stub ss 'echo "LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*"'
check "a persistent ssh.service counts as ready" "$(probe)" "sshd=yes ima=40 rc=0"

# No unit of any name active, but something IS listening on 22: still ready.
stub systemctl 'exit 3'
stub ss 'echo "LISTEN 0 128 [::]:22 [::]:*"'
check "a listener on 22 is enough, whatever the unit is called" \
      "$(probe)" "sshd=yes ima=40 rc=0"

# Nothing listening: the probe must say no — and say WHY, in its output.
stub systemctl 'exit 3'
stub ss 'echo "LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:*"'
check "nothing on port 22 is not ready" "$(probe)" "sshd=no ima=40 rc=1"

# A high port that merely ends in 22 is not sshd.
stub ss 'echo "LISTEN 0 4096 0.0.0.0:2222 0.0.0.0:*"'
check "port 2222 does not pass for port 22" "$(probe)" "sshd=no ima=40 rc=1"

# The other half of "settled": the IMA policy loaded at boot. A VM that
# never loaded one still has the kernel's boot_aggregate line (bug #19).
stub systemctl 'exit 0'
stub ss 'echo "LISTEN 0 4096 *:22 *:*"'
echo "boot_aggregate" > "$STUB/ima.log"
check "an unpopulated IMA log is not ready" "$(probe)" "sshd=yes ima=1 rc=1"

printf '\nLXD vTPM extension (bug #26 — the wrong extension name)\n'

# A GET /1.0 body shaped like the real one.
stub lxc 'cat <<JSON
{
    "api_extensions": [
        "storage_zfs_remove_snapshots",
        "tpm_device_type",
        "instance_nic_network"
    ],
    "api_status": "stable"
}
JSON'
if detect_lxd_vtpm; then pass "tpm_device_type is recognised"
else fail "tpm_device_type is recognised"; fi
if detect_lxd_ext tpm_device; then
  fail "the old name 'tpm_device' must NOT match tpm_device_type"
else pass "the old name 'tpm_device' does not match tpm_device_type"; fi

stub lxc 'echo "{\"api_extensions\": [\"instance_nic_network\"], \"api_status\": \"stable\"}"'
if detect_lxd_vtpm; then fail "an LXD without the extension must not pass"
else pass "an LXD without the extension does not pass"; fi

stub lxc 'exit 1'
if detect_lxd_vtpm; then fail "an unreachable LXD must not pass"
else pass "an unreachable LXD does not pass"; fi
rm -f "$STUB/bin/lxc"

printf '\nverifier count (bug #28 — the shell that launched it is not a verifier)\n'

mkdir -p "$STUB/verifier"
printf 'import time\ntime.sleep(30)\n' > "$STUB/verifier/verifier.py"
python3 "$STUB/verifier/verifier.py" & real=$!
# What 'make console' leaves in the process table beside it: a shell whose
# command line contains the pattern but which is not a verifier. (Two
# commands, so bash keeps the shell instead of exec-ing the last one and
# rewriting its command line — the process table must show the pattern for
# this test to be testing anything.)
bash -c "trap : EXIT; sleep 30 # python3 verifier/verifier.py" & shell=$!
sleep 1
# Guard the fixture itself: if the naive pattern does not match the shell,
# this test proves nothing and must say so rather than quietly passing.
if pgrep -f "verifier/verifier\.py" | grep -qx "$shell"; then
  pass "fixture: the naive 'pgrep -f verifier/verifier.py' does match the shell"
else
  fail "fixture: the naive pattern no longer matches the shell — test is vacuous"
fi
# One PID per line, and a REAL verifier may well be running on this machine
# (an earlier demo, or 'make console' in another terminal) — so flatten to a
# single space-separated line and assert membership, never the exact set.
found=$(verifier_pids | tr '\n' ' ')
case " $found " in
  *" $real "*) pass "the real verifier process is counted" ;;
  *) fail "the real verifier process is counted (got '${found:-none}')" ;;
esac
case " $found " in
  *" $shell "*) fail "the launching shell must NOT be counted as a verifier" ;;
  *) pass "the launching shell is not counted" ;;
esac
kill "$real" "$shell" 2>/dev/null
wait "$real" "$shell" 2>/dev/null

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf '  ok  host-side gates: readiness probe, vTPM detection, verifier count\n'
  exit 0
fi
printf '  %d assertion(s) failed\n' "$fails" >&2
exit 1
