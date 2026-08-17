#!/usr/bin/env bash
# 50-agent.sh — deploy the Harden agent and its dependencies into the VM.
#
# Prerequisites: 40-apparmor.sh (profile loaded; it names the agent's path).

cd "$(dirname "$0")/.." || exit 1
. scripts/lib/common.sh
. scripts/lib/detect.sh
guard_host
need lxc "lxd (snap)"
require_script agent/agent.py "the repository checkout (agent/agent.py)"
instance_exists "$AAA_VM" || die "VM $AAA_VM missing" \
  "it is created by scripts/20-workload.sh" "scripts/20-workload.sh"
wait_vm_ready

# ---- agent code ------------------------------------------------------------
vm_exec mkdir -p "$AAA_VM_STATE"
vm_push agent/agent.py "$AAA_VM_STATE/agent.py"
vm_exec sh -c "chmod 755 $AAA_VM_STATE/agent.py && chown harden:harden $AAA_VM_STATE"
ok "agent deployed to $AAA_VM_STATE/agent.py"
warn "NOTE: every future edit of agent.py changes its IMA hash — run 'make rebaseline' after (bug #10)"

# ---- agent SSH identity (certificate arrives from the verifier later) ------
vm_exec sh -c 'sudo -u harden sh -c "
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N \"\" -C harden-agent -f ~/.ssh/id_ed25519"'
lxc file pull "$AAA_VM/home/harden/.ssh/id_ed25519.pub" "$AAA_STATE/harden_key.pub"
ok "agent key generated; public half exported to $AAA_STATE/harden_key.pub"

# ---- configuration ---------------------------------------------------------
# model_endpoint points at a llama.cpp server on the host bridge address.
# The agent treats an unreachable or empty model as a normal, one-line
# condition (bug #8) and falls back to its fixed playbook.
host_gw=${AAA_NET_CIDR%/*}
tmp_cfg=$(mktemp)
python3 - "$tmp_cfg" "$host_gw" <<'EOF'
import json, sys
fleet = ["web-01", "db-01", "gw-01"]
json.dump({"fleet": fleet,
           "model_endpoint": f"http://{sys.argv[2]}:8080/completion"},
          open(sys.argv[1], "w"), indent=2)
EOF
# bug #12: lxc file push preserves the mktemp source mode (0600 root), which
# leaves the config unreadable by the harden user that runs the agent. State
# the mode and owner explicitly instead of inheriting mktemp's.
vm_push "$tmp_cfg" "$AAA_VM_STATE/config.json" 0644 harden:harden
rm -f "$tmp_cfg"
vm_exec sh -c "chown harden:harden $AAA_VM_STATE/agent.py"
ok "agent config written (fleet + model endpoint http://$host_gw:8080)"

# ---- verify outcome --------------------------------------------------------
vm_exec sh -c "python3 -m py_compile $AAA_VM_STATE/agent.py" || \
  die "agent.py does not compile inside the VM" \
      "the deployed file is corrupt or python is missing" \
      "re-run scripts/50-agent.sh"
vm_exec sh -c "python3 -c 'import json; json.load(open(\"$AAA_VM_STATE/config.json\"))'" || \
  die "config.json is not valid JSON" "the push was truncated" "re-run scripts/50-agent.sh"
ok "agent verified in place — next: scripts/60-fleet.sh"
