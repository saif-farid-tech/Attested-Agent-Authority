# Module 07: SSH Certificates

You will learn how SSH certificates replace permanent keys with authority that
expires. You will create a certificate authority, sign a key into a short-lived
certificate, use it to connect, and then watch it die. This is the core
mechanism of the entire project: the agent's power is not taken away -- it
drains away, and the only way to refill it is to pass attestation.

## Prerequisites

Complete these modules first:

- [Module 04: Virtual Machines with LXD](../04-virtual-machines-lxd/README.md)
- [Module 05: Cryptographic Hashing](../05-cryptographic-hashing/README.md)
- [Module 06: SSH Fundamentals](../06-ssh-fundamentals/README.md)

## What you will need

- A computer running Ubuntu 22.04 or 24.04.
- LXD installed and initialized (from Module 04).
- About 30-40 minutes.

## Concepts

### The problem with permanent keys

In Module 06, you saw the weakness of raw SSH keys: once a public key is in
`authorized_keys`, the matching private key grants access forever. Revoking it
means manually editing files on every server. In a fleet of hundreds of
machines, this is slow, error-prone, and usually does not happen fast enough.

For an AI agent with root access, this is worse. If the agent is compromised
-- or compromises itself by removing its own constraints -- its SSH keys keep
working. Nothing about the key itself records whether the agent is still
trustworthy.

What you want is authority that expires. Not a key that works forever, but a
signed permission slip that is valid for five minutes, or one minute, or
thirty seconds. When it expires, the agent must come back and prove it still
deserves access before it gets a new one. If it cannot prove that, it gets
nothing, and every server refuses it automatically.

### What is a certificate authority?

A **certificate authority** (CA) is an entity that vouches for others by signing
their credentials. The concept is the same as in everyday life: a notary stamps
a document to say "I verified this person's identity." The stamp (the
signature) carries authority because people trust the notary, not because they
trust the person.

In SSH, the CA is simply a key pair:

- The **CA private key** is used to sign other people's public keys. It is the
  notary's stamp.
- The **CA public key** is given to servers. It says: "Trust anyone whose key
  was signed by this CA."

The CA does not need to be a special service or a separate machine. It is just
a key pair used for a specific purpose: signing other keys.

### How SSH certificates work

Here is the full flow:

1. **The CA generates a key pair.** This happens once. The CA private key must
   be protected -- anyone who has it can grant access to every server that
   trusts this CA.

2. **A user generates their own key pair.** This is the same `ssh-keygen` you
   already know.

3. **The CA signs the user's public key.** This produces a third file: a
   **certificate**. The certificate is the user's public key plus metadata
   (who the key belongs to, when it expires, what it can do) plus the CA's
   signature over all of it.

4. **Servers are configured to trust the CA.** Instead of listing individual
   public keys in `authorized_keys`, the server has a single line in its SSH
   configuration: `TrustedUserCAKeys /path/to/ca_public_key`. This says:
   "Accept anyone who presents a valid certificate signed by this CA."

5. **The user connects with their key and certificate.** SSH automatically
   presents the certificate. The server checks: Is the certificate signed by
   my trusted CA? Is it still within its validity period? If both are true, the
   user is in.

### The expiry -- the whole point

When the CA signs a certificate, it can set a validity period. A certificate
valid for five minutes works for five minutes and then stops working. The
server enforces this -- it checks the current time against the certificate's
"valid before" timestamp and rejects expired certificates. No one has to
revoke anything. The authority simply dies on schedule.

This is the mechanism the project uses. The verifier holds the CA private key.
Every time attestation passes, the verifier signs a new certificate with a
short lifetime. As long as attestation keeps passing, the agent keeps getting
fresh certificates and its authority stays alive. The moment attestation fails,
the verifier stops signing, no new certificate is issued, and the agent's last
certificate ticks down to expiry. When it hits zero, every server in the fleet
refuses the agent. The authority was not revoked -- it was never renewed.

### TrustedUserCAKeys

This is the SSH server configuration directive that makes it all work. In the
server's `/etc/ssh/sshd_config` file, you add:

```
TrustedUserCAKeys /etc/ssh/ca_key.pub
```

This tells the SSH server: "Accept any certificate signed by the CA whose
public key is in this file." With this in place, the server does not need an
`authorized_keys` file at all. It does not need to know about individual users
or individual keys. It trusts the CA, and the CA decides who gets in and for
how long.

The fleet servers in the project are configured exactly this way. They know
nothing about attestation, TPMs, or measurement logs. They check one thing:
"Is this certificate signed by my CA and currently valid?" The entire
attestation apparatus is invisible to them.

## Exercises

### Exercise 1: Create a certificate authority

Generate the CA key pair. This is just a regular SSH key pair that you will use
for signing:

```
mkdir -p ~/.ssh/lab-ca
ssh-keygen -t ed25519 -f ~/.ssh/lab-ca/ca_key -N "" -C "lab-ca-module-07"
```

You now have two files:

```
ls -la ~/.ssh/lab-ca/
```

You should see:

```
ca_key        -- the CA private key (the stamp)
ca_key.pub    -- the CA public key (what servers will trust)
```

Look at the CA public key:

```
cat ~/.ssh/lab-ca/ca_key.pub
```

A single line starting with `ssh-ed25519`. This is what you will give to
servers.

**What just happened:** You created a certificate authority. It is not a
service, not a daemon, not a special piece of software -- it is a key pair.
Whoever holds the private key can sign certificates that every trusting server
will accept. Protecting this key is critical.

### Exercise 2: Create a user key pair

Generate a key pair for the "user" (the agent, in the project's terms):

```
ssh-keygen -t ed25519 -f ~/.ssh/lab-ca/agent_key -N "" -C "agent-module-07"
```

You now have the agent's private key and public key:

```
ls ~/.ssh/lab-ca/agent_key*
```

```
agent_key       -- the agent's private key
agent_key.pub   -- the agent's public key (to be signed by the CA)
```

**What just happened:** You created the key pair that the "agent" will use.
On its own, this key pair grants access to nothing. It needs to be signed by
the CA to become useful.

### Exercise 3: Sign a certificate with a 5-minute lifetime

This is where it gets interesting. Sign the agent's public key with the CA,
creating a certificate that expires in 5 minutes:

```
ssh-keygen -s ~/.ssh/lab-ca/ca_key \
  -I agent-cert \
  -n root \
  -V +5m \
  ~/.ssh/lab-ca/agent_key.pub
```

The flags:

- `-s ~/.ssh/lab-ca/ca_key` -- sign with this CA private key.
- `-I agent-cert` -- an identifier for the certificate (appears in logs).
- `-n root` -- the certificate is valid for logging in as the user `root`.
  This is called the **principal**.
- `-V +5m` -- valid from now until 5 minutes from now. This is the expiry.
- The last argument is the public key to sign.

You should see:

```
Signed user key ~/.ssh/lab-ca/agent_key-cert.pub: id "agent-cert" serial 0 for root valid from ...
```

A new file was created:

```
ls ~/.ssh/lab-ca/agent_key-cert.pub
```

This is the certificate -- the agent's public key plus the CA's signature plus
the metadata (principal, validity period).

**What just happened:** The CA signed the agent's public key into a certificate
with a 5-minute lifetime. This certificate is a statement from the CA: "The
holder of the matching private key is authorized to log in as root, but only
for the next five minutes." After that, the certificate is worthless.

### Exercise 4: Inspect the certificate

Look at what is inside the certificate:

```
ssh-keygen -Lf ~/.ssh/lab-ca/agent_key-cert.pub
```

You should see output including:

```
        Type: ssh-ed25519-cert-v01@openssh.com user certificate
        Public key: ED25519-CERT ...
        Signing CA: ED25519 SHA256:... (using ssh-ed25519)
        Key ID: "agent-cert"
        Serial: 0
        Valid: from YYYY-MM-DDTHH:MM:SS to YYYY-MM-DDTHH:MM:SS
        Principals:
                root
        ...
```

Pay attention to the `Valid` line. It shows the exact start and end times. This
certificate will stop working at the "to" time, and nothing can change that.
The server will check its own clock against this timestamp and reject the
certificate once it has passed.

Also note the `Principals` line: `root`. This certificate only works for
logging in as root. If you tried to use it to log in as any other user, it
would be rejected.

**What just happened:** You examined the certificate's metadata. The key fields
are the validity window and the principal. The server checks both: is the
certificate still within its validity window, and does the requested user match
one of the listed principals?

### Exercise 5: Set up a VM to trust the CA

Create a VM that will act as a fleet server:

```
lxc launch ubuntu:24.04 fleet-lab --vm
```

Wait about fifteen seconds for it to boot. Confirm it has an IP address:

```
lxc list fleet-lab --format csv -c 4 | cut -d' ' -f1
```

Note this IP address -- you will use it as `VM_IP` below.

Install the SSH server and push the CA public key into the VM:

```
lxc exec fleet-lab -- apt-get update -qq
lxc exec fleet-lab -- apt-get install -y -qq openssh-server
lxc file push ~/.ssh/lab-ca/ca_key.pub fleet-lab/etc/ssh/ca_key.pub
```

Now configure the SSH server to trust this CA. This is the critical step --
instead of listing individual keys in `authorized_keys`, you tell the server
to trust anyone with a valid certificate from your CA:

```
lxc exec fleet-lab -- bash -c "echo 'TrustedUserCAKeys /etc/ssh/ca_key.pub' >> /etc/ssh/sshd_config"
lxc exec fleet-lab -- bash -c "echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config"
lxc exec fleet-lab -- systemctl restart ssh
```

Verify the configuration took effect:

```
lxc exec fleet-lab -- grep TrustedUserCAKeys /etc/ssh/sshd_config
```

You should see:

```
TrustedUserCAKeys /etc/ssh/ca_key.pub
```

**What just happened:** You configured the server to trust your CA. The server
has no `authorized_keys` file, no list of individual users. It trusts one thing:
certificates signed by the CA whose public key is at `/etc/ssh/ca_key.pub`. Any
valid, unexpired certificate from that CA gets in. This is exactly how the
fleet servers in the project are configured -- they trust the verifier's CA and
nothing else.

### Exercise 6: Connect with your certificate

Your certificate is less than 5 minutes old (if more than 5 minutes have
passed since Exercise 3, re-run the signing command from Exercise 3 to get a
fresh one).

Connect to the VM using the certificate:

```
ssh -i ~/.ssh/lab-ca/agent_key \
  -o CertificateFile=~/.ssh/lab-ca/agent_key-cert.pub \
  -o StrictHostKeyChecking=no \
  root@VM_IP hostname
```

Replace `VM_IP` with the actual IP address from Exercise 5.

You should see:

```
fleet-lab
```

You connected. The server accepted your certificate because:

1. It is signed by the CA the server trusts.
2. The principal (`root`) matches the user you logged in as.
3. The certificate has not expired yet.

No password. No `authorized_keys`. Just a signed, time-limited certificate.

**What just happened:** You authenticated to a server using a certificate
instead of a raw key. The server did not know your public key in advance -- it
checked that your certificate was signed by its trusted CA and was still valid.
This is the exact authentication mechanism the agent uses to reach fleet
servers.

### Exercise 7: Watch the certificate expire

This is the exercise that matters most. You are going to watch your authority
die.

First, check how much time is left on your certificate:

```
ssh-keygen -Lf ~/.ssh/lab-ca/agent_key-cert.pub 2>&1 | grep Valid
```

Note the expiry time. If it has already expired, sign a fresh one with a
shorter lifetime so you do not have to wait long:

```
ssh-keygen -s ~/.ssh/lab-ca/ca_key \
  -I agent-cert \
  -n root \
  -V +2m \
  ~/.ssh/lab-ca/agent_key.pub
```

This certificate lives for only 2 minutes. Confirm the connection works right
now:

```
ssh -i ~/.ssh/lab-ca/agent_key \
  -o CertificateFile=~/.ssh/lab-ca/agent_key-cert.pub \
  -o StrictHostKeyChecking=no \
  root@VM_IP echo "ACCESS GRANTED at $(date)"
```

You should see the access-granted message with the current time.

Now wait. Check the clock. When the certificate's "Valid to" time passes, try
again:

```
ssh -i ~/.ssh/lab-ca/agent_key \
  -o CertificateFile=~/.ssh/lab-ca/agent_key-cert.pub \
  -o StrictHostKeyChecking=no \
  root@VM_IP echo "This should fail"
```

You should see:

```
root@VM_IP: Permission denied (publickey).
```

The same key. The same certificate file. The same server. But the time has
passed, and the certificate is dead.

Try once more, just to be certain:

```
ssh -i ~/.ssh/lab-ca/agent_key \
  -o CertificateFile=~/.ssh/lab-ca/agent_key-cert.pub \
  -o StrictHostKeyChecking=no \
  root@VM_IP echo "Still trying"
```

Same result: `Permission denied`. The authority is gone.

**What just happened:** You experienced the core mechanism of this entire
project. You had access. Now you do not. The key did not change. The server did
not change. Nobody revoked anything. The certificate simply expired, and the
server -- checking its clock against the certificate's timestamp -- refused the
connection. The ONLY way to get access back is a fresh signature from the CA.

Read that last sentence again. It is the entire design of Attested Agent
Authority in one line.

### Exercise 8: Prove that only the CA can restore access

Your certificate is expired. Your key is useless without a valid certificate.
The only way back in is a new signature from the CA.

Sign a new certificate:

```
ssh-keygen -s ~/.ssh/lab-ca/ca_key \
  -I agent-cert-renewed \
  -n root \
  -V +5m \
  ~/.ssh/lab-ca/agent_key.pub
```

Try connecting again:

```
ssh -i ~/.ssh/lab-ca/agent_key \
  -o CertificateFile=~/.ssh/lab-ca/agent_key-cert.pub \
  -o StrictHostKeyChecking=no \
  root@VM_IP echo "ACCESS RESTORED at $(date)"
```

You should see the access-restored message. You are back in -- because the CA
signed a new certificate.

Now think about what controls access. It is not the key (the key never
changed). It is not the server configuration (nothing was edited). It is
entirely the CA's willingness to sign. If the CA stops signing, the last
certificate expires and access dies permanently.

**What just happened:** You restored access by getting a fresh signature from
the CA. This is the attestation loop: the verifier (acting as the CA) signs a
new certificate every time attestation passes. If the agent tampers with its
constraints, attestation fails, the verifier stops signing, and the agent's
current certificate counts down to zero. Nobody revokes anything. The authority
simply is not renewed.

### Exercise 9: See what happens without the certificate

To drive the point home, try connecting with just the raw key, no certificate:

```
ssh -i ~/.ssh/lab-ca/agent_key \
  -o StrictHostKeyChecking=no \
  root@VM_IP echo "Raw key, no certificate"
```

The result: `Permission denied`. The server has no `authorized_keys` file -- it
ONLY trusts certificates. A raw key is meaningless to it.

**What just happened:** The server rejects raw keys entirely. It is configured
to trust certificates from the CA and nothing else. Even if someone steals the
agent's private key, the key alone is useless without a current, signed
certificate. And certificates can only come from the CA. And the CA only signs
when attestation passes.

## Cleanup

Remove the lab VM and key files:

```
lxc stop fleet-lab
lxc delete fleet-lab
rm -rf ~/.ssh/lab-ca
```

## Checkpoint

You can verify you understood this module by answering these questions (no
command to run -- this is a comprehension check):

1. What does the server check when a certificate is presented? (Answer: Is it
   signed by my trusted CA? Is it still within its validity period? Does the
   principal match?)
2. What happens when a certificate expires? (Answer: The server rejects it.
   No one has to revoke it.)
3. What is the ONLY way to restore access after a certificate expires? (Answer:
   Get a fresh signature from the CA.)

If you can answer all three without looking back, you understand the mechanism.

## Key Takeaways

- SSH **certificates** replace permanent keys with time-limited, signed
  authority. They expire automatically -- no manual revocation needed.
- A **certificate authority** is a key pair used to sign other keys. Servers
  trust the CA, not individual users.
- `TrustedUserCAKeys` tells an SSH server to accept any valid certificate
  from a specific CA.
- The **validity period** is set at signing time. Once it expires, the
  certificate is dead and the only path to access is a new signature from the
  CA.
- The CA's **willingness to sign** is the sole control over access. Whoever
  controls the CA controls who gets in and for how long.

## How this connects to the project

The verifier IS the certificate authority. It holds the CA private key and it
is the only entity that can sign certificates. Here is the full chain:

1. Every 30 seconds, the verifier demands a TPM quote from the agent's VM.
2. It checks the quote against the signed allowlist of expected measurements.
3. If the measurements match -- the agent's code, its AppArmor profile, and
   every program it ran are exactly what they should be -- the verifier signs a
   certificate valid for one minute.
4. The agent uses that certificate to SSH into fleet servers.
5. If the agent modifies its AppArmor profile, the next measurement check
   fails.
6. The verifier stops signing. It does not revoke anything, block anything, or
   send any alert. It simply does not sign.
7. The agent's last certificate ticks down. For up to a minute, the agent
   still has access on borrowed time. Then the certificate expires, and every
   server in the fleet refuses the agent simultaneously.

You experienced steps 3 through 7 in this module. You had a certificate, it
expired, access died, and only a fresh signature from the CA brought it back.
In the project, "the CA agrees to sign" means "attestation passed." That
conditional renewal is the entire enforcement mechanism.

The fleet servers know nothing about TPMs, measurement logs, or AppArmor. They
check one thing -- is this certificate signed by the CA and still valid? -- and
that simplicity is a feature. The complexity of attestation is confined to the
verifier. The fleet just enforces expiry, which is something SSH servers
already know how to do.

This module is the mechanism. Everything after this -- AppArmor, TPM, IMA, the
attestation pipeline -- is about controlling when the CA is willing to sign.

## Next

[Module 08: AppArmor](../08-apparmor/README.md)
