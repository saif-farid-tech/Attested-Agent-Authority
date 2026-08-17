#!/usr/bin/env bash
# 60-fleet.sh — three fleet hosts that trust nothing but the CA.
#
# Prerequisites: 10-network.sh (bridge), 20-workload.sh ($AAA_STATE exists).
#
# bug #6, all three lessons baked in:
#   - the CA PUBLIC key is pushed to each host
#   - sshd trusts it via TrustedUserCAKeys — NOT @cert-authority, which
#     lives in known_hosts and governs HOST keys, a different mechanism
#   - the `harden` user must exist on each fleet host

cd "$(dirname "$0")/.." || exit 1
. scripts/lib/common.sh
. scripts/lib/detect.sh
guard_host
need lxc "lxd (snap)"
lxc network show "$AAA_NET" >/dev/null 2>&1 || die "network $AAA_NET missing" \
  "it is created by scripts/10-network.sh" "scripts/10-network.sh"
mkdir -p "$AAA_STATE"

# ---- the SSH user CA -------------------------------------------------------
# Generated on the host, project-local. In the full design this key lives on
# an immutable Ubuntu Core verifier box; see docs/ARCHITECTURE.md.
if [ ! -f "$AAA_STATE/ssh_ca" ]; then
  ssh-keygen -q -t ed25519 -N '' -C 'attested-agent-authority CA' -f "$AAA_STATE/ssh_ca"
  ok "SSH user CA created at $AAA_STATE/ssh_ca"
else
  log "SSH user CA already exists"
fi

# ---- three fleet containers ------------------------------------------------
for host in "${AAA_FLEET[@]}"; do
  if instance_exists "$host"; then
    log "instance $host already exists"
  else
    lxc launch ubuntu:24.04 "$host" --network "$AAA_NET"
    ok "launched container $host"
  fi

  # ---- pin the address (bug #16) -------------------------------------------
  # The VM learns these addresses once, into an /etc/hosts that is frozen into
  # the demo-ready snapshot. Under DHCP a restarted container could come back
  # on a different lease, and the snapshot then pointed the agent at nothing:
  # a demo that worked last week failing today for no visible reason.
  want=${AAA_FLEET_ADDR[$host]}
  nicdev=$(lxc config show "$host" --expanded | \
           awk '/^  [a-z0-9]+:$/{d=$1} /type: nic/ && !found {gsub(":","",d); print d; found=1}')
  [ -n "$nicdev" ] || die "$host has no NIC device" \
      "the container's expanded config lists no nic" \
      "lxc config show $host --expanded  # then re-run"
  if [ "$(lxc config device get "$host" "$nicdev" ipv4.address 2>/dev/null)" = "$want" ]; then
    log "$host address already pinned to $want"
  else
    lxc config device override "$host" "$nicdev" ipv4.address="$want" 2>/dev/null || \
      lxc config device set "$host" "$nicdev" ipv4.address="$want"
    lxc restart "$host" >/dev/null 2>&1 || true
    ok "pinned $host to $want on device $nicdev"
  fi

  for _ in $(seq 1 30); do
    lxc exec "$host" -- true >/dev/null 2>&1 && break; sleep 2
  done

  lxc exec "$host" -- sh -c '
    command -v sshd >/dev/null || { export DEBIAN_FRONTEND=noninteractive
                                    apt-get update -q && apt-get install -qy openssh-server; }
    id harden >/dev/null 2>&1 || useradd -m -s /bin/bash harden
    printf "harden ALL=(ALL) NOPASSWD:ALL\n" > /etc/sudoers.d/harden
    chmod 0440 /etc/sudoers.d/harden'

  lxc file push "$AAA_STATE/ssh_ca.pub" "$host/etc/ssh/attested_ca.pub"
  lxc exec "$host" -- sh -c '
    grep -q "^TrustedUserCAKeys /etc/ssh/attested_ca.pub" /etc/ssh/sshd_config || \
      echo "TrustedUserCAKeys /etc/ssh/attested_ca.pub" >> /etc/ssh/sshd_config
    # certificates or nothing: no passwords, no plain authorized_keys
    grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config || \
      echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
    systemctl restart ssh || systemctl restart sshd'
  ok "$host: user harden, CA trusted via TrustedUserCAKeys, sshd restarted"
done

# ---- verify outcome --------------------------------------------------------
for host in "${AAA_FLEET[@]}"; do
  lxc_says "trustedusercakeys /etc/ssh/attested_ca.pub" exec "$host" -- sshd -T || \
    die "$host: sshd is not trusting the CA" \
        "TrustedUserCAKeys did not take effect" \
        "lxc exec $host -- sshd -T | grep -i trusted  # inspect, then re-run"
  # An address can take a few seconds to surface after a restart; ask again
  # rather than failing the build on a race (bug #16).
  addr=""
  for _ in $(seq 1 30); do
    addr=$(detect_fleet_addr "$host")
    [ -n "$addr" ] && break
    sleep 2
  done
  [ -n "$addr" ] || die "$host has no IPv4 address" "networking on $AAA_NET failed" \
      "lxc restart $host && re-run"
  [ "$addr" = "${AAA_FLEET_ADDR[$host]}" ] || \
    warn "$host answers on $addr, pin is ${AAA_FLEET_ADDR[$host]} — 'lxc restart $host' then re-run"
  log "$host at $addr"
done
ok "fleet ready: ${AAA_FLEET[*]} trust only certificates signed by $AAA_STATE/ssh_ca"
ok "next: scripts/70-baseline.sh"
