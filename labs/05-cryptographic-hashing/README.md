# Module 05: Cryptographic Hashing

You will learn what a cryptographic hash is, how to compute one, and why
changing even a single byte of input produces a completely different output.
This matters because the entire attestation system depends on hashing: the
kernel hashes every program and file the agent touches, and the TPM holds a
running hash-of-hashes that the agent cannot rewind.

## Prerequisites

Complete these modules first:

- [Module 00: The Terminal](../00-the-terminal/README.md)
- [Module 01: Files, Users, Permissions](../01-files-users-permissions/README.md)

## What you will need

- A computer running Ubuntu 22.04 or 24.04.
- No special hardware or packages -- `sha256sum` is included with Ubuntu.
- About 20-30 minutes.

## Concepts

### What is a hash?

A **hash** is a digital fingerprint of some data. You feed any amount of data
into a hash function, and it produces a fixed-length string of characters. This
string is called the **hash value**, **digest**, or simply "the hash."

Three properties make hashes useful:

1. **Deterministic.** The same input always produces the same hash. Hash the
   word "hello" today, hash it tomorrow, hash it on a different computer -- you
   get the same result every time.

2. **Avalanche effect.** Change even one byte of the input, and the hash
   changes completely. Not just a little -- the entire output looks different.
   "hello" and "hellp" produce hashes that have nothing visually in common.

3. **One-way.** Given a hash, you cannot work backwards to figure out the
   original input. You can go from data to fingerprint, but not from
   fingerprint to data. This is not a limitation -- it is the design.

The hash function this project uses is **SHA-256** (Secure Hash Algorithm,
256-bit). It always produces a 64-character hexadecimal string, no matter
whether the input is a single letter or a ten-gigabyte file.

### Why hashes matter for integrity

If you hash a file and record the hash, you can later hash the file again and
compare. If the hashes match, the file has not changed -- not even by one byte.
If the hashes differ, something changed. You may not know what changed, but you
know with certainty that it did.

This is exactly how the project detects tampering. The kernel hashes the
agent's AppArmor profile, its code, and every program it runs. Those hashes
are recorded. If the agent modifies any of these files, the hash changes, and
the system knows.

### Hash chains and PCR extension

A **hash chain** takes this idea further. Instead of storing individual hashes,
you combine them into a running total:

1. Start with a value of all zeros.
2. Take the first hash. Concatenate it with the current value. Hash the
   concatenation. That result becomes the new current value.
3. Take the second hash. Concatenate it with the current value. Hash the
   concatenation. That result becomes the new current value.
4. Repeat for every hash.

This operation is called **extension**, and the running total is stored in a
**PCR** (Platform Configuration Register) inside the TPM. The critical property
is that extension is one-way: you can add new measurements to the chain, but
you cannot remove old ones. There is no "un-extend." If the agent modifies a
file, the new hash gets extended into the PCR, and the PCR value diverges from
what the verifier expects. Even if the agent puts the original file back, the
PCR now contains the history of both the modification and the restoration --
and that history does not match the expected chain.

This is why, in the demonstration, reverting the tamper does not fix
attestation. The measurement log is append-only.

## Exercises

### Exercise 1: Hash a string

Compute the SHA-256 hash of the word "hello":

```
echo -n "hello" | sha256sum
```

The `-n` flag tells `echo` not to add a newline character at the end. Without
it, you would be hashing "hello\n" (hello followed by a newline), which is a
different input and produces a different hash.

You should see:

```
2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  -
```

The `  -` at the end means the input came from standard input (a pipe) rather
than a file. The 64-character string before it is the SHA-256 hash.

**What just happened:** You fed five bytes ("h", "e", "l", "l", "o") into the
SHA-256 function and got a 64-character fingerprint. This fingerprint uniquely
identifies that exact input.

### Exercise 2: Prove determinism

Run the exact same command again:

```
echo -n "hello" | sha256sum
```

You should see the same hash:

```
2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  -
```

Now compute the hash a different way -- write "hello" to a file and hash the
file:

```
echo -n "hello" > /tmp/hello.txt
sha256sum /tmp/hello.txt
```

You should see:

```
2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  /tmp/hello.txt
```

The hash is identical. The same content produces the same fingerprint regardless
of how you compute it.

**What just happened:** You verified that SHA-256 is deterministic. The hash
depends only on the content, not on the method of delivery. This is what makes
hash-based verification reliable -- the kernel and the verifier can
independently hash the same file and get the same result.

### Exercise 3: The avalanche effect

Now hash "hellp" -- one letter different:

```
echo -n "hellp" | sha256sum
```

You should see something like:

```
5f4e23018f498e71fcaf53e894a1aadb1a68f47de3e5c1e46c95c28e6593b48f  -
```

Compare the two hashes visually:

```
hello: 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
hellp: 5f4e23018f498e71fcaf53e894a1aadb1a68f47de3e5c1e46c95c28e6593b48f
```

They share no visible pattern. Changing one letter -- the final "o" to "p" --
produced a completely different hash. This is the avalanche effect.

**What just happened:** You demonstrated that even a tiny change in input
produces a wildly different hash. This is why hashing detects tampering so
effectively. The agent cannot make a "small" change to its AppArmor profile
and hope the hash stays similar -- any change at all produces a completely
different fingerprint.

### Exercise 4: Hash a file, modify it, detect the change

Create a file with some content:

```
echo "This file has not been modified." > /tmp/original.txt
```

Hash it and save the hash:

```
sha256sum /tmp/original.txt > /tmp/original.sha256
```

Look at the saved hash:

```
cat /tmp/original.sha256
```

You should see a line with the hash followed by the filename.

Now modify the file -- add a single word:

```
echo "This file has definitely been modified." > /tmp/original.txt
```

Verify the file against the saved hash:

```
sha256sum --check /tmp/original.sha256
```

You should see:

```
/tmp/original.txt: FAILED
sha256sum: WARNING: 1 computed checksum did NOT match
```

The check failed because the file's content changed, so its hash no longer
matches the recorded hash.

Now restore the original content exactly:

```
echo "This file has not been modified." > /tmp/original.txt
```

Check again:

```
sha256sum --check /tmp/original.sha256
```

You should see:

```
/tmp/original.txt: OK
```

**What just happened:** You experienced the core mechanism of integrity
checking. You recorded a file's hash, modified the file, and the check caught
the change. When you restored the exact original content, the check passed
again. This is what `sha256sum --check` does: it recomputes the hash and
compares it to the stored value. The project's allowlist works the same way --
it is a list of expected hashes, and attestation compares the actual hashes
against it.

### Exercise 5: Simulate a PCR extend operation

This exercise walks you through the hash chain that a TPM's PCR register
performs. You will do it manually with `sha256sum` to understand the mechanism.

Start with a PCR value of all zeros (32 zero bytes, represented as 64 hex
zeros):

```
PCR="0000000000000000000000000000000000000000000000000000000000000000"
echo "Starting PCR value: $PCR"
```

Now simulate extending the PCR with the hash of "program_A". First, hash
"program_A":

```
HASH_A=$(echo -n "program_A" | sha256sum | awk '{print $1}')
echo "Hash of program_A: $HASH_A"
```

Extend: concatenate the current PCR value with the new hash, and hash the
result. The PCR and the hash are both hex strings representing 32 bytes each,
so we concatenate them and hash the 64 raw bytes:

```
PCR=$(echo -n "${PCR}${HASH_A}" | xxd -r -p | sha256sum | awk '{print $1}')
echo "PCR after extending with program_A: $PCR"
```

The `xxd -r -p` converts the hex string into raw bytes before hashing -- this
is important because the TPM concatenates raw bytes, not text characters.

Now extend with a second measurement, "program_B":

```
HASH_B=$(echo -n "program_B" | sha256sum | awk '{print $1}')
echo "Hash of program_B: $HASH_B"

PCR=$(echo -n "${PCR}${HASH_B}" | xxd -r -p | sha256sum | awk '{print $1}')
echo "PCR after extending with program_B: $PCR"
```

Save this final PCR value -- this is the "expected" value:

```
EXPECTED=$PCR
echo "Expected final PCR: $EXPECTED"
```

Now replay from scratch to verify. Start over and extend in the same order:

```
PCR="0000000000000000000000000000000000000000000000000000000000000000"
PCR=$(echo -n "${PCR}${HASH_A}" | xxd -r -p | sha256sum | awk '{print $1}')
PCR=$(echo -n "${PCR}${HASH_B}" | xxd -r -p | sha256sum | awk '{print $1}')
echo "Replayed PCR:       $PCR"
echo "Expected PCR:       $EXPECTED"
```

They should match.

Now see what happens if the order changes -- extend with program_B first, then
program_A:

```
PCR="0000000000000000000000000000000000000000000000000000000000000000"
PCR=$(echo -n "${PCR}${HASH_B}" | xxd -r -p | sha256sum | awk '{print $1}')
PCR=$(echo -n "${PCR}${HASH_A}" | xxd -r -p | sha256sum | awk '{print $1}')
echo "Wrong-order PCR:    $PCR"
echo "Expected PCR:       $EXPECTED"
```

The values are different. Even with the same measurements, changing the order
produces a different final PCR.

**What just happened:** You manually performed the extend operation that the
TPM does in hardware. The key lessons are: (1) the final PCR value depends on
every measurement AND their order, (2) you can verify the chain by replaying
from zero, and (3) there is no way to "un-extend" -- you can only add to the
chain. This is exactly how the verifier checks the agent: it replays the
measurement log from the beginning and compares the result to what the TPM
reports.

### Exercise 6: Why you cannot undo an extend

Try to produce the expected PCR value without including program_A. You would
need to find some value X such that extending with X and then program_B gives
the expected result. Try it:

```
HASH_X=$(echo -n "some_other_program" | sha256sum | awk '{print $1}')
PCR="0000000000000000000000000000000000000000000000000000000000000000"
PCR=$(echo -n "${PCR}${HASH_X}" | xxd -r -p | sha256sum | awk '{print $1}')
PCR=$(echo -n "${PCR}${HASH_B}" | xxd -r -p | sha256sum | awk '{print $1}')
echo "Attempted forgery:  $PCR"
echo "Expected PCR:       $EXPECTED"
```

They do not match. And they never will, for any value of X other than the
original HASH_A. The hash function makes it computationally impossible to find
an input that produces a specific output. The agent cannot fake the history.

**What just happened:** You tried to forge a PCR value and failed. This is the
property that makes TPM-based attestation trustworthy: even a root-level agent
cannot construct a measurement history that matches the expected PCR value
unless the actual measurements are exactly right.

## Checkpoint

Run this sequence and confirm the output matches:

```
echo -n "Module 05 complete" | sha256sum
```

You should see:

```
ce498ef9a83c616d3e1a0036ad27202b0e3ea914cbfddafeb0e1de402dc5be24  -
```

If your output matches, you understand hashing and are ready to move on.

## Key Takeaways

- A **cryptographic hash** is a fixed-length fingerprint of data: same input
  always gives the same output, different input gives a wildly different output.
- **SHA-256** produces a 64-character hex string regardless of input size.
- The **avalanche effect** means even a one-byte change completely changes the
  hash -- there is no such thing as a "small" hash difference.
- Hashes are **one-way**: you cannot reverse a hash to recover the original
  data.
- **PCR extension** chains hashes into a running total that can be extended but
  never reversed. The final value encodes the entire history of what was
  measured and in what order.

## How this connects to the project

IMA (Integrity Measurement Architecture) hashes every program the agent runs
and every file root reads. Each hash is extended into PCR 10 of the TPM. The
verifier replays this hash chain and compares the result to the TPM's reported
value. If they match, it knows the measurement log has not been tampered with.
Then it checks each individual hash against the signed allowlist -- a recorded
set of expected fingerprints.

When the agent modifies its AppArmor profile, the new version gets hashed and
extended into the PCR. The hash does not match the allowlist, and attestation
fails. Even if the agent restores the original file, the PCR now contains both
the tampered hash and the restored hash -- the history is append-only, and the
expected chain no longer matches. The agent cannot hide what it did because it
cannot un-extend the PCR.

## Next

[Module 06: SSH Fundamentals](../06-ssh-fundamentals/README.md)
