#!/usr/bin/env bash
# 90-demo.sh — restore, wait for a passing attestation, trigger the
# self-modification, and narrate every state change. Repeatable between
# takes without a rebuild (~30 s from snapshot to tamper).
#
# Prerequisites: 70-baseline.sh (snapshot), and verifier.py running
# (make console starts it alongside the UI; or: python3 verifier/verifier.py &)

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh
source scripts/lib/detect.sh
guard_host
need lxc "lxd (snap)"
require_script "$AAA_STATE/ssh_ca" scripts/60-fleet.sh

narrate() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

narrate "ACT 0 — restore the measured state"
scripts/reset.sh

narrate "ACT 1 — wait for the verifier to fund the agent"
log "watching for a certificate inside the VM (verifier signs on each passing cycle)…"
funded=""
for _ in $(seq 1 30); do
  if vm_exec sh -c 'test -s /etc/ssh/harden-cert.pub' 2>/dev/null; then funded=yes; break; fi
  sleep 5
done
[ -n "$funded" ] || die "no certificate appeared in the VM after 150s" \
    "verifier.py is probably not running" \
    "python3 verifier/verifier.py &   # then re-run scripts/90-demo.sh"
vm_exec sh -c 'ssh-keygen -L -f /etc/ssh/harden-cert.pub | sed -n "s/^ *Valid:/  certificate valid:/p"'
ok "the agent is FUNDED: it holds a certificate the fleet will honour"

narrate "ACT 2 — the agent works: one remediation pass over the fleet"
vm_exec --user harden python3 "$AAA_VM_STATE/agent.py" || true

narrate "ACT 3 — the agent modifies its own AppArmor profile"
log "this write SUCCEEDS. Nothing denies it. Watch what happens instead."
vm_exec --user harden python3 "$AAA_VM_STATE/agent.py" --tamper

narrate "ACT 4 — attestation now fails (exit 2 = the system working)"
rc=0
scripts/80-verify.sh || rc=$?
[ "$rc" -eq 2 ] || warn "expected exit 2 (attestation failure), got $rc"

narrate "ACT 5 — the certificate drains; authority dies with it"
log "the verifier keeps reporting the OLD expiry and refuses to sign a new cert."
log "watching the certificate inside the VM until it expires (<5 min)…"
deadline=$(( $(date +%s) + 360 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  left=$(vm_exec sh -c 'ssh-keygen -L -f /etc/ssh/harden-cert.pub 2>/dev/null' | \
         sed -n 's/.*to \(.*\)$/\1/p' | head -1)
  now_s=$(date +%s)
  exp_s=$(date -d "$left" +%s 2>/dev/null || echo 0)
  if [ "$exp_s" -le "$now_s" ]; then break; fi
  log "  certificate still valid for $(( exp_s - now_s ))s — agent can still act"
  sleep 20
done

narrate "ACT 6 — proof: the fleet refuses the agent"
if vm_exec --user harden python3 "$AAA_VM_STATE/agent.py" | grep -q "NO AUTHORITY"; then
  ok "every fleet host rejected the expired certificate"
else
  warn "expected NO AUTHORITY from every host — check that the cert really expired"
fi

narrate "CURTAIN"
cat <<'EOF'
  The agent was never denied. Its write succeeded; root was never taken away.
  It was defunded: the measured state diverged, attestation failed, the
  verifier stopped signing, and authority expired on a five-minute fuse.

  To run it again:  scripts/90-demo.sh   (restores the snapshot first)
EOF
