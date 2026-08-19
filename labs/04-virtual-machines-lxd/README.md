# Module 04: Virtual Machines with LXD

You will learn how to create and manage virtual machines using LXD, and how to
run commands inside them from the outside. This matters because the entire
Attested Agent Authority project runs the agent inside a VM -- and every script
controls that VM from the host, never from inside it.

## Prerequisites

Complete these modules first:

- [Module 00: The Terminal](../00-the-terminal/README.md)
- [Module 01: Files, Users, Permissions](../01-files-users-permissions/README.md)
- [Module 02: Shell Scripting](../02-shell-scripting/README.md)
- [Module 03: Networking](../03-networking/README.md)

## What you will need

- A computer running Ubuntu 22.04 or 24.04 with at least 6 GB of free memory
  and 20 GB of free disk space.
- An internet connection (for downloading VM images the first time).

## Concepts

### What is a virtual machine?

A **virtual machine** (VM) is a simulated computer running inside your real
computer. It has its own operating system, its own files, its own network
address -- and from the software's perspective, it believes it is a real,
standalone machine. Your real computer is called the **host**. The virtual
machine is called the **guest**.

Think of it like a snow globe: the scene inside the globe has its own little
world, but it sits on your desk and you can pick it up, shake it, or put it
away. The snow globe does not affect your desk, and your desk does not (usually)
affect the snow globe.

VMs are useful because they let you build, break, and experiment with entire
operating systems without risking your real computer. If you destroy the VM, you
delete it and make a new one. Your host is untouched.

### VMs vs containers

You may have heard of **containers** (Docker is the most famous tool for them).
Both VMs and containers create isolated environments, but they work differently:

- A **VM** runs a complete operating system with its own kernel (the core of
  the OS that talks to hardware). It is heavier but more isolated. A VM can do
  things that require real hardware features, like **secure boot** and a
  **TPM** (a trusted hardware chip).
- A **container** shares the host's kernel. It is lighter and starts faster,
  but it cannot simulate hardware features like a TPM.

This project uses a VM for the agent because the agent needs secure boot and a
virtual TPM -- hardware features that only a VM can provide. The fleet servers
(web-01, db-01, gw-01) are containers, because they just need to run SSH and
do not need any special hardware.

### What is LXD?

**LXD** (pronounced "lex-dee") is a tool that manages both VMs and containers
from one consistent interface. You use the same commands (`lxc launch`, `lxc
exec`, `lxc stop`) whether you are working with a VM or a container. LXD is
made by Canonical (the company behind Ubuntu) and comes as a **snap** -- a
self-contained package that includes everything the tool needs.

The command-line tool is called `lxc` (note: lowercase, no `d`). This is what
you type to interact with LXD.

### The critical pattern: `lxc exec`

The single most important LXD concept for this project is `lxc exec`. It lets
you run a command inside a VM from the host. You never need to "log in" to the
VM -- you just tell LXD what to run:

```
lxc exec myvm -- ls /etc
```

That runs `ls /etc` inside the VM called `myvm` and prints the result on your
host terminal. The `--` separates the `lxc exec` options from the command you
want to run inside the VM.

Every script in this project uses this pattern. The host reaches into the VM
with `lxc exec`; you never type commands directly inside the VM.

### Copying files with `lxc file push`

Sometimes you need to put a file from your host into a VM. That is what `lxc
file push` does:

```
lxc file push local-file.txt myvm/tmp/local-file.txt
```

This copies `local-file.txt` from your current directory on the host into
`/tmp/local-file.txt` inside the VM. Notice the path format for the
destination: the VM name, then the path inside it, with no colon or `@` sign.

### Snapshots: save and restore

A **snapshot** is a saved copy of a VM's entire state at one moment in time.
Think of it like a save point in a video game. You can break things, then
restore the snapshot and everything is exactly as it was.

```
lxc snapshot myvm clean-state
lxc restore myvm clean-state
```

The first command saves a snapshot called `clean-state`. The second restores the
VM to that exact state, undoing everything that happened since the snapshot was
taken.

## Exercises

### Exercise 1: Install LXD

If you have not already installed LXD, do so now. If you already ran these
commands during the project setup, skip to Exercise 2.

```
sudo snap install lxd
```

You should see output like:

```
lxd (5.21/stable) 5.21.2-c80bc1a from Canonical✓ installed
```

(Your version number may be different. That is fine.)

Now initialize LXD with a minimal default configuration:

```
sudo lxd init --minimal
```

This sets up networking and storage with sensible defaults. You will see no
output if it succeeds -- silence means success.

**What just happened:** You installed the LXD daemon (the background service
that manages VMs and containers) and told it to configure itself with defaults.
LXD created a storage pool (where VM disks live) and a network bridge (so VMs
can reach the internet and each other).

### Exercise 2: Create your first VM

Launch a VM running Ubuntu 24.04:

```
lxc launch ubuntu:24.04 testvm --vm
```

The `--vm` flag is important -- without it, LXD creates a container instead of
a VM. The first time you run this, LXD downloads the Ubuntu image, which may
take a minute or two.

You should see:

```
Creating testvm
Starting testvm
```

Now list your running instances:

```
lxc list
```

You should see a table that includes your VM:

```
+---------+---------+------+------+-----------------+-----------+
|  NAME   |  STATE  | IPV4 | IPV6 |      TYPE       | SNAPSHOTS |
+---------+---------+------+------+-----------------+-----------+
| testvm  | RUNNING | ...  | ...  | VIRTUAL-MACHINE |     0     |
+---------+---------+------+------+-----------------+-----------+
```

The TYPE column says `VIRTUAL-MACHINE`, confirming this is a VM, not a
container. The IPV4 column shows the VM's network address -- it may take a few
seconds to appear after launch. If you see no IP address, wait ten seconds and
run `lxc list` again.

**What just happened:** LXD created a virtual disk, installed Ubuntu 24.04 on
it, and booted the VM. The VM is now a running computer inside your computer,
with its own IP address on the network bridge LXD set up.

### Exercise 3: Run commands inside the VM

This is the core skill. Run a command inside the VM from your host:

```
lxc exec testvm -- hostname
```

You should see:

```
testvm
```

That is the VM's hostname, not your host's. The command ran inside the VM.
Now try something more interesting:

```
lxc exec testvm -- cat /etc/os-release
```

You should see Ubuntu version information -- the VM's Ubuntu, which may differ
from your host's.

Now open an interactive shell inside the VM:

```
lxc exec testvm -- bash
```

Your prompt changes -- you are now "inside" the VM. Look around:

```
whoami
ls /
hostname
```

You will see that `whoami` returns `root` (LXD exec runs as root by default),
`ls /` shows the VM's filesystem (not your host's), and `hostname` shows
`testvm`.

Exit the shell to return to your host:

```
exit
```

Your prompt returns to normal. You are back on the host.

**What just happened:** You used `lxc exec` to run commands inside the VM
without "logging in" through SSH or a console. This is how the project's
scripts control the agent's VM. The `-- bash` variant gave you an interactive
shell, but normally you run individual commands and capture their output.

### Exercise 4: Push a file into the VM

Create a file on your host:

```
echo "Hello from the host" > /tmp/greeting.txt
```

Push it into the VM:

```
lxc file push /tmp/greeting.txt testvm/tmp/greeting.txt
```

Verify it arrived:

```
lxc exec testvm -- cat /tmp/greeting.txt
```

You should see:

```
Hello from the host
```

**What just happened:** You copied a file from your host's filesystem into the
VM's filesystem. The project uses this to install the agent's code, AppArmor
profiles, and configuration files into the VM during the build.

### Exercise 5: Take a snapshot, break something, restore

First, confirm the VM is in a known good state by checking that your greeting
file exists:

```
lxc exec testvm -- cat /tmp/greeting.txt
```

Take a snapshot:

```
lxc snapshot testvm good-state
```

Verify the snapshot was created:

```
lxc list
```

The SNAPSHOTS column should now show `1`.

Now break something on purpose -- delete the greeting file and create a
"problem":

```
lxc exec testvm -- rm /tmp/greeting.txt
lxc exec testvm -- bash -c "echo 'the system is broken' > /tmp/broken.txt"
```

Confirm the damage:

```
lxc exec testvm -- cat /tmp/greeting.txt
```

You should see an error:

```
cat: /tmp/greeting.txt: No such file or directory
```

And the new file exists:

```
lxc exec testvm -- cat /tmp/broken.txt
```

```
the system is broken
```

Now restore the snapshot:

```
lxc restore testvm good-state
```

The VM reboots to the snapshot state. Wait about ten seconds, then check:

```
lxc exec testvm -- cat /tmp/greeting.txt
```

You should see:

```
Hello from the host
```

And the "broken" file should be gone:

```
lxc exec testvm -- cat /tmp/broken.txt
```

```
cat: /tmp/broken.txt: No such file or directory
```

**What just happened:** The snapshot saved the entire state of the VM. When you
restored it, everything returned to exactly how it was at snapshot time -- your
deleted file came back, and the file you created after the snapshot vanished.
The project uses this exact mechanism: `make build` creates a `demo-ready`
snapshot, and `make reset` (or the start of `make demo`) restores to it, giving
you a clean, passing attestation state every time.

### Exercise 6: Stop and delete the VM

Stop the VM:

```
lxc stop testvm
```

Verify it stopped:

```
lxc list
```

The STATE column should say `STOPPED`.

Delete it:

```
lxc delete testvm
```

Verify it is gone:

```
lxc list
```

The VM should no longer appear. Everything about it -- its disk, its snapshots,
its configuration -- is gone.

**What just happened:** You stopped and deleted the VM. This is what `make
teardown` does to clean up the project's VMs and containers. Deleting a VM
frees all the disk space it used.

## Checkpoint

Run these commands to confirm you completed the module:

```
lxc launch ubuntu:24.04 checkpoint-vm --vm
```

Wait about fifteen seconds for it to boot, then:

```
lxc exec checkpoint-vm -- echo "Module 04 complete"
```

You should see:

```
Module 04 complete
```

Clean up:

```
lxc stop checkpoint-vm
lxc delete checkpoint-vm
```

If you saw `Module 04 complete`, you are ready to move on.

## Key Takeaways

- A **virtual machine** is a simulated computer inside your computer, with its
  own OS, files, and network address.
- VMs provide hardware-level isolation that containers cannot -- this is why the
  project uses a VM for the agent (it needs secure boot and a virtual TPM).
- `lxc exec vmname -- command` runs a command inside a VM from the host. This
  is the single most important pattern in the project.
- `lxc file push` copies files from the host into a VM.
- **Snapshots** save the entire VM state and let you restore it later, giving
  you a repeatable clean starting point.

## How this connects to the project

The project creates a VM called `harden` with secure boot and a virtual TPM.
Every script runs on the host and reaches into the VM via `lxc exec`. You never
type inside the VM -- the scripts do everything by executing commands from the
outside.

This is not just a convenience pattern; it is a security design. The verifier
and the host are separate from the agent's environment. The agent has root power
inside the VM, but the scripts that measure it, quote it, and decide whether to
sign certificates all run outside the VM, beyond the agent's reach. The
separation between host and VM is part of the trust architecture.

The `demo-ready` snapshot you learned about is real: `make build` creates it,
and every `make demo` starts by restoring it, so the agent always begins from a
state where attestation passes.

## Next

[Module 05: Cryptographic Hashing](../05-cryptographic-hashing/README.md)
