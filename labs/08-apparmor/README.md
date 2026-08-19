# Module 08: AppArmor -- Constraining Programs

You will learn how Linux can restrict what a program is allowed to do, even
when that program runs as root. This matters because the Attested Agent
Authority project gives an AI agent root inside its workload VM -- and then
uses AppArmor to draw a boundary around what root can touch. Without this
boundary, there is nothing to measure, and nothing to violate.

## Prerequisites

- Module 01: Files, Users, Permissions (you need to understand chmod, chown,
  and the idea of file permissions)
- Module 02: Shell Scripting (you will write a small script to test against)
- Module 04: Virtual Machines (you will work inside an LXD VM)

## What you will need

- Your Ubuntu host from previous modules, with LXD installed and working.
- An LXD VM (you will create one in Exercise 1).
- About 15-20 minutes.

## Concepts

### The problem with chmod and chown

In Module 01, you learned that Linux controls access to files using
permissions: the owner, the group, and everyone else each get read, write,
and execute bits. You also learned that the `root` user can override most of
these checks. Root can read any file, write any file, and run any program.

This is called **Discretionary Access Control (DAC)** -- "discretionary"
because the owner of a file decides who gets access. The problem is: if a
program runs as root, DAC has nothing to say. Root is above the permission
system. A root process can read `/etc/shadow`, rewrite system configs, or
delete the entire filesystem. The permissions you set with `chmod` are
irrelevant when the user IS root.

For the Attested Agent Authority project, this is the core problem. The agent
runs as root inside its VM. It needs root to do its job -- installing
packages, editing config files, restarting services across the fleet. But if
root can do anything, how do you constrain the agent at all?

### Mandatory Access Control (MAC)

The answer is **Mandatory Access Control** -- a system where the kernel
enforces rules that even root cannot bypass at runtime. The key word is
"mandatory": the rules are not up to the user or the process. The kernel
consults a policy before allowing any access, regardless of who is asking.

On Ubuntu, the MAC system is **AppArmor**. It ships with every Ubuntu
installation and is enabled by default.

### AppArmor profiles

An AppArmor profile is a text file that describes exactly what one program is
allowed to do. Think of it as a whitelist: the profile lists every file the
program may read, write, or execute, every network operation it may perform,
and every capability it may use. Anything not on the list is denied.

Profiles live in `/etc/apparmor.d/` and are named after the program they
confine (with slashes replaced by dots, so a profile for `/usr/bin/curl`
would be named `usr.bin.curl`).

### Profile syntax

Here is a minimal AppArmor profile:

```
abi <abi/3.0>,
include <tunables/global>

profile myprogram /usr/local/bin/myprogram {
  include <abstractions/base>

  /usr/local/bin/myprogram r,
  /var/lib/mydata/ r,
  /var/lib/mydata/** r,

  deny /etc/shadow rwx,
}
```

The key parts:

- **`profile myprogram /usr/local/bin/myprogram`** -- the profile's name and
  the executable it applies to.
- **`/var/lib/mydata/ r,`** -- the program may read the directory listing.
- **`/var/lib/mydata/** r,`** -- the program may read any file inside that
  directory (the `**` glob matches everything underneath).
- **`deny /etc/shadow rwx,`** -- explicitly deny all access to this file.
  (Anything not listed is already denied, but explicit denies are useful for
  documentation and for overriding rules from included abstractions.)

The permission letters:

| Letter | Meaning |
|--------|---------|
| `r` | Read |
| `w` | Write |
| `rw` | Read and write |
| `x` | Execute (generic) |
| `ix` | Execute and inherit this profile's confinement |
| `px` | Execute under that program's own profile |

The `ix` and `px` distinction matters when your confined program launches
another program. With `ix`, the child inherits the parent's restrictions.
With `px`, the child runs under its own separate profile (which must exist).

### The glob gotcha

AppArmor uses its own glob syntax, and it has a sharp edge you need to know.
The glob `*` does NOT match a dot at a path-component boundary in the way you
might expect. Specifically:

```
/usr/bin/python3*
```

This matches `/usr/bin/python3` and `/usr/bin/python310` -- but it does
**not** match `/usr/bin/python3.14`. The `*` will not cross the dot. If
your system has Python 3.14, the profile silently fails to cover it.

The fix is the brace pattern:

```
/usr/bin/python3{,.*}
```

This matches `/usr/bin/python3` (the empty alternative before the comma) and
`/usr/bin/python3.14` and `/usr/bin/python3.12` (the `.*` alternative). The
project's own profile uses this exact pattern because of this gotcha.

### Profile modes: enforce vs complain

A loaded profile operates in one of two modes:

- **Enforce** -- violations are blocked and logged. This is the production
  mode.
- **Complain** -- violations are logged but allowed. This is useful for
  developing a profile: you can see what would be blocked without actually
  breaking anything.

You can see which mode each profile is in with `aa-status`.

### Key commands

- **`aa-status`** -- shows all loaded profiles and their modes.
- **`apparmor_parser -r /etc/apparmor.d/profilename`** -- reload a profile
  from disk (apply changes you made to the file).
- **`aa-enforce /etc/apparmor.d/profilename`** -- switch a profile to enforce
  mode.
- **`aa-complain /etc/apparmor.d/profilename`** -- switch a profile to
  complain mode.

### The critical insight

Root can edit the profile file. Root can reload it with `apparmor_parser`.
AppArmor enforces whatever profile is currently loaded, but nothing in
AppArmor stops root from loading something more permissive. The constraint
is only as strong as the file on disk -- and root controls that file.

That is why AppArmor alone is not enough. You need something that NOTICES
when the profile changes. That is IMA (Module 10) and the TPM (Module 09).

## Exercises

### Exercise 1: Create a VM for AppArmor experiments

Create a fresh VM to work in. AppArmor is a kernel feature, and you want an
environment where you can experiment freely.

```
lxc launch ubuntu:24.04 apparmor-lab --vm
```

Wait about 30 seconds for the VM to boot, then open a shell inside it:

```
lxc exec apparmor-lab -- bash
```

**Expected output:** You are now at a root shell inside the VM. Your prompt
changes to something like `root@apparmor-lab:~#`.

Install the AppArmor utilities you will need:

```
apt-get update -q && apt-get install -qy apparmor-utils
```

**What just happened:** You created an Ubuntu VM and installed the tools for
managing AppArmor profiles. AppArmor itself is already in the kernel -- these
tools just make it easier to work with.

### Exercise 2: See what AppArmor is doing right now

From inside the VM, check the current AppArmor status:

```
aa-status
```

**Expected output:** A list of loaded profiles grouped by mode (enforce or
complain). On a fresh Ubuntu VM, you will see several profiles already
loaded -- things like `lsb_release`, `nvidia_modprobe`, and others that
ship with Ubuntu. The exact list depends on your Ubuntu version.

Look at the output. You will see lines like:

```
N profiles are loaded.
N profiles are in enforce mode.
...
N processes have profiles defined.
N processes are in enforce mode.
```

**What just happened:** Ubuntu ships with AppArmor profiles for many system
programs. These profiles have been silently constraining those programs since
the VM booted. You never noticed because that is how MAC works -- it is
invisible when everything stays within bounds.

### Exercise 3: Write a script to confine

Create a simple script that reads from two different directories. You will
then write an AppArmor profile that allows one and blocks the other.

First, set up the directories and the script:

```
mkdir -p /opt/allowed-data /opt/secret-data
echo "this is public" > /opt/allowed-data/info.txt
echo "this is secret" > /opt/secret-data/credentials.txt
```

Now create the script:

```
cat > /usr/local/bin/reader.sh << 'SCRIPT'
#!/bin/bash
echo "--- Reading allowed data ---"
cat /opt/allowed-data/info.txt

echo "--- Reading secret data ---"
cat /opt/secret-data/credentials.txt

echo "--- Done ---"
SCRIPT
chmod +x /usr/local/bin/reader.sh
```

Run it without any AppArmor profile:

```
/usr/local/bin/reader.sh
```

**Expected output:**

```
--- Reading allowed data ---
this is public
--- Reading secret data ---
this is secret
--- Done ---
```

**What just happened:** Without an AppArmor profile, the script can read
both directories. It runs as root, and root can read everything. DAC does
not help here.

### Exercise 4: Write an AppArmor profile

Now write a profile that allows the script to read `/opt/allowed-data/` but
denies access to `/opt/secret-data/`:

```
cat > /etc/apparmor.d/usr.local.bin.reader.sh << 'PROFILE'
abi <abi/3.0>,
include <tunables/global>

profile reader /usr/local/bin/reader.sh {
  include <abstractions/base>
  include <abstractions/bash>

  /usr/local/bin/reader.sh r,
  /usr/bin/bash ix,
  /usr/bin/cat ix,

  /opt/allowed-data/ r,
  /opt/allowed-data/** r,

  deny /opt/secret-data/ rwx,
  deny /opt/secret-data/** rwx,
}
PROFILE
```

Load the profile:

```
apparmor_parser -r /etc/apparmor.d/usr.local.bin.reader.sh
```

**Expected output:** No output means success.

Verify it loaded:

```
aa-status | grep reader
```

**Expected output:** A line showing `reader` in enforce mode:

```
   reader
```

**What just happened:** You wrote an AppArmor profile that whitelists
`/opt/allowed-data/` for reading, explicitly denies `/opt/secret-data/`,
and allows the script to execute `bash` and `cat` (which it needs to
function). You loaded it into the kernel with `apparmor_parser`.

### Exercise 5: See the denial

Run the script again:

```
/usr/local/bin/reader.sh
```

**Expected output:**

```
--- Reading allowed data ---
this is public
--- Reading secret data ---
cat: /opt/secret-data/credentials.txt: Permission denied
--- Done ---
```

The first read succeeded. The second was blocked -- even though you are root.

Now check the system log for the denial:

```
journalctl -k | grep DENIED | tail -5
```

**Expected output:** A line like:

```
audit: type=1400 ... apparmor="DENIED" operation="open" profile="reader" name="/opt/secret-data/credentials.txt" ...
```

**What just happened:** AppArmor blocked root from reading a file. The
kernel checked the profile before allowing the `open()` system call,
found no rule permitting access to `/opt/secret-data/credentials.txt`,
found an explicit deny, and refused the operation. It logged the denial
to the kernel audit log. This is mandatory access control in action --
the policy overrides root's privileges.

### Exercise 6: Modify the profile and reload

Now suppose you decide the script should be allowed to read the secret
data after all. Edit the profile to permit it:

```
cat > /etc/apparmor.d/usr.local.bin.reader.sh << 'PROFILE'
abi <abi/3.0>,
include <tunables/global>

profile reader /usr/local/bin/reader.sh {
  include <abstractions/base>
  include <abstractions/bash>

  /usr/local/bin/reader.sh r,
  /usr/bin/bash ix,
  /usr/bin/cat ix,

  /opt/allowed-data/ r,
  /opt/allowed-data/** r,

  /opt/secret-data/ r,
  /opt/secret-data/** r,
}
PROFILE
```

Reload the profile:

```
apparmor_parser -r /etc/apparmor.d/usr.local.bin.reader.sh
```

Run the script again:

```
/usr/local/bin/reader.sh
```

**Expected output:**

```
--- Reading allowed data ---
this is public
--- Reading secret data ---
this is secret
--- Done ---
```

Both reads succeed now.

**What just happened:** You edited the profile file, reloaded it, and the
kernel immediately began enforcing the new, more permissive version. The
old denial is gone. Root edited the constraint, and the constraint changed.

This is the fundamental problem: AppArmor enforces the loaded profile
faithfully, but root controls what gets loaded. A program running as root
can rewrite its own profile to allow anything, reload it, and proceed
without restriction. AppArmor will never complain -- it enforces whatever
it is told to enforce.

### Exercise 7: Clean up

Exit the VM:

```
exit
```

Back on your host, you can stop the VM to free resources (you will create
different VMs in later modules):

```
lxc stop apparmor-lab
```

## Checkpoint

From inside the VM (run `lxc exec apparmor-lab -- bash` if you exited),
verify that your profile is loaded:

```
aa-status | grep reader
```

Expected output: a line containing `reader`.

Verify the profile file exists:

```
cat /etc/apparmor.d/usr.local.bin.reader.sh | head -3
```

Expected output:

```
abi <abi/3.0>,
include <tunables/global>
```

If both commands produce the expected output, you have completed this
module.

## Key Takeaways

- **Discretionary Access Control (DAC)** -- the chmod/chown system -- is
  powerless against root. Root bypasses file permissions.
- **Mandatory Access Control (MAC)** lets the kernel enforce restrictions
  that even root cannot bypass at runtime.
- **AppArmor profiles** are whitelists: they name every file, path, and
  operation a program is allowed to perform. Anything not listed is denied.
- AppArmor globs have a sharp edge: `python3*` does not match `python3.14`.
  Use `python3{,.*}` to cross the dot.
- Root can edit and reload AppArmor profiles. The constraint is only as
  strong as the file on disk, and root controls that file.

## How this connects to the project

The agent's AppArmor profile is the constraint that defines what the agent is
allowed to do. It lives at `/etc/apparmor.d/harden` inside the workload VM.
The profile permits the agent to read its config, run SSH, and access the
fleet -- and critically, it permits the agent to write to its own profile
file.

That is the loaded gun. The agent can edit its own constraint. AppArmor will
faithfully enforce whatever new profile is loaded. But the kernel's Integrity
Measurement Architecture (IMA, Module 10) is watching: when `apparmor_parser`
reads the profile to load it, IMA hashes the file and extends that hash into
the TPM (Module 09). The original profile's hash is on the signed allowlist.
The new profile's hash is not.

AppArmor is the rule. IMA is the witness. The TPM is the record that cannot
be erased.

## Next

[Module 09: TPM -- Trusted Hardware](../09-tpm-trusted-hardware/README.md)
