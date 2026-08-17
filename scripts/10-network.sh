#!/usr/bin/env bash
# 10-network.sh — create the fleet bridge with pinned addressing.
#
# Prerequisite: 00-preflight.sh passed.
# DHCP reassigns the workload VM's address on every rebuild, which silently
# breaks the verifier's SSH target. The network is created here; the VM's
# address is pinned in 20-workload.sh via a NIC device override.

cd "$(dirname "$0")/.." || exit 1
. scripts/lib/common.sh
guard_host
need lxc "lxd (snap)"

if lxc network show "$AAA_NET" >/dev/null 2>&1; then
  log "network $AAA_NET already exists"
else
  lxc network create "$AAA_NET" \
    ipv4.address="$AAA_NET_CIDR" ipv4.nat=true ipv6.address=none
  ok "created network $AAA_NET ($AAA_NET_CIDR, NAT, no IPv6)"
fi

# verify outcome: the bridge must exist and carry the expected subnet
have=$(lxc network get "$AAA_NET" ipv4.address)
[ "$have" = "$AAA_NET_CIDR" ] || \
  die "network $AAA_NET has address $have, expected $AAA_NET_CIDR" \
      "a previous run created it differently" \
      "scripts/teardown.sh && scripts/10-network.sh"

ok "network $AAA_NET verified — next: scripts/20-workload.sh"
