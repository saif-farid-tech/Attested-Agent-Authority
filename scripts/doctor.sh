#!/usr/bin/env bash
# doctor.sh — one-shot health check of the whole chain. Read-only: it changes
# nothing, never dies early, and prints a single report you can paste when
# something is wrong. This is the command to run FIRST when the demo misbehaves.

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh
source scripts/lib/detect.sh
guard_host

pass=0; fail=0; warns=0
P() { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
F() { printf '  \033[31m✗\033[0m %s\n'  "$*"; fail=$((fail+1)); }
W() { printf '  \033[33m!\033[0m %s\n'  "$*"; warns=$((warns+1)); }
H() { printf '\n\033[1m%s\033[0m\n' "$*"; }

H "host"
command -v lxc >/dev/null 2>&1 && P "lxc present" || F "lxc missing — sudo snap install lxd"
detect_host_tpm && P "host TPM present" || W "no host TPM (demo uses the VM's vTPM — fine)"

H "workload VM ($AAA_VM)"
if instance_exists "$AAA_VM"; then
  P "instance exists"
  state=$(lxc list "$AAA_VM" -c s -f csv 2>/dev/null)
  [ "$state" = RUNNING ] && P "running" || F "not running (state=$state) — lxc start $AAA_VM"
  addr=$(lxc list "$AAA_VM" -c 4 -f csv 2>/dev/null | awk 'NR==1{print $1}')
  if [ -n "$addr" ]; then
    P "address: $addr"
    [ "$addr" = "$AAA_VM_ADDR" ] || W "address is not the pin $AAA_VM_ADDR (the verifier now auto-detects, so this is OK)"
    if lxc exec "$AAA_VM" -- true >/dev/null 2>&1; then P "reachable via lxc exec"; else F "lxc exec fails"; fi
  else
    F "no IPv4 address — the VM's network is down (lxc restart $AAA_VM)"
  fi
  detect_vm_tpm 2>/dev/null && P "vTPM visible inside VM" || F "no /dev/tpm* in VM — check the tpm device"
  imalines=$(lxc exec "$AAA_VM" -- sh -c 'wc -l < /sys/kernel/security/ima/ascii_runtime_measurements' 2>/dev/null || echo 0)
  [ "${imalines:-0}" -gt 10 ] && P "IMA log populated ($imalines measurements)" || F "IMA log empty — reboot: lxc restart $AAA_VM"
  lxc exec "$AAA_VM" -- sh -c 'aa-status 2>/dev/null | grep -q harden' && P "AppArmor profile 'harden' loaded" || F "profile not loaded — scripts/40-apparmor.sh"
  if lxc exec "$AAA_VM" -- test -f /var/lib/harden/agent.py; then P "agent.py deployed"; else F "agent.py missing — scripts/50-agent.sh"; fi
  if lxc exec "$AAA_VM" -- sudo -u harden test -r /var/lib/harden/config.json; then
    P "config.json readable by harden"
  else
    F "config.json not readable by harden — scripts/50-agent.sh"
  fi
else
  F "instance $AAA_VM does not exist — make build"
fi

H "verifier state (host: $AAA_STATE)"
for f in ak.pub ssh_ca workload_ed25519 harden_key.pub; do
  [ -s "$AAA_STATE/$f" ] && P "$f present" || F "$f missing — re-run the build"
done
if [ -s "$AAA_STATE/allowlist.txt" ]; then
  n=$(wc -l < "$AAA_STATE/allowlist.txt")
  P "allowlist.txt present ($n entries)"
  [ -s "$AAA_STATE/allowlist.txt.asc" ] && P "allowlist signed" || W "allowlist not signed — make rebaseline"
else
  F "allowlist.txt missing — scripts/70-baseline.sh (make rebaseline)"
fi

H "fleet"
for host in "${AAA_FLEET[@]}"; do
  if instance_exists "$host"; then
    a=$(lxc list "$host" -c 4 -f csv 2>/dev/null | awk 'NR==1{print $1}')
    if lxc_says "trustedusercakeys /etc/ssh/attested_ca.pub" exec "$host" -- sshd -T; then
      P "$host up at ${a:-?}, trusts the CA"
    else
      F "$host not trusting the CA — scripts/60-fleet.sh"
    fi
  else
    F "$host missing — scripts/60-fleet.sh"
  fi
done

H "verifier daemon"
if pgrep -f "verifier/verifier.py" >/dev/null 2>&1; then
  P "verifier.py running (funding the agent)"
else
  W "verifier.py not running — start with 'make console', or 'make demo' starts its own"
fi

H "end-to-end attestation"
rc=0; out=$(python3 verifier/attest-once.py 2>&1) || rc=$?
printf '%s\n' "$out" | sed 's/^/  /'
case $rc in
  0) P "attestation PASSES — the agent can be funded" ;;
  2) W "attestation FAILS as a verdict (rc=2) — correct if you just ran the tamper; otherwise 'make rebaseline'" ;;
  *) F "attestation blocked by a setup problem (rc=$rc) — see the stage above" ;;
esac

H "summary"
printf '  %d ok · %d warnings · %d problems\n' "$pass" "$warns" "$fail"
if [ "$fail" -eq 0 ]; then
  printf '  \033[32mhealthy — run: make console  (UI) and  make demo\033[0m\n'
else
  printf '  \033[31mfix the ✗ items above, top to bottom, then re-run: make doctor\033[0m\n'
fi
exit 0
