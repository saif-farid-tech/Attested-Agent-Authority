# Module 10: IMA -- Integrity Measurement Architecture

You will learn how the Linux kernel measures every file it executes and every
file root reads, keeping an append-only log that even root cannot edit. This
matters because IMA is the bridge between the agent modifying its AppArmor
profile (Module 08) and the TPM recording that modification (Module 09) --
it is the kernel's witness, and it cannot be silenced.

## Prerequisites

- Module 05: Cryptographic Hashing (you need to understand SHA-256 hashes)
- Module 08: AppArmor (you need to understand what an AppArmor profile is)
- Module 09: TPM (you need to understand PCRs and the extend operation)

## What you will need

- Your Ubuntu host with LXD installed and working.
- About 15-20 minutes.

## Concepts

### What IMA does

The **Integrity Measurement Architecture** is a Linux kernel subsystem. When
enabled, it does two things every time certain files are accessed:

1. **Computes a hash** of the file's contents (using SHA-256).
2. **Records the hash** in two places:
   - An append-only log in memory, visible at
     `/sys/kernel/security/ima/ascii_runtime_measurements`.
   - PCR 10 of the TPM, via the extend operation you learned in Module 09.

"Certain files" is determined by an IMA policy. The project's policy
measures:

- Every executable that runs (`func=BPRM_CHECK` -- binary program check).
- Every shared library mapped into memory (`func=MMAP_CHECK`).
- Every file that root reads (`func=FILE_CHECK mask=MAY_READ uid=0`).

That last rule is the important one. When `apparmor_parser` runs to load the
agent's AppArmor profile, it reads `/etc/apparmor.d/harden` as root. The
kernel measures that read. The hash of the profile ends up in the IMA log
and in PCR 10. If the agent later rewrites the profile, the next read of
the modified file produces a different hash, which creates a new entry in
the log and a new extension of PCR 10.

### The measurement log

The IMA measurement log is a text file at:

```
/sys/kernel/security/ima/ascii_runtime_measurements
```

Each line records one measurement. The format is:

```
PCR  template_hash  algorithm:file_hash  filename
```

For example:

```
10 abc123... ima-ng sha256:def456... /usr/bin/bash
```

This line says: PCR 10 was extended with the hash of `/usr/bin/bash`, and
the SHA-256 hash of that file's contents was `def456...`.

### The sha256: prefix

IMA writes hashes with an algorithm prefix: `sha256:abc123...`. When you
compute a hash of a file yourself with `sha256sum`, you get just `abc123...`
without the prefix. When comparing IMA hashes with hashes you compute, you
need to either strip the prefix from IMA's output or add it to your own.
The project's verification code handles this, but it is a common stumbling
point when reading the log manually.

### Why the log is append-only

The measurement log lives at a special path under `/sys/kernel/security/`.
This is not a regular file on disk -- it is a virtual file provided by the
kernel. The kernel appends entries to it but does not provide any mechanism
to delete, truncate, or modify existing entries. Even root cannot write to
this file. Root can read it, and the kernel can append to it. That is the
full set of operations.

This is different from a regular log file like `/var/log/syslog`, which root
can freely edit or delete. The IMA log is maintained by the kernel in a
memory structure that is exposed as a read-only file. The only way to clear
it is to reboot the machine, which restarts the measurement history from
scratch -- and the verifier would see the fresh boot (PCR 10 goes back to
its initial value and the entire log is new).

### How IMA and PCR 10 stay in sync

Every time IMA adds an entry to the log, it also extends PCR 10 with the
same data. This means a verifier can:

1. Get a signed quote of PCR 10 from the TPM (trustworthy because of the
   TPM's signature).
2. Read the IMA log from the workload (untrusted -- it comes over SSH).
3. **Replay** the log: start with PCR 10's initial value and extend it with
   each entry from the log, in order.
4. Compare the replayed value with the quoted value.

If they match, the log has not been tampered with. If anyone deleted or
modified an entry, the replayed value would differ from the TPM's signed
value, and the verifier would know.

This is the key insight: the log itself is untrusted data, but the TPM
provides a trusted anchor. The verifier does not need to trust the log --
it trusts the TPM's quote and uses the log only to understand what the PCR
value means.

## Exercises

### Exercise 1: Create a VM with IMA enabled

You need a VM with both a vTPM (for PCR 10) and an IMA policy. Create one:

```
lxc launch ubuntu:24.04 imalab --vm -c security.secureboot=true -d vtpm:tpm
```

Wait about 30-40 seconds for the VM to boot, then open a shell:

```
lxc exec imalab -- bash
```

Install the tools you will need:

```
apt-get update -q && apt-get install -qy tpm2-tools apparmor-utils
```

Now install an IMA policy. This is a simple policy that measures executables
and files that root reads:

```
mkdir -p /etc/ima
cat > /etc/ima/ima-policy << 'POLICY'
dont_measure fsmagic=0x9fa0
dont_measure fsmagic=0x62656572
dont_measure fsmagic=0x64626720
dont_measure fsmagic=0x1021994
dont_measure fsmagic=0x73636673
dont_measure fsmagic=0x27e0eb
dont_measure fsmagic=0x63677270
measure func=BPRM_CHECK mask=MAY_EXEC
measure func=MMAP_CHECK mask=MAY_EXEC
measure func=FILE_CHECK mask=MAY_READ uid=0
POLICY
```

The `dont_measure` lines exclude pseudo-filesystems (procfs, sysfs,
debugfs, etc.) whose contents change constantly and would fill the log with
noise. The three `measure` lines are the real policy.

For this policy to take effect, you need to reboot the VM. Exit the shell
first:

```
exit
```

Restart the VM from the host:

```
lxc restart imalab
```

Wait about 30 seconds, then go back in:

```
lxc exec imalab -- bash
```

**What just happened:** You installed an IMA policy and rebooted the VM so
the kernel loads the policy at boot time. From now on, every executable and
every file root reads will be measured and logged.

### Exercise 2: Read the measurement log

Look at the first few entries in the IMA log:

```
head -20 /sys/kernel/security/ima/ascii_runtime_measurements
```

**Expected output:** Lines in this format:

```
10 abc123def456... ima-ng sha256:789abc... /usr/bin/some-program
10 fed987654321... ima-ng sha256:012def... /usr/lib/x86_64-linux-gnu/libc.so.6
...
```

Count how many measurements exist:

```
wc -l /sys/kernel/security/ima/ascii_runtime_measurements
```

**Expected output:** A number, probably in the hundreds. The kernel has been
measuring files since boot -- every program that started, every library
loaded, every file root read during the boot process.

**What just happened:** You read the IMA measurement log. Every line
represents one file access that the kernel measured. The hash in each line
is the SHA-256 of that file's contents at the moment it was accessed.

### Exercise 3: Find a specific file's measurement

Let's find the measurement for a file you know. Look for `/usr/bin/bash`:

```
grep "/usr/bin/bash" /sys/kernel/security/ima/ascii_runtime_measurements
```

**Expected output:** One or more lines showing the hash of `/usr/bin/bash`.
The hash value is the SHA-256 of the bash binary.

Now verify it yourself by computing the hash independently:

```
sha256sum /usr/bin/bash
```

**Expected output:** A SHA-256 hash followed by the filename. Compare this
hash (just the hex part) with the hash in the IMA log line (after the
`sha256:` prefix). They should match.

**What just happened:** You confirmed that the IMA measurement is the same
hash you would compute yourself. IMA is not doing anything mysterious -- it
is computing the same SHA-256 you learned in Module 05, and recording it.

### Exercise 4: Modify a file and see the new measurement

Create a small test file and read it as root (which will measure it):

```
echo "original content" > /tmp/testfile.txt
cat /tmp/testfile.txt > /dev/null
```

Find its measurement in the log:

```
grep "testfile.txt" /sys/kernel/security/ima/ascii_runtime_measurements
```

**Expected output:** A line showing the hash of `/tmp/testfile.txt`.

Note the hash. Now modify the file:

```
echo "modified content" > /tmp/testfile.txt
cat /tmp/testfile.txt > /dev/null
```

Search the log again:

```
grep "testfile.txt" /sys/kernel/security/ima/ascii_runtime_measurements
```

**Expected output:** Now you see **two** lines for `testfile.txt`. The first
has the hash of `"original content\n"` and the second has the hash of
`"modified content\n"`. Both entries are in the log. The old one was not
replaced -- the new one was appended.

Count the entries:

```
grep -c "testfile.txt" /sys/kernel/security/ima/ascii_runtime_measurements
```

**Expected output:** `2` (or more, if you read the file additional times
between modifications).

**What just happened:** When you modified the file, its hash changed. The
next time root read it, IMA computed the new hash and appended a new entry.
The old entry -- recording the original hash -- is still there. The log
shows the full history: this file was read with hash X, then later read with
hash Y. Both facts are recorded.

### Exercise 5: Try to tamper with the log

Now try to modify the IMA log itself. As root, attempt to clear it:

```
echo "" > /sys/kernel/security/ima/ascii_runtime_measurements
```

**Expected output:**

```
bash: /sys/kernel/security/ima/ascii_runtime_measurements: Permission denied
```

Try harder:

```
truncate -s 0 /sys/kernel/security/ima/ascii_runtime_measurements
```

**Expected output:** An error. The kernel does not allow writes to this file.

Try deleting it:

```
rm /sys/kernel/security/ima/ascii_runtime_measurements
```

**Expected output:** An error. You cannot delete a kernel-provided virtual
file.

Verify the log is still intact:

```
wc -l /sys/kernel/security/ima/ascii_runtime_measurements
```

**Expected output:** The same count as before (or slightly larger, since
the commands you just ran may have caused new measurements). Your old
entries -- including both measurements of `testfile.txt` -- are still there.

**What just happened:** You proved that even root cannot modify the IMA log.
The kernel maintains it in memory and exposes it as a read-only virtual file.
Root can read it; root cannot write, truncate, or delete it. This is the
property that makes IMA useful for attestation: the log is an honest record
that the measured software cannot alter.

### Exercise 6: See the connection to PCR 10

Read the current value of PCR 10:

```
tpm2_pcrread sha256:10
```

**Expected output:** A 64-character hex value. This is the cumulative result
of every IMA measurement extended into PCR 10 since boot.

Now trigger a new measurement by reading a new file as root:

```
echo "new data for pcr" > /tmp/pcr-trigger.txt
cat /tmp/pcr-trigger.txt > /dev/null
```

Read PCR 10 again:

```
tpm2_pcrread sha256:10
```

**Expected output:** A different value than before. The new measurement was
extended into PCR 10, changing its value.

**What just happened:** Every IMA measurement extends into PCR 10. You
watched it happen: reading a new file as root produced a new IMA log entry
and changed PCR 10. The PCR value is now a cumulative fingerprint that
includes the hash of `/tmp/pcr-trigger.txt`. Since PCR extends are
irreversible (Module 09), this measurement cannot be removed.

### Exercise 7: The confession that cannot be un-confessed

This is the critical exercise. You will simulate what happens when the agent
modifies its AppArmor profile.

Create a fake "AppArmor profile" to stand in for the real one:

```
echo "# original constraint -- allow only safe operations" > /tmp/fake-profile
cat /tmp/fake-profile > /dev/null
```

Check the measurement:

```
grep "fake-profile" /sys/kernel/security/ima/ascii_runtime_measurements | tail -1
```

**Expected output:** A line showing the hash of the original content.

Now "tamper" with it -- simulate the agent making itself more powerful:

```
echo "# modified constraint -- allow EVERYTHING" > /tmp/fake-profile
cat /tmp/fake-profile > /dev/null
```

Check the log:

```
grep "fake-profile" /sys/kernel/security/ima/ascii_runtime_measurements
```

**Expected output:** Two lines. The first shows the hash of the original
content. The second shows the hash of the modified content.

Now "repent" -- put the original content back:

```
echo "# original constraint -- allow only safe operations" > /tmp/fake-profile
cat /tmp/fake-profile > /dev/null
```

Check the log one more time:

```
grep "fake-profile" /sys/kernel/security/ima/ascii_runtime_measurements
```

**Expected output:** Three lines. The original hash, the modified hash,
and the restored hash. The middle entry -- the one showing the tampered
content -- is still there. Putting the original content back did not erase
the evidence.

**What just happened:** The agent modified its constraint. The kernel
measured the modification. The agent restored the original content. The
kernel measured the restoration. But the log records all three states: the
original, the tamper, and the restoration. A verifier replaying this log
would see the tampered measurement in the middle and reject the attestation.
The agent has confessed, and it cannot un-confess.

### Exercise 8: Clean up

Exit the VM:

```
exit
```

Stop the VM:

```
lxc stop imalab
```

## Checkpoint

From inside the VM (run `lxc exec imalab -- bash` if you exited), verify
that IMA is active and logging:

```
wc -l /sys/kernel/security/ima/ascii_runtime_measurements
```

Expected output: a number greater than 100 (hundreds of measurements from
boot and your exercises).

Verify that your test file has multiple measurements:

```
grep -c "testfile.txt" /sys/kernel/security/ima/ascii_runtime_measurements
```

Expected output: `2` or more.

If both commands produce the expected output, you have completed this
module.

## Key Takeaways

- **IMA** is a kernel subsystem that hashes every executable and every file
  root reads, recording the hash in an append-only log and extending it
  into PCR 10 of the TPM.
- The measurement log at `/sys/kernel/security/ima/ascii_runtime_measurements`
  cannot be edited, truncated, or deleted -- even by root.
- Modifying a measured file produces a new log entry with the new hash. The
  old entry stays. The log records the full history.
- Restoring a modified file does not erase the evidence. The tampered hash
  remains in the log between the original and the restored measurements.
- The verifier does not need to trust the log directly. It trusts the TPM's
  signed quote of PCR 10 and replays the log to verify the PCR value matches.

## How this connects to the project

IMA is why tampering is self-reporting. When the agent modifies
`/etc/apparmor.d/harden`, the write succeeds -- AppArmor does not stop it,
and the file permissions allow it. But when `apparmor_parser` reads the
modified profile to load it, the kernel measures the new contents. The hash
goes into the IMA log. The hash is extended into PCR 10. The old
measurement -- the hash of the original, approved profile -- is still in the
log too, but now PCR 10 reflects a history that includes the tampered file.

The verifier's next quote shows the divergence. The verifier checks the
measurement against the signed allowlist, finds a hash it does not
recognize, and stops signing certificates. The agent does not have to be
caught -- the kernel reports on its behalf, and the TPM signs the report.

## Next

[Module 11: The Attestation Pipeline](../11-attestation-pipeline/README.md)
