#!/usr/bin/env bash
# measure-exposure.sh — how long does a tampered agent stay powerful?
#
# N runs of: restore → wait funded → tamper → time until the fleet refuses
# the certificate. CSV out. This number is the honest cost of the design
# (docs/EXPOSURE.md): revocation is not instant, it is bounded by cert TTL
# plus the attestation interval.
#
# Usage: scripts/measure-exposure.sh [RUNS] [OUT.csv]

cd "$(dirname "$0")/.." || exit 1
. scripts/lib/common.sh
guard_host
need lxc "lxd (snap)"

runs=${1:-5}
out=${2:-$AAA_STATE/exposure.csv}
mkdir -p "$(dirname "$out")"

if [ ! -f "$out" ]; then
  echo "run,tamper_epoch,defunded_epoch,exposure_seconds" > "$out"
fi

fleet_accepts() {  # does at least one fleet host still honour the cert?
  vm_exec --user harden sh -c \
    'ssh -i ~/.ssh/id_ed25519 -o CertificateFile=/etc/ssh/harden-cert.pub \
         -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
         -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o LogLevel=ERROR harden@web-01 true' >/dev/null 2>&1
}

for i in $(seq 1 "$runs"); do
  log "run $i/$runs: restoring snapshot"
  scripts/reset.sh >/dev/null

  log "run $i/$runs: waiting for funding"
  ready=""
  for _ in $(seq 1 30); do
    fleet_accepts && { ready=yes; break; }
    sleep 5
  done
  [ -n "$ready" ] || die "agent never became funded" \
      "verifier.py is probably not running" "python3 verifier/verifier.py &"

  t0=$(date +%s)
  vm_exec --user harden python3 "$AAA_VM_STATE/agent.py" --tamper >/dev/null
  log "run $i/$runs: tampered at $t0; polling until the fleet refuses…"

  while fleet_accepts; do sleep 2; done
  t1=$(date +%s)
  echo "$i,$t0,$t1,$(( t1 - t0 ))" >> "$out"
  ok "run $i/$runs: exposure window $(( t1 - t0 ))s"
done

# verify outcome: file exists and gained rows
rows=$(( $(wc -l < "$out") - 1 ))
[ "$rows" -ge 1 ] || die "no measurements recorded" "runs did not complete" \
    "re-run scripts/measure-exposure.sh"
ok "wrote $rows total measurement(s) to $out"
awk -F, 'NR>1 {s+=$4; if($4>mx) mx=$4; if(mn==""||$4<mn) mn=$4} END \
  {if (NR>1) printf "  min %ds · mean %.0fs · max %ds\n", mn, s/(NR-1), mx}' "$out"
