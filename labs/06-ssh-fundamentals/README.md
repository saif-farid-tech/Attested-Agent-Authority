# Module 06: SSH Fundamentals

You will learn how SSH lets you run commands on a remote machine securely, and
how key-based authentication replaces passwords with cryptographic proof. This
matters because the agent connects to every fleet server over SSH -- and
understanding how SSH keys work is essential before you can understand the
certificate system that controls whether the agent gets in.

## Prerequisites

Complete these modules first:

- [Module 00: The Terminal](../00-the-terminal/README.md)
- [Module 01: Files, Users, Permissions](../01-files-users-permissions/README.md)
- [Module 04: Virtual Machines with LXD](../04-virtual-machines-lxd/README.md)
- [Module 05: Cryptographic Hashing](../05-cryptographic-hashing/README.md)

## What you will need

- A computer running Ubuntu 22.04 or 24.04.
- LXD installed and initialized (from Module 04).
- No additional packages -- `ssh`, `ssh-keygen`, and `sshd` are included with
  Ubuntu.

## Concepts

### What is SSH?

**SSH** (Secure Shell) is a program that lets you run commands on another
computer over a network, securely. "Securely" means two things: the
connection is encrypted (nobody watching the network can read what you type or
see what comes back), and the connection is authenticated (you can prove who
you are to the remote machine, and it can prove who it is to you).

When you type:

```
ssh user@10.0.0.5
```

you are saying: "Connect to the machine at address 10.0.0.5, log in as
`user`, and give me a terminal there." Everything you type after that runs on
the remote machine, not on yours.

You can also run a single command without opening a full terminal session:

```
ssh user@10.0.0.5 ls /etc
```

This connects, runs `ls /etc` on the remote machine, prints the output on
your screen, and disconnects. The project uses this pattern constantly -- the
agent runs commands like `ssh root@web-01 cat /etc/ssh/sshd_config` to inspect
and fix fleet servers.

### Password authentication (and why it is weak)

The simplest way to log in with SSH is with a password. The remote machine
asks for one, you type it, and if it matches, you are in. This works, but it
has problems:

- Passwords can be guessed. Automated tools try thousands of passwords per
  minute against SSH servers exposed to the internet.
- Passwords are typed. They can be watched (over your shoulder, on a keystroke
  logger, or through a compromised connection).
- Passwords are shared secrets. Both you and the server know the password,
  which means the server stores something that could be stolen.

For these reasons, serious SSH setups disable password authentication entirely
and use keys instead.

### Key-based authentication

Key-based authentication replaces passwords with a pair of mathematically
related files:

- The **private key** is your secret. It stays on your machine, and you never
  share it with anyone. Think of it as the actual key to a lock.
- The **public key** is the lock. You give it to every server you want to
  access. It can be shared freely -- knowing the lock does not help you open it.

The math works like this: the private key can produce a signature that only the
matching public key can verify. When you connect with SSH, the server sends a
challenge, your SSH client signs it with your private key, and the server
checks the signature against the public key it has on file. If the signature
is valid, you are in -- without ever transmitting a password.

The public key is typically stored in a file called `authorized_keys` on the
server. This file lives at `~/.ssh/authorized_keys` in the home directory of
the user you are logging in as. Each line in the file is one public key that
is allowed to log in as that user.

### Key pair files

When you generate an SSH key pair, you get two files:

- `~/.ssh/id_ed25519` -- the private key. Its permissions must be `600` (only
  the owner can read it), or SSH refuses to use it.
- `~/.ssh/id_ed25519.pub` -- the public key. This is the one you copy to
  servers.

The `ed25519` part is the algorithm used. Ed25519 is modern, fast, and
produces short keys. You may also see `rsa` keys, which are older and longer.
Either works; Ed25519 is preferred for new keys.

### The `authorized_keys` mechanism

Here is the full chain of how key-based authentication works:

1. You generate a key pair on your machine (the client).
2. You copy the public key to the server and append it to
   `~/.ssh/authorized_keys`.
3. When you connect, your SSH client proves it holds the private key by signing
   a challenge.
4. The server checks the signature against every public key in
   `authorized_keys`.
5. If any key matches, you are in.

This is simple and effective, but it has a limitation that Module 07 will
address: once a public key is in `authorized_keys`, it works forever. If your
private key is stolen, the thief has permanent access until someone manually
removes the public key from every server. There is no expiry date.

## Exercises

### Exercise 1: Create an LXD VM for SSH practice

You need a separate machine to SSH into. Create one with LXD:

```
lxc launch ubuntu:24.04 sshlab --vm
```

Wait about fifteen seconds for it to boot, then confirm it is running and note
its IP address:

```
lxc list
```

Look for the `sshlab` row and find its IPv4 address (something like
`10.x.x.x`). You will need this address for the SSH commands below. If no IP
appears yet, wait ten seconds and run `lxc list` again.

Install the SSH server inside the VM (it may already be installed, but this
ensures it):

```
lxc exec sshlab -- apt-get update -qq
lxc exec sshlab -- apt-get install -y -qq openssh-server
```

**What just happened:** You created a VM that will act as a remote server for
the rest of this module. You installed the SSH server (`sshd`) inside it so it
will accept SSH connections.

### Exercise 2: Generate an SSH key pair

On your host (not inside the VM), generate a key pair:

```
ssh-keygen -t ed25519 -f ~/.ssh/lab_key -N "" -C "lab-module-06"
```

The flags mean:

- `-t ed25519` -- use the Ed25519 algorithm.
- `-f ~/.ssh/lab_key` -- save the key to this file (instead of the default
  name, so it does not interfere with any existing keys).
- `-N ""` -- set an empty passphrase (fine for a lab exercise; in production
  you would use a passphrase to protect the key file).
- `-C "lab-module-06"` -- a comment embedded in the key to help you identify
  it later.

You should see output like:

```
Generating public/private ed25519 key pair.
Your identification has been saved in /home/youruser/.ssh/lab_key
Your public key has been saved in /home/youruser/.ssh/lab_key.pub
The key fingerprint is:
SHA256:... lab-module-06
```

Now look at both files:

```
cat ~/.ssh/lab_key.pub
```

You should see a single line starting with `ssh-ed25519`, followed by a long
string of characters, followed by `lab-module-06`. This is the public key --
the lock.

```
cat ~/.ssh/lab_key
```

You should see multiple lines starting with `-----BEGIN OPENSSH PRIVATE KEY-----`
and ending with `-----END OPENSSH PRIVATE KEY-----`. This is the private key
-- the actual key. Never share this file.

Check the permissions:

```
ls -la ~/.ssh/lab_key
```

The permissions should be `-rw-------` (readable and writable by the owner
only). SSH enforces this: if the private key is readable by other users, SSH
refuses to use it.

**What just happened:** You created a mathematically linked pair of files. The
public key can verify signatures made by the private key, but cannot produce
them. This asymmetry is the foundation of SSH key authentication.

### Exercise 3: Install your public key on the VM

First, create a `.ssh` directory inside the VM for the root user and set its
permissions:

```
lxc exec sshlab -- mkdir -p /root/.ssh
lxc exec sshlab -- chmod 700 /root/.ssh
```

Push your public key into the VM's `authorized_keys` file:

```
lxc file push ~/.ssh/lab_key.pub sshlab/root/.ssh/authorized_keys
```

Set the correct permissions on the `authorized_keys` file:

```
lxc exec sshlab -- chmod 600 /root/.ssh/authorized_keys
```

Verify it is in place:

```
lxc exec sshlab -- cat /root/.ssh/authorized_keys
```

You should see your public key -- the same line that `cat ~/.ssh/lab_key.pub`
shows.

Ensure the SSH server inside the VM allows root login with keys. Check the
current setting:

```
lxc exec sshlab -- grep "^PermitRootLogin" /etc/ssh/sshd_config
```

If it says `prohibit-password` or `yes`, you are fine (both allow key-based
login). If it says `no`, or if there is no output, enable it:

```
lxc exec sshlab -- bash -c "echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config"
lxc exec sshlab -- systemctl restart ssh
```

**What just happened:** You installed your public key on the server. You told
the SSH server: "Anyone who can prove they hold the private key matching this
public key is allowed to log in as root." The permissions matter -- SSH ignores
the `authorized_keys` file if it or its parent directory is readable by other
users.

### Exercise 4: Connect with your key

Find the VM's IP address:

```
lxc list sshlab --format csv -c 4 | cut -d' ' -f1
```

This prints just the IPv4 address. Note it -- you will use it in the commands
below. In the following examples, replace `VM_IP` with this actual address.

Connect via SSH using your key:

```
ssh -i ~/.ssh/lab_key -o StrictHostKeyChecking=no root@VM_IP
```

The flags:

- `-i ~/.ssh/lab_key` -- use this specific private key.
- `-o StrictHostKeyChecking=no` -- do not ask about the server's host key the
  first time (fine for a lab; in production, you would verify it).

You should get a shell prompt on the VM -- something like `root@sshlab:~#`.
You are now on the remote machine. Run:

```
hostname
whoami
```

You should see `sshlab` and `root`. You are logged into the VM via SSH,
authenticated by your key -- no password was asked for.

Type `exit` to disconnect and return to your host.

**What just happened:** Your SSH client signed a challenge with your private
key. The server checked the signature against the public key in
`authorized_keys`. The signature matched, so you were granted access. No
password was transmitted, no password was stored, and nobody watching the
network could intercept a reusable credential.

### Exercise 5: Run a remote command without logging in

You do not need an interactive session to use SSH. Run a single command
remotely:

```
ssh -i ~/.ssh/lab_key -o StrictHostKeyChecking=no root@VM_IP cat /etc/hostname
```

You should see:

```
sshlab
```

The command ran on the VM, printed its output to your terminal, and the
connection closed. You never saw a remote prompt.

Try another:

```
ssh -i ~/.ssh/lab_key -o StrictHostKeyChecking=no root@VM_IP uptime
```

You should see the VM's uptime -- how long it has been running since its last
boot.

**What just happened:** You used SSH the same way the agent does -- to execute
a command on a remote machine and get the result back. The agent runs commands
like `ssh root@web-01 cat /etc/ssh/sshd_config` to audit and fix fleet
servers. Every connection is authenticated, encrypted, and closed automatically.

### Exercise 6: Understand the permanence problem

Your key is now permanently authorized. To see why this is a problem, imagine
the key is stolen. Simulate this by copying the private key to a different
location (pretending a different person has it):

```
cp ~/.ssh/lab_key /tmp/stolen_key
chmod 600 /tmp/stolen_key
```

The "thief" can connect with the stolen key:

```
ssh -i /tmp/stolen_key -o StrictHostKeyChecking=no root@VM_IP hostname
```

This works. The server does not know or care that the key was copied. It only
checks: "Does this key match one in `authorized_keys`?" It does, so access is
granted.

The only way to revoke access is to manually remove the public key from the
server:

```
lxc exec sshlab -- bash -c "> /root/.ssh/authorized_keys"
```

Now try the stolen key again:

```
ssh -i /tmp/stolen_key -o StrictHostKeyChecking=no root@VM_IP hostname
```

This time you should see a `Permission denied` error. The key has been
revoked -- but only because you manually cleared the server's
`authorized_keys`. In a real deployment with hundreds of servers, you would
have to do this on every single one.

Clean up the simulated theft:

```
rm /tmp/stolen_key
```

**What just happened:** You experienced the fundamental weakness of raw SSH
keys: they are permanent. Once authorized, they work forever from any machine
that holds a copy of the private key. Revoking them requires touching every
server individually. Module 07 introduces certificates, which solve this by
adding an expiry time that the server enforces automatically.

## Checkpoint

Run these commands to verify you completed the module:

```
ssh-keygen -t ed25519 -f ~/.ssh/checkpoint_key -N "" -C "checkpoint-06" -q
cat ~/.ssh/checkpoint_key.pub
```

You should see a line starting with `ssh-ed25519`. If so, you can generate key
pairs and are ready for Module 07.

Clean up the exercise VM and checkpoint key:

```
lxc stop sshlab
lxc delete sshlab
rm -f ~/.ssh/checkpoint_key ~/.ssh/checkpoint_key.pub
rm -f ~/.ssh/lab_key ~/.ssh/lab_key.pub
```

## Key Takeaways

- **SSH** provides encrypted, authenticated remote command execution.
- **Key-based authentication** replaces passwords with a private key (your
  secret) and a public key (installed on the server).
- The server's `authorized_keys` file lists every public key allowed to log in.
- `ssh user@host command` runs a single command remotely -- the pattern the
  agent uses to manage fleet servers.
- Raw SSH keys have a critical weakness: they are **permanent**. A stolen key
  works forever unless manually revoked on every server.

## How this connects to the project

The agent connects to fleet servers (web-01, db-01, gw-01) over SSH. It runs
commands remotely -- auditing configurations, applying fixes -- using exactly
the `ssh user@host command` pattern you practiced. But the agent does not use
raw keys with `authorized_keys`. If it did, a compromised agent would have
permanent access to the entire fleet.

The problem is clear: you need SSH for remote access, but you need the access
to expire. You need authority that drains away unless someone keeps renewing it.
That is what Module 07 introduces.

## Next

[Module 07: SSH Certificates](../07-ssh-certificates/README.md)
