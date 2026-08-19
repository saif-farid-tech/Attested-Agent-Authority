# Module 09: TPM -- Trusted Hardware

You will learn what a Trusted Platform Module (TPM) is and how it creates
evidence that software cannot forge. This matters because the Attested Agent
Authority project uses TPM quotes as the proof that the agent's measured
state has not been tampered with -- and the verifier will not sign a
certificate without that proof.

## Prerequisites

- Module 04: Virtual Machines (you will use LXD VMs with a virtual TPM)
- Module 05: Cryptographic Hashing (you need to understand hash functions)
- Module 06: SSH Fundamentals (you need to understand key pairs and
  signatures)

## What you will need

- Your Ubuntu host with LXD installed and working.
- About 20-25 minutes.

## Concepts

### What is a TPM?

A TPM is a small chip -- either a physical chip soldered to your motherboard,
or a firmware module running in a protected area of your CPU. It does three
things:

1. **Holds secrets** -- cryptographic keys that never leave the chip.
2. **Signs statements** -- it can sign a message with a key that nobody else
   has, proving the statement came from this specific TPM.
3. **Records measurements** -- it has special registers that accumulate
   hashes in a way that cannot be undone.

A TPM is not fast. It is not general-purpose. It does a few things, and it
does them in a way that software running on the main CPU cannot fake.

### Virtual TPM (vTPM)

For this lab, you will use a **virtual TPM** (vTPM). This is a software
implementation of a TPM that LXD provides to virtual machines. It behaves
identically to a real TPM from the guest's perspective: the same commands,
the same data structures, the same operations.

Here is the honest caveat: **a vTPM can be forged by the host.** The host
controls the software that emulates the TPM, so the host can make it say
anything. A real TPM cannot be forged this way because it is a separate
physical chip with its own tamper-resistant storage. For learning, the
mechanism is identical -- every command you run, every concept you learn,
works the same way with a discrete TPM. The difference is the foundation,
not the logic built on top of it.

### Platform Configuration Registers (PCRs)

The most important concept in TPM attestation is the **PCR** -- Platform
Configuration Register. A TPM has a set of PCRs, numbered 0 through 23.
Each PCR is a small register that holds a single hash value (32 bytes for
SHA-256).

PCRs have one crucial property: they can be **extended** but never
**written**. Here is how extending works:

```
new_value = hash(old_value + new_data)
```

When you extend a PCR with some data, the TPM hashes the current PCR value
concatenated with the new data, and stores the result as the new PCR value.
You cannot set a PCR to an arbitrary value. You cannot reset it to zero
(except by rebooting). You can only extend it forward.

This means the PCR value is a cumulative record of everything that has been
extended into it, in order. If someone extends `A`, then `B`, then `C` into
a PCR, the final value is:

```
hash(hash(hash(initial + A) + B) + C)
```

Change any one of those inputs, or change their order, and the final value
is completely different. And there is no way to "un-extend" -- you cannot
compute a value to extend that would take the PCR back to a previous state
(that would require reversing a hash function, which is computationally
infeasible -- you proved this to yourself in Module 05).

### Which PCR is which?

Different PCRs are used for different purposes by convention:

| PCR | Purpose |
|-----|---------|
| 0-7 | Firmware and boot measurements (BIOS, bootloader, kernel) |
| 8-9 | OS boot measurements |
| **10** | **IMA -- Integrity Measurement Architecture** |
| 11-15 | Available for other uses |
| 16-23 | Debug and testing |

**PCR 10** is the one that matters for this project. Every time the kernel's
IMA subsystem measures a file (which you will learn about in Module 10), it
extends that measurement into PCR 10. The value of PCR 10 is therefore a
cumulative fingerprint of every file the kernel has measured since boot.

### TPM keys

A TPM uses several keys:

- **Endorsement Key (EK)** -- the TPM's identity. It is unique to this TPM
  and is used to prove "I am this specific TPM." In a real TPM, the EK is
  burned in at the factory. In a vTPM, it is generated when the vTPM is
  first created.

- **Attestation Key (AK)** -- a key created under the EK, used specifically
  for signing attestation quotes. The AK is what the verifier trusts: it
  knows the AK came from the TPM (because it was created under the EK), and
  any quote signed by the AK is therefore a truthful statement from the TPM.

### Quotes

A **quote** is a signed statement from the TPM that says: "At the time of
this request, with this nonce, the values of the requested PCRs were [these
values]." The quote is signed with the AK, so the verifier can confirm:

1. The quote was produced by the TPM that owns this AK.
2. The PCR values in the quote are the actual PCR values at the time of
   signing.
3. The nonce in the quote matches the nonce the verifier sent (preventing
   replay of old quotes).

The verifier sends a fresh random nonce with every quote request. The TPM
includes that nonce in the signed quote. This means you cannot save an old
"good" quote and replay it later -- the nonce will not match.

### tpm2-tools

The `tpm2-tools` package provides command-line tools for interacting with a
TPM. The ones you will use:

- **`tpm2_createek`** -- create an Endorsement Key.
- **`tpm2_createak`** -- create an Attestation Key under the EK.
- **`tpm2_pcrread`** -- read the current value of one or more PCRs.
- **`tpm2_pcrextend`** -- extend a PCR with new data.
- **`tpm2_quote`** -- ask the TPM to produce a signed quote of PCR values.
- **`tpm2_checkquote`** -- verify a quote's signature and nonce.
- **`tpm2_evictcontrol`** -- make a key persistent (survives reboots).
- **`tpm2_readpublic`** -- export a key's public half.

## Exercises

### Exercise 1: Create a VM with a virtual TPM

Create a VM with secure boot and a vTPM device:

```
lxc launch ubuntu:24.04 tpmlab --vm -c security.secureboot=true -d vtpm:tpm
```

Wait about 30-40 seconds for the VM to boot, then open a shell:

```
lxc exec tpmlab -- bash
```

Install the TPM tools:

```
apt-get update -q && apt-get install -qy tpm2-tools
```

Verify the TPM device exists:

```
ls -l /dev/tpm*
```

**Expected output:** You should see `/dev/tpm0` and `/dev/tpmrm0`. The
first is the raw device; the second is the "resource manager" device that
handles session management for you.

**What just happened:** LXD created a virtual machine with a vTPM attached.
From inside the VM, the vTPM looks exactly like a hardware TPM at
`/dev/tpm0`. The kernel's TPM driver loaded automatically.

### Exercise 2: Create the Endorsement Key and Attestation Key

Create the Endorsement Key:

```
mkdir -p /tmp/tpmlab
cd /tmp/tpmlab
tpm2_createek -c ek.ctx -G ecc -u ek.pub
```

**Expected output:** No error output. Two files appear: `ek.ctx` (the key
context, which is a handle for using the key) and `ek.pub` (the public
portion).

Now create an Attestation Key under the EK:

```
tpm2_createak -C ek.ctx -c ak.ctx -G ecc -g sha256 -s ecdsa -u ak.pub -n ak.name
```

**Expected output:** Several lines of output describing the key properties,
and new files `ak.ctx`, `ak.pub`, `ak.name`.

Make the AK persistent so it survives reboots:

```
tpm2_evictcontrol -C o -c ak.ctx 0x81010002
```

**Expected output:** A line confirming the key was made persistent at handle
`0x81010002`.

Export the AK's public key in PEM format (this is what a verifier would
use):

```
tpm2_readpublic -c 0x81010002 -f pem -o ak.pem
```

**Expected output:** Output describing the key, and an `ak.pem` file.

Verify it is a proper PEM key:

```
cat ak.pem
```

**Expected output:** A block starting with `-----BEGIN PUBLIC KEY-----` and
ending with `-----END PUBLIC KEY-----`.

**What just happened:** You created the TPM's key hierarchy. The EK is the
TPM's identity. The AK, created under the EK, is the key used for
attestation. Making it persistent at handle `0x81010002` means you can
refer to it by that handle even after rebooting the VM. The PEM export is
what you would give to a remote verifier so it can check quote signatures.

### Exercise 3: Read PCR values

Read all the SHA-256 PCR values:

```
tpm2_pcrread sha256
```

**Expected output:** A list of PCR indices 0-23 with their current hash
values. Many will be all zeros (meaning nothing has been extended into them).
Some, like PCR 0-7, will have values from the boot process. Look at PCR 10
in particular -- it may have a value if IMA is active, or it may be all
zeros.

Read just PCR 10:

```
tpm2_pcrread sha256:10
```

**Expected output:** One line showing the SHA-256 value of PCR 10. Note this
value -- you will change it in the next exercise and prove you cannot change
it back.

**What just happened:** `tpm2_pcrread` asked the TPM for the current values
of its PCRs. These are not files on disk -- they are values stored inside
the TPM chip (or vTPM process). You read them, but you did not and cannot
write them directly.

### Exercise 4: Extend a PCR (and prove you cannot go back)

PCR 16 is reserved for testing. Extend it with some data:

First, read the current value:

```
tpm2_pcrread sha256:16
```

**Expected output:** A line showing PCR 16's value. On a fresh boot with
nothing extended, it will be all zeros:

```
  sha256:
    16: 0x0000000000000000000000000000000000000000000000000000000000000000
```

Now extend it:

```
tpm2_pcrextend 16:sha256=b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c
```

Read it again:

```
tpm2_pcrread sha256:16
```

**Expected output:** A completely different value. PCR 16 is no longer all
zeros -- it now contains `hash(old_value + the_data_you_extended)`.

Extend it a second time with different data:

```
tpm2_pcrextend 16:sha256=7d865e959b2466918c9863afca942d0fb89d7c9ac0c99bafc3749504ded97730
```

Read it one more time:

```
tpm2_pcrread sha256:16
```

**Expected output:** Another completely different value. Each extension
produces a new value that depends on everything that came before.

Now try to set PCR 16 back to its original all-zeros value. You cannot.
There is no command that resets a PCR. The only way to get it back to zeros
is to reboot the VM.

**What just happened:** You demonstrated the fundamental property of PCRs.
They are extend-only. Each extension irreversibly incorporates new data into
the register. There is no "undo" operation. This is what makes PCRs useful
for attestation: if someone modifies a file that gets measured into a PCR,
the PCR value changes, and there is no way to change it back without
rebooting (which would start the measurement log from scratch and be
visible to the verifier).

### Exercise 5: Generate and verify a quote

Now you will produce a signed quote of PCR 16's current value and verify it.

Generate a random nonce (this is what a verifier would send):

```
NONCE=$(od -An -tx1 -N20 /dev/urandom | tr -d ' \n')
echo "Nonce: $NONCE"
```

**Expected output:** A string of 40 hex characters. This is your nonce.

Request a quote from the TPM:

```
tpm2_quote -c 0x81010002 -l sha256:16 -q $NONCE -m quote.msg -s quote.sig -o quote.pcrs -g sha256
```

**Expected output:** Output showing the quote was produced, including the
quoted PCR value and the signature. Three files are created: `quote.msg`
(the signed message), `quote.sig` (the signature), and `quote.pcrs` (the
PCR values that were quoted).

Now verify the quote:

```
tpm2_checkquote -u ak.pem -m quote.msg -s quote.sig -f quote.pcrs -g sha256 -q $NONCE
```

**Expected output:** Output confirming the quote is valid. The command exits
with code 0 (success).

**What just happened:** You asked the TPM to produce a signed attestation of
PCR 16's current value. The TPM signed the PCR value and the nonce with the
AK. Then `tpm2_checkquote` verified that:
1. The signature is valid (it was produced by the TPM that owns this AK).
2. The nonce matches (this is a fresh quote, not a replay).
3. The PCR values in the quote match the PCR values in the attached data.

### Exercise 6: Prove the old quote fails after extending

Now extend PCR 16 one more time:

```
tpm2_pcrextend 16:sha256=a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e
```

The PCR value has changed. Try to verify the old quote with the old nonce:

```
tpm2_checkquote -u ak.pem -m quote.msg -s quote.sig -f quote.pcrs -g sha256 -q $NONCE
```

**Expected output:** This still succeeds -- the signature itself is still
valid because you have not changed the quote data. The quote accurately
records what the PCR was at the time it was signed. But if a verifier were
to compare the quoted PCR value against the TPM's current PCR value, they
would see a mismatch.

Read the current PCR value:

```
tpm2_pcrread sha256:16
```

Compare this visually with the value shown in the quote output from Exercise
5. They are different. The quote is a truthful record of the past, but the
present has moved on. A verifier that demands a fresh quote (with a new
nonce) would get one reflecting the extended state -- and if that state does
not match what it expects, it would reject the attestation.

Generate a new quote with a new nonce:

```
NEW_NONCE=$(od -An -tx1 -N20 /dev/urandom | tr -d ' \n')
tpm2_quote -c 0x81010002 -l sha256:16 -q $NEW_NONCE -m quote2.msg -s quote2.sig -o quote2.pcrs -g sha256
```

**Expected output:** A quote with a different PCR value than the first one.

**What just happened:** You proved that extending a PCR makes it impossible
to produce a quote matching the old state. The verifier in the Attested
Agent Authority project works exactly this way: every 30 seconds it sends a
fresh nonce, gets a fresh quote, and checks whether PCR 10 reflects the
expected measurement history. One unexpected extension and the quote no
longer matches.

### Exercise 7: Clean up

Exit the VM:

```
exit
```

Stop the VM:

```
lxc stop tpmlab
```

## Checkpoint

From inside the VM (run `lxc exec tpmlab -- bash` if you exited), verify
that the AK is persistent:

```
tpm2_readpublic -c 0x81010002 -f pem 2>/dev/null | head -1
```

Expected output:

```
-----BEGIN PUBLIC KEY-----
```

Verify that PCR 16 is not all zeros (you extended it):

```
tpm2_pcrread sha256:16 | grep -v "0x00000000000000000000"
```

Expected output: a line showing PCR 16 with a non-zero value.

If both commands produce the expected output, you have completed this
module.

## Key Takeaways

- A **TPM** is a chip (or virtual chip) that holds keys and signs statements
  that software cannot forge.
- **PCRs** can be extended but never written directly. Each extension
  irreversibly mixes new data into the register. The only reset is a reboot.
- The **Endorsement Key (EK)** is the TPM's identity. The **Attestation Key
  (AK)** is used to sign quotes.
- A **quote** is a signed statement of PCR values with a nonce. A fresh
  nonce prevents replaying old quotes.
- A **vTPM** behaves identically to a real TPM for learning, but the host
  can forge it. A real TPM cannot be forged.

## How this connects to the project

The workload VM has a vTPM with an AK persisted at handle `0x81010002`.
The verifier holds the AK's public key, exported once during setup. Every
30 seconds, the verifier sends a fresh nonce, the TPM produces a signed
quote over PCR 10, and `tpm2_checkquote` verifies the signature. The
verifier then replays the IMA measurement log (Module 10) against the
quoted PCR value to confirm the entire history is accounted for.

The agent cannot forge a quote. It cannot un-extend PCR 10. It cannot
produce a quote that shows a state that did not happen. The TPM reports the
truth, and the agent has no say in the matter.

## Next

[Module 10: IMA -- Integrity Measurement Architecture](../10-ima-integrity-measurement/README.md)
