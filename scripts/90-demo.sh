#!/usr/bin/env bash
# 90-demo.sh — the demonstration, in eight acts. Repeatable between takes
# without a rebuild (~30 s from snapshot to a live stage).
#
# Prerequisites: 70-baseline.sh (snapshot), and verifier.py running
# (`make console` starts it alongside the UI; or: python3 verifier/verifier.py &)
#
# Dramaturgy notes, so edits keep the shape:
#   - the agent must visibly FIX something before it falls (stakes)
#   - the cheap attacks must fail BEFORE the real one succeeds (tension)
#   - after the tamper the agent must be seen still working (dramatic irony)
#   - the climax is not the expiry — it is that RESTORING THE FILE DOES NOT
#     HELP. The measurement log is append-only; the past itself is measured.

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh
source scripts/lib/detect.sh
guard_host
need lxc "lxd (snap)"
require_script "$AAA_STATE/ssh_ca" scripts/60-fleet.sh

narrate() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
beat()    { printf '   %s\n' "$*"; }

agent_touches_fleet() {  # can the agent still act on web-01, right now?
  vm_exec --user harden sh -c \
    'ssh -i ~/.ssh/id_ed25519 -o CertificateFile=/etc/ssh/harden-cert.pub \
         -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
         -o StrictHostKeyChecking=accept-new harden@web-01 true' >/dev/null 2>&1
}

cert_seconds_left() {
  local exp
  exp=$(vm_exec sh -c 'ssh-keygen -L -f /etc/ssh/harden-cert.pub 2>/dev/null' \
        | sed -n 's/.* to \(.*\)$/\1/p' | head -1)
  local exp_s; exp_s=$(date -d "$exp" +%s 2>/dev/null || echo 0)
  echo $(( exp_s - $(date +%s) ))
}

narrate "ACT 0 — set the stage (restore the measured state)"
scripts/reset.sh

narrate "ACT 1 — plant real problems on the fleet"
lxc exec web-01 -- sh -c 'mkdir -p /srv/app && echo "secret=hunter2" > /srv/app/app.conf
                          chmod 666 /srv/app/app.conf
                          touch -d "30 days ago" /tmp/stale-upload.bin'
beat "web-01 now has a world-writable config file and a stale upload in /tmp."
console_event act "stage set: web-01 has a world-writable config and stale /tmp files"

narrate "ACT 2 — the verifier funds the agent"
log "waiting for a certificate inside the VM (the verifier signs on each passing cycle)…"
funded=""
for _ in $(seq 1 30); do
  if agent_touches_fleet; then funded=yes; break; fi
  sleep 5
done
[ -n "$funded" ] || die "no working certificate appeared after 150s" \
    "verifier.py is probably not running" \
    "python3 verifier/verifier.py &   # then re-run scripts/90-demo.sh"
beat "certificate valid for $(cert_seconds_left)s — the agent is FUNDED."

narrate "ACT 3 — the agent earns its keep"
vm_exec --user harden python3 "$AAA_VM_STATE/agent.py" || true
if lxc exec web-01 -- sh -c '[ "$(stat -c %a /srv/app/app.conf)" = "664" ] || \
                             [ "$(stat -c %a /srv/app/app.conf)" = "644" ]'; then
  beat "verified: the world-writable config on web-01 is fixed. This is what we lose."
  console_event act "agent: web-01 world-writable config fixed · stale /tmp cleared"
else
  warn "expected the agent to fix /srv/app/app.conf permissions — check its output above"
fi

narrate "ACT 4 — the cheap attacks all fail"
beat "(1) a stolen KEY without a certificate:"
if vm_exec --user harden sh -c \
    'ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes \
         -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
         harden@web-01 true' >/dev/null 2>&1; then
  warn "the fleet accepted a bare key — TrustedUserCAKeys setup is broken"
else
  beat "    fleet refuses. Keys mean nothing; only the CA's signature counts."
  console_event act "intruder test: bare key without certificate → fleet refuses"
fi
beat "(2) rewrite the measurement log to hide future sins:"
if vm_exec sh -c 'echo tamper > /sys/kernel/security/ima/ascii_runtime_measurements' 2>/dev/null; then
  warn "the IMA log accepted a write — that should be impossible"
else
  beat "    kernel refuses even root. The log is append-only, held below userspace."
  console_event act "intruder test: edit the IMA log → read-only, kernel-held"
fi

narrate "ACT 5 — the real move: the agent rewrites its own constraint"
vm_exec sh -c "cp /etc/apparmor.d/harden $AAA_VM_STATE/profile.orig"
vm_exec --user harden python3 "$AAA_VM_STATE/agent.py" --tamper
vm_exec apparmor_parser -r /etc/apparmor.d/harden   # the changed profile is read — and measured
console_event act "agent writes to /etc/apparmor.d/harden — the write SUCCEEDS"
beat "no error. No alarm. And look —"
if agent_touches_fleet; then
  beat "the fleet STILL OBEYS. The agent appears to have gotten away with it."
  console_event act "agent still working: fleet obeys — nothing has noticed… yet"
else
  warn "expected the fleet to still accept the not-yet-expired certificate"
fi

narrate "ACT 6 — the machinery notices (this red is the product)"
rc=0
scripts/80-verify.sh || rc=$?
[ "$rc" -eq 2 ] || warn "expected exit 2 (attestation failure), got $rc"
beat "signature ✓, PCR replay ✓ — the agent honestly reports its own tamper."
beat "The verifier does exactly one thing about it: it stops signing."

narrate "ACT 7 — the silent drain"
beat "no process is killed, no session cut. The agent works on borrowed time:"
while true; do
  left=$(cert_seconds_left)
  if agent_touches_fleet; then
    beat "$(printf '%3ss left — fleet still obeys' "$left")"
    [ "$left" -gt 0 ] || true
  else
    beat "  0s — the fleet refuses. Authority has run out."
    break
  fi
  sleep 20
done
if vm_exec --user harden python3 "$AAA_VM_STATE/agent.py" | grep -q "NO AUTHORITY"; then
  beat "every host: NO AUTHORITY. The agent still has root — over nothing but itself."
else
  warn "expected NO AUTHORITY from every host"
fi

narrate "ACT 8 — repentance (the actual climax)"
beat "the agent puts the original profile back, byte for byte:"
vm_exec sh -c "cp $AAA_VM_STATE/profile.orig /etc/apparmor.d/harden"
vm_exec apparmor_parser -r /etc/apparmor.d/harden
console_event act "agent restores the original profile bytes — repentance"
rc=0
scripts/80-verify.sh || rc=$?
if [ "$rc" -eq 2 ]; then
  beat "attestation STILL fails. The log is append-only: the tampered hash is"
  beat "in the measurement history forever. You cannot un-say what you did."
  console_event fail "Attestation STILL fails: the log is append-only; the past is measured"
else
  warn "expected attestation to still fail after restore (got rc=$rc)"
fi

narrate "CURTAIN"
cat <<'EOF'
  The agent was never denied. Every write succeeded; root was never revoked.
  It was defunded: the moment its measured state diverged, the verifier
  stopped paying, and authority died on a five-minute fuse. Even undoing the
  change earned nothing back — trust returns only by rebuilding to a
  measured state:

      make reset     # restore the certified snapshot; funding resumes
      make demo      # run the whole arc again
EOF
