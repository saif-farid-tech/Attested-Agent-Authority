# Module 03: Networking

You will learn how computers find and talk to each other on a network: IP
addresses, ports, network interfaces, bridges, and the difference between
dynamic and static addressing. This matters for the final project because it
builds a private network called `fleet0` with pinned addresses so the
verifier always knows where to find the VM, and the agent always knows where
to find the fleet servers.

## Prerequisites

- [Module 00: The Terminal](../00-the-terminal/README.md)
- [Module 01: Files, Users, Permissions](../01-files-users-permissions/README.md)
- [Module 02: Shell Scripting](../02-shell-scripting/README.md)

## What you will need

- The same Ubuntu machine from previous modules.
- A working internet connection (for the ping exercises).

## Concepts

### What is an IP address?

An **IP address** is a number that identifies a computer on a network. Think
of it as a street address for machines. Just as a postal service uses your
street address to find your house, the network uses IP addresses to route
data to the right computer.

An IPv4 address looks like four numbers separated by dots:

```
192.168.1.100
```

Each number is between 0 and 255. Some addresses are special:

- **127.0.0.1** — This is called **localhost** or the **loopback address**.
  It always refers to the machine you are sitting at. When you send data to
  127.0.0.1, it goes to yourself. This is useful for testing.

- **10.x.x.x**, **172.16-31.x.x**, **192.168.x.x** — These are **private
  addresses**. They are used inside local networks (your home, an office, a
  virtual lab) and are not reachable from the internet. The project uses
  `10.147.0.x` for its private network.

### What is a port?

If an IP address is a street address, a **port** is an apartment number. A
single computer can run many network services at the same time — a web
server, an SSH server, a database — and each one listens on a different port
number. Port numbers range from 0 to 65535.

Common port numbers:

- **22** — SSH (secure remote login)
- **80** — HTTP (web traffic)
- **443** — HTTPS (encrypted web traffic)
- **9000** — used by the project's console web UI

When you connect to a server, you specify both the address and the port. For
example, `ssh alice@10.147.0.10` connects to port 22 (the default for SSH) on
the machine at address `10.147.0.10`.

### Network interfaces

A **network interface** is a connection point between your computer and a
network. Physical interfaces correspond to hardware — your ethernet cable or
your Wi-Fi card. But interfaces can also be virtual — software-defined
connections that exist only inside the computer.

Every Linux machine has at least one special interface called **lo** (the
loopback interface), which carries traffic to and from localhost (127.0.0.1).

The `ip addr` command shows you all the interfaces on your machine and what
addresses are assigned to each one. You will see output like:

```
1: lo: <LOOPBACK,UP> ...
    inet 127.0.0.1/8 ...
2: enp0s3: <BROADCAST,MULTICAST,UP> ...
    inet 192.168.1.100/24 ...
```

This tells you: interface `lo` has address 127.0.0.1, and interface `enp0s3`
(a physical ethernet port) has address 192.168.1.100.

### What is a bridge?

A **bridge** is a virtual network switch. If you have several virtual
machines and you want them to talk to each other (and optionally to the
outside world), you create a bridge and attach each VM to it. The bridge
forwards traffic between them, just as a physical switch connects physical
cables.

The Attested Agent Authority project creates a bridge called `fleet0`. The
workload VM and three fleet containers are all attached to this bridge, so
they can reach each other over the network. The bridge also does NAT (Network
Address Translation), which lets the VMs access the internet through the host
machine's connection.

### DHCP vs static addresses

When a machine joins a network, it needs an IP address. There are two ways to
get one:

**DHCP** (Dynamic Host Configuration Protocol) — The machine asks the network
for an address, and a DHCP server assigns one automatically. This is how your
laptop gets its address on your home Wi-Fi. The problem: the address can
change. If the DHCP server gives your machine 10.147.0.15 today and
10.147.0.23 tomorrow, anything that was configured to connect to
10.147.0.15 will break.

**Static addressing** — The machine is given a specific, fixed address. It
always has the same one. This is what servers use, and it is what the project
uses for the VM and fleet containers.

The project pins the VM's address to `10.147.0.10` and each fleet container
to its own fixed address (`10.147.0.11`, `.12`, `.13`). This way, the
verifier's SSH commands always connect to the same address, and the agent's
fleet connections always reach the right hosts. Early versions of the project
used DHCP, and the demo would break after a reboot because the VM got a
different address.

### The /8, /24 notation (CIDR)

You will often see addresses written with a slash and a number after them,
like `10.147.0.1/24`. This notation (called **CIDR**, for Classless
Inter-Domain Routing) tells you both the address and the size of the network.

The number after the slash says how many bits of the address identify the
network. In practice:

- **/24** means the first three numbers identify the network and the last
  number identifies the machine. So `10.147.0.x` is the network, and you can
  have machines numbered 1 through 254. This is the most common size for
  small networks.
- **/8** means only the first number identifies the network (like
  `127.x.x.x` for loopback).

The project uses `10.147.0.1/24`, which means the bridge network is
`10.147.0.x` and can hold up to 254 machines.

## Exercises

### Exercise 1: Find your IP address

Run the following command to see all network interfaces and their addresses:

```
ip addr
```

**Expected output:** Several blocks of text, one per network interface. Look
for lines containing `inet` — those show IPv4 addresses. You will see at
least:

```
1: lo: <LOOPBACK,UP,LOWER_UP> ...
    inet 127.0.0.1/8 scope host lo
```

and one or more additional interfaces with your machine's actual IP address.
The interface names vary: `enp0s3`, `ens33`, `eth0`, `wlp2s0` for Wi-Fi,
among others.

**What just happened:** `ip addr` listed every network interface on your
machine, along with its IP addresses and other details. The `lo` interface
(loopback) is always present and always has 127.0.0.1.

### Exercise 2: Find only your IP addresses

The full output of `ip addr` is verbose. To see just the addresses, use:

```
ip -brief addr
```

**Expected output:** A compact table like:

```
lo               UNKNOWN        127.0.0.1/8 ::1/128
enp0s3           UP             192.168.1.100/24
```

**What just happened:** The `-brief` flag gave you a one-line summary per
interface: the name, its state (UP/DOWN/UNKNOWN), and the addresses assigned
to it. This is the quickest way to check your machine's addresses.

### Exercise 3: Test connectivity with ping

The `ping` command sends a small packet to another machine and waits for a
reply. It is the most basic test of network connectivity: can this machine
reach that one?

Ping yourself (localhost):

```
ping -c 4 127.0.0.1
```

The `-c 4` flag says "send four packets and stop" (without it, ping runs
forever until you press `Ctrl` + `C`).

**Expected output:**

```
PING 127.0.0.1 (127.0.0.1) 56(84) bytes of data.
64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=0.042 ms
64 bytes from 127.0.0.1: icmp_seq=2 ttl=64 time=0.035 ms
64 bytes from 127.0.0.1: icmp_seq=3 ttl=64 time=0.030 ms
64 bytes from 127.0.0.1: icmp_seq=4 ttl=64 time=0.029 ms

--- 127.0.0.1 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3004ms
```

The key numbers: 4 transmitted, 4 received, 0% loss. That means every packet
got a reply.

**What just happened:** Your machine sent four test packets to itself (via
the loopback interface) and received four replies. This confirms the
networking stack is working.

### Exercise 4: Ping an external address

Ping a well-known public DNS server:

```
ping -c 4 8.8.8.8
```

**Expected output** (if you have an internet connection):

```
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=117 time=12.3 ms
64 bytes from 8.8.8.8: icmp_seq=2 ttl=117 time=11.8 ms
64 bytes from 8.8.8.8: icmp_seq=3 ttl=117 time=12.1 ms
64 bytes from 8.8.8.8: icmp_seq=4 ttl=117 time=11.9 ms

--- 8.8.8.8 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3005ms
```

Notice the `time` values are much higher than when you pinged localhost
(milliseconds instead of fractions of a millisecond). That is the round-trip
time for the packet to travel across the internet to Google's server and back.

If you see `100% packet loss` or `Network is unreachable`, your machine
cannot reach the internet. Check your network connection.

**What just happened:** Your machine sent test packets across the internet to
Google's public DNS server at 8.8.8.8 and received replies. This confirms
your machine can reach the outside world.

### Exercise 5: See what is listening on your machine

The `ss` command shows network connections and listening sockets. To see
which programs are listening for incoming connections:

```
ss -tlnp
```

The flags mean:

- `-t` — show TCP connections (the most common type)
- `-l` — show only listening sockets (waiting for connections)
- `-n` — show port numbers instead of service names
- `-p` — show the process (program) that owns each socket

**Expected output:** A table showing listening ports. You may need `sudo` to
see all process names:

```
sudo ss -tlnp
```

**Expected output:** Something like:

```
State    Recv-Q   Send-Q   Local Address:Port   Peer Address:Port   Process
LISTEN   0        128      0.0.0.0:22           0.0.0.0:*           users:(("sshd",pid=1234,fd=3))
LISTEN   0        5        127.0.0.1:631        0.0.0.0:*           users:(("cupsd",pid=5678,fd=7))
```

This tells you: the SSH server (`sshd`) is listening on port 22 on all
interfaces (`0.0.0.0`), and the print server (`cupsd`) is listening on port
631 but only on localhost (`127.0.0.1`). Your output will vary depending on
what services are running on your machine.

**What just happened:** `ss -tlnp` showed you every program that is waiting
for incoming network connections, which port it is using, and which addresses
it is accepting connections from. This is how you check whether a service is
running and reachable.

### Exercise 6: Understand the loopback vs real interfaces

Run this command to see your interfaces more clearly:

```
ip link show
```

**Expected output:** A list of interfaces with their state (UP or DOWN) and
type. For example:

```
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
2: enp0s3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT
    link/ether 08:00:27:ab:cd:ef brd ff:ff:ff:ff:ff:ff
```

The `link/ether` line on your real interface shows its **MAC address** — a
hardware identifier unique to that network card. The loopback interface has
all zeros because it is not a physical device.

**What just happened:** `ip link show` listed your network interfaces with
their hardware-level details. The loopback (`lo`) is a virtual interface that
exists purely in software. Your other interface (the name varies) is the real
one that connects to a physical or virtual network.

### Exercise 7: Explore hostname and DNS

Your machine has a name as well as an address:

```
hostname
```

**Expected output:** Your machine's hostname (for example, `ubuntu-desktop`).

Check how your machine resolves names to addresses:

```
host google.com
```

**Expected output:**

```
google.com has address 142.250.80.46
google.com has IPv6 address 2607:f8b0:4004:800::200e
```

(The exact addresses will differ.)

If `host` is not installed, try:

```
getent hosts google.com
```

**What just happened:** The `host` command (or `getent`) asked a DNS server
to translate the name `google.com` into an IP address. DNS (Domain Name
System) is the internet's phone book — it maps human-readable names to
machine-readable addresses. When you type `ping google.com`, your machine
first looks up the address via DNS and then sends packets to that address.

### Exercise 8: Write a network check script

Bring together what you know. Create a script that checks your network:

```
cd ~/linux-labs
cat > netcheck.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Error on line $LINENO"' ERR

echo "=== Network Check ==="
echo ""

# Show hostname
echo "Hostname: $(hostname)"

# Show primary IP addresses
echo ""
echo "Interfaces:"
ip -brief addr

# Test local connectivity
echo ""
echo "Localhost ping:"
if ping -c 1 -W 2 127.0.0.1 > /dev/null 2>&1; then
    echo "  localhost: reachable"
else
    echo "  localhost: UNREACHABLE (this should never happen)"
fi

# Test internet connectivity
echo ""
echo "Internet connectivity:"
if ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1; then
    echo "  internet: reachable"
else
    echo "  internet: unreachable (check your connection)"
fi

# Show listening ports
echo ""
echo "Listening TCP ports:"
ss -tln | tail -n +2 | while read -r line; do
    echo "  $line"
done

echo ""
echo "=== Check complete ==="
SCRIPT

chmod +x netcheck.sh
./netcheck.sh
```

**Expected output:** A structured report showing your hostname, IP addresses,
localhost reachability (should be reachable), internet reachability (depends
on your connection), and a list of listening TCP ports.

**What just happened:** You wrote a script that uses everything from this
module — `hostname`, `ip addr`, `ping`, `ss` — to produce a quick network
status report. The script uses `set -euo pipefail` and a trap, as you learned
in Module 02. The `> /dev/null 2>&1` after the ping commands discards the
output (we only care about the exit code: did the ping succeed or fail?).

## Checkpoint

Run the following commands to verify you completed the module:

```
ip -brief addr | grep -c -v "^$"
```

Expected output: A number, at least 2 (the loopback interface and at least
one real interface).

```
ping -c 1 -W 2 127.0.0.1 > /dev/null 2>&1 && echo "localhost OK"
```

Expected output:

```
localhost OK
```

```
~/linux-labs/netcheck.sh
```

Expected: the script runs without errors and produces its network report.

If all three checks pass, you have completed this module.

## Key Takeaways

- An IP address identifies a machine on the network. A port identifies a
  specific service on that machine.
- `ip addr` shows your network interfaces and addresses. `ip -brief addr`
  gives a compact view.
- `ping` tests whether you can reach another machine. 0% packet loss means
  connectivity works.
- `ss -tlnp` shows which programs are listening for incoming connections and
  on which ports.
- A bridge is a virtual switch that connects virtual machines to each other
  and (optionally) to the outside world.
- Static addresses are fixed and predictable. DHCP addresses can change and
  break things that depend on a specific address.

## How this connects to the project

The project creates a bridge network called `fleet0` with the address range
`10.147.0.1/24`. This happens in `scripts/10-network.sh`, which runs:

```bash
lxc network create fleet0 ipv4.address=10.147.0.1/24 ipv4.nat=true
```

That single command creates a virtual bridge, gives it the address
10.147.0.1, and enables NAT so the VMs can reach the internet.

The workload VM is pinned to `10.147.0.10`. The fleet containers are pinned
to `10.147.0.11`, `10.147.0.12`, and `10.147.0.13`. These addresses are
defined in `scripts/lib/common.sh` and never change — every script that needs
to reach the VM or a fleet host uses these fixed addresses.

Early versions of the project used DHCP, and the demo would break after a
reboot because the VM came back on a different address. The verifier
connected to the old address, got no reply, and attestation failed — not
because of a real security event, but because a DHCP server handed out a
different number. Pinning the addresses (documented in CORRECTIONS.md as
bug #16) fixed this class of failure permanently.

The `ss -tlnp` command you used is also how the project checks whether the
SSH server inside the VM is ready. The readiness probe in `common.sh` looks
for something listening on port 22, because a VM whose SSH server is not yet
listening will refuse attestation connections even though the machine is
technically running.

## Next

[Module 04: Virtual Machines (LXD)](../04-virtual-machines-lxd/README.md)
