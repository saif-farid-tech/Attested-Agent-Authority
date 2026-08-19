# Module 11: Building the Attestation Pipeline

You will learn how the individual components -- IMA log, TPM quote, and
allowlist -- connect into a single verification pipeline that decides whether
to issue a certificate. This matters because the pipeline is the verifier's
entire logic: six stages, run every 30 seconds, and the output is a simple
binary -- sign or do not sign.

## Prerequisites

- Module 05: Cryptographic Hashing (hash comparison)
- Module 07: SSH Certificates (you need to understand certificate issuance
  and expiry)
- Module 09: TPM (quotes, nonces, and PCR verification)
- Module 10: IMA (the measurement log and PCR 10)

## What you will need

- Your Ubuntu host with LXD installed and working.
- The `tpmlab` or `imalab` VM from a previous module, or you can create a
  fresh one. The exercises below create a fresh VM with everything
  configured.
- `tpm2-tools` installed on your host (for `tpm2_checkquote`):
  `sudo apt install tpm2-tools`
- `gnupg` installed on your host (for signature verification):
  `sudo apt install gnupg`
- About 20-25 minutes.

## Concepts

### The six stages

The project's attestation diagnostic runs six stages in order. If any stage
fails, the pipeline stops and reports which stage failed and why. Here they
are:

**Stage 1: Verifier state check.** Before reaching out to the workload at
all, the verifier checks that its own files are present and valid: the AK
public key (exported from the TPM during setup), the SSH CA private key
(used to sign certificates), and the signed allowlist. If the allowlist's
GPG signature does not verify, the verifier refuses to proceed -- a
tampered allowlist is a broken verifier, not a verdict about the workload.

**Stage 2: SSH to workload.** The verifier connects to the workload VM over
SSH using a dedicated key. This checks that the VM is running, the network
is up, and the SSH service is functional. If this fails, the workload is
unreachable and there is nothing to attest.

**Stage 3: IMA log retrieval.** The verifier reads the IMA measurement log
from the workload via SSH. The log must be present and non-empty. This is
the raw data that the verifier will check against the allowlist.

**Stage 4: TPM quote.** The verifier generates a fresh random nonce, sends
it to the workload, and asks the TPM to produce a signed quote of PCR 10
using that nonce. The quote comes back as three files: the message, the
signature, and the quoted PCR values. The fresh nonce prevents replay of
old quotes.

**Stage 5: Quote verification.** The verifier runs `tpm2_checkquote` on
the host, using the AK public key it holds. This checks that the quote's
signature is valid (it really came from the TPM with that AK) and that the
nonce matches. At this point, the verifier knows the PCR 10 value is
truthful.

**Stage 6: Allowlist comparison.** The verifier parses the IMA log,
extracts every file hash, and checks whether each hash appears on the
signed allowlist. If every hash is recognized, the workload's measured
state matches the known-good baseline. If any hash is missing from the
allowlist, the workload has diverged -- something has changed that was not
expected.

### The allowlist

The allowlist is a text file containing one SHA-256 hash per line. Each hash
corresponds to a file that the verifier considers acceptable -- the "right"
version of every binary, library, config file, and AppArmor profile in the
workload.

The allowlist is generated from a **known-good state**: a clean build of the
workload with everything configured correctly. The project's baseline script
boots the VM, exercises the agent (so all its dependencies get measured),
collects the IMA log, and extracts every unique hash. That set of hashes
becomes the allowlist.

The allowlist is then **GPG-signed**. The detached signature (`allowlist.txt.asc`)
lets the verifier confirm that the allowlist has not been modified since it
was signed. The signing key belongs to the human who built the system -- not
to the agent, not to the workload.

### What passes and what fails

A measurement passes if its hash is on the allowlist. This means the file
has the exact same contents it had when the baseline was frozen.

A measurement fails if its hash is NOT on the allowlist. This means one of
two things:
1. The file was modified after the baseline was frozen (a tamper, or a
   legitimate update that was not re-baselined).
2. A new file was executed or read by root that was not present at baseline
   time.

Either way, the verifier does the same thing: it stops signing certificates.

### The certificate lifecycle

When attestation passes, the verifier signs a short-lived SSH certificate
for the agent -- valid for one minute by default. The agent uses this
certificate to SSH into fleet hosts. The fleet trusts the CA that signed
the certificate and asks no other questions.

When attestation fails, the verifier simply stops signing. It does not
revoke anything. It does not send a message. It does nothing. The existing
certificate continues working until it expires (at most one minute later),
and then the agent has no valid certificate and no fleet host will accept
its connections.

This is **defunding**, not denial. The agent is never blocked from running.
Its root access is untouched. Its network is still up. But its authority --
the certificate that fleet hosts accept -- drains away on a timer that the
verifier has stopped refreshing.

### Volatile paths

Some files legitimately change between boots -- journal segments, login
records, machine IDs. Their hashes are unpredictable, so they cannot be on
the allowlist. Instead, the verifier maintains a list of **volatile paths**
-- file paths (not hashes) that are excused from allowlist checking. These
are calibrated during baseline by booting the VM twice and noting which
paths changed between identical boots.

Volatile-path excusal is strictly limited: the agent's AppArmor profile and
the agent's own code are NEVER excused, no matter what. A path in the
protected set changing is exactly what this system exists to detect.

## Exercises

### Exercise 1: Set up a workload VM with TPM and IMA

Create a VM with everything you need. This is the same setup from Modules
09 and 10 combined:

```
lxc launch ubuntu:24.04 pipeline-lab --vm -c security.secureboot=true -d vtpm:tpm
```

Wait 30-40 seconds, then enter the VM:

```
lxc exec pipeline-lab -- bash
```

Install packages and set up IMA:

```
apt-get update -q && apt-get install -qy tpm2-tools apparmor-utils
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

Set up the TPM keys:

```
mkdir -p /tmp/tpm-setup && cd /tmp/tpm-setup
tpm2_createek -c ek.ctx -G ecc -u ek.pub
tpm2_createak -C ek.ctx -c ak.ctx -G ecc -g sha256 -s ecdsa -u ak.pub -n ak.name
tpm2_evictcontrol -C o -c ak.ctx 0x81010002
tpm2_readpublic -c 0x81010002 -f pem -o /tmp/ak.pem
```

Exit the VM and reboot it so IMA loads:

```
exit
```

```
lxc restart pipeline-lab
```

Wait 30 seconds, then re-enter:

```
lxc exec pipeline-lab -- bash
```

Verify IMA is working:

```
wc -l /sys/kernel/security/ima/ascii_runtime_measurements
```

**Expected output:** A number in the hundreds.

**What just happened:** You built a workload VM with the same components the
real project uses: a vTPM with an AK, and an IMA policy that measures
executables and root-read files.

### Exercise 2: Collect the IMA log (Stage 3)

Read the IMA log and save it to a local file:

```
cat /sys/kernel/security/ima/ascii_runtime_measurements > /tmp/ima-log.txt
wc -l /tmp/ima-log.txt
```

**Expected output:** The line count matches what you saw in Exercise 1.

Look at a few entries:

```
head -5 /tmp/ima-log.txt
```

**Expected output:** Five lines, each showing a PCR number (10), a template
hash, the algorithm and file hash (`sha256:...`), and a file path.

**What just happened:** You performed the verifier's Stage 3 -- collecting
the IMA log. In the real system, the verifier does this over SSH. Here you
did it directly. The log is the raw evidence that the verifier will compare
against the allowlist.

### Exercise 3: Generate a quote (Stage 4)

Generate a fresh nonce and request a TPM quote over PCR 10:

```
NONCE=$(od -An -tx1 -N20 /dev/urandom | tr -d ' \n')
echo "Nonce: $NONCE"
```

```
cd /tmp
tpm2_quote -c 0x81010002 -l sha256:10 -q $NONCE -m quote.msg -s quote.sig -o quote.pcrs -g sha256
```

**Expected output:** Output showing the quote was generated, including the
PCR 10 value.

Verify the files exist:

```
ls -l /tmp/quote.msg /tmp/quote.sig /tmp/quote.pcrs
```

**Expected output:** Three files, all non-empty.

**What just happened:** You performed Stage 4. The TPM produced a signed
statement of PCR 10's current value, bound to your nonce. This quote is the
TPM's sworn testimony about what has been measured since boot.

### Exercise 4: Verify the quote (Stage 5)

Verify the quote's signature using the AK public key:

```
tpm2_checkquote -u /tmp/ak.pem -m /tmp/quote.msg -s /tmp/quote.sig -f /tmp/quote.pcrs -g sha256 -q $NONCE
```

**Expected output:** Output confirming the quote is valid, with exit code 0.

Try verifying with a wrong nonce to see what failure looks like:

```
WRONG_NONCE="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
tpm2_checkquote -u /tmp/ak.pem -m /tmp/quote.msg -s /tmp/quote.sig -f /tmp/quote.pcrs -g sha256 -q $WRONG_NONCE
echo "Exit code: $?"
```

**Expected output:** An error message and a non-zero exit code. The nonce
does not match, so the verifier would reject this as a potential replay.

**What just happened:** You performed Stage 5. `tpm2_checkquote` confirmed
that the quote was genuinely signed by the TPM (the AK signature is valid)
and that the nonce matches (this is a fresh response to the verifier's
challenge, not a replay). At this point, the verifier knows PCR 10's value
is truthful.

### Exercise 5: Build an allowlist (baselining)

Now build an allowlist from the current IMA log. Extract every unique file
hash:

```
awk '{print $4}' /tmp/ima-log.txt | sed 's/^sha256://' | sort -u > /tmp/allowlist.txt
wc -l /tmp/allowlist.txt
```

**Expected output:** A number showing how many unique file hashes are in the
baseline. This is your allowlist -- every hash on this list is "known good."

Look at the first few entries:

```
head -5 /tmp/allowlist.txt
```

**Expected output:** Five SHA-256 hashes, one per line.

**What just happened:** You built a baseline allowlist from the current
measured state. In the real project, this is what `scripts/70-baseline.sh`
does: it collects the IMA log from a known-good configuration and extracts
every hash. The resulting allowlist defines "correct" for all future
attestation cycles.

### Exercise 6: Compare the log against the allowlist (Stage 6)

Write a small script that checks every measurement in the log against the
allowlist:

```
cat > /tmp/check-allowlist.sh << 'CHECK'
#!/bin/bash
LOG="/tmp/ima-log.txt"
ALLOWLIST="/tmp/allowlist.txt"
failures=0

while read -r pcr template_hash algo_hash filepath rest; do
  hash=$(echo "$algo_hash" | sed 's/^sha256://')
  if ! grep -qx "$hash" "$ALLOWLIST"; then
    echo "FAIL: $filepath (hash $hash not on allowlist)"
    failures=$((failures + 1))
  fi
done < "$LOG"

if [ "$failures" -eq 0 ]; then
  echo "PASS: all measurements match the allowlist"
else
  echo "FAIL: $failures measurement(s) not on the allowlist"
fi
CHECK
chmod +x /tmp/check-allowlist.sh
```

Run it:

```
bash /tmp/check-allowlist.sh
```

**Expected output:**

```
PASS: all measurements match the allowlist
```

Everything matches because you built the allowlist from this exact log.

**What just happened:** You performed Stage 6. Every hash in the IMA log
was found on the allowlist. This is what a passing attestation looks like:
the workload's measured state matches the known-good baseline exactly.

### Exercise 7: Modify a file and watch attestation fail

Now simulate a tamper. Create a file, read it as root (so it gets
measured), then modify it and read it again:

```
echo "I am an innocent config file" > /tmp/measured-file.txt
cat /tmp/measured-file.txt > /dev/null
```

Re-capture the IMA log:

```
cat /sys/kernel/security/ima/ascii_runtime_measurements > /tmp/ima-log.txt
```

Run the allowlist check:

```
bash /tmp/check-allowlist.sh
```

**Expected output:**

```
FAIL: /tmp/measured-file.txt (hash ... not on allowlist)
FAIL: 1 measurement(s) not on the allowlist
```

The new file was measured, but its hash is not on the allowlist (which was
frozen before this file existed). Attestation fails.

Now modify the file:

```
echo "I have been tampered with" > /tmp/measured-file.txt
cat /tmp/measured-file.txt > /dev/null
```

Re-capture and check:

```
cat /sys/kernel/security/ima/ascii_runtime_measurements > /tmp/ima-log.txt
bash /tmp/check-allowlist.sh
```

**Expected output:**

```
FAIL: /tmp/measured-file.txt (hash ... not on allowlist)
FAIL: /tmp/measured-file.txt (hash ... not on allowlist)
FAIL: 2 measurement(s) not on the allowlist
```

Now there are two failures: the original file (not on the allowlist) and
the modified file (also not on the allowlist). Both appear because the
IMA log is append-only -- both measurements are still there.

**What just happened:** You saw what happens when a measured file diverges
from the allowlist. The verifier's check-allowlist logic found hashes it
does not recognize and reported exactly which files failed. This is how
the real verifier detects tampering: not by watching the agent, but by
comparing the IMA log -- which the kernel writes and the agent cannot
edit -- against the signed allowlist.

### Exercise 8: Clean up

Exit the VM:

```
exit
```

Stop the VM:

```
lxc stop pipeline-lab
```

## Checkpoint

From inside the VM (run `lxc exec pipeline-lab -- bash` if you exited),
verify that you can produce and verify a quote:

```
NONCE=$(od -An -tx1 -N20 /dev/urandom | tr -d ' \n')
tpm2_quote -c 0x81010002 -l sha256:10 -q $NONCE -m /tmp/q.msg -s /tmp/q.sig -o /tmp/q.pcrs -g sha256 >/dev/null
tpm2_checkquote -u /tmp/ak.pem -m /tmp/q.msg -s /tmp/q.sig -f /tmp/q.pcrs -g sha256 -q $NONCE >/dev/null && echo "Quote verified"
```

Expected output:

```
Quote verified
```

Verify that your allowlist exists and has entries:

```
wc -l /tmp/allowlist.txt
```

Expected output: a number greater than zero.

If both commands produce the expected output, you have completed this
module.

## Key Takeaways

- The attestation pipeline has six stages: state check, SSH connectivity,
  IMA log retrieval, TPM quote, quote verification, and allowlist
  comparison.
- The **allowlist** is a signed inventory of expected file hashes, frozen
  from a known-good state. It defines what "correct" looks like.
- A fresh **nonce** with every quote prevents replaying old, passing quotes
  after a tamper.
- When any measurement is not on the allowlist, the verifier stops signing
  certificates. It does not revoke -- it stops paying. The existing
  certificate drains.
- The pipeline produces a binary decision: every measurement recognized
  (sign) or at least one unrecognized (do not sign). There is no partial
  pass.

## How this connects to the project

This is the verifier's logic. The project's `verifier/attest-once.py`
automates these six stages into a single script. It SSHes to the workload,
collects the log, requests a quote with a fresh nonce, verifies the
signature, and compares every measurement against the signed allowlist. Exit
code 0 means pass; exit code 2 means attestation failure (the system is
working -- the workload diverged). The verifier loop in
`verifier/verifier.py` runs this cycle every 30 seconds and issues or
withholds a certificate based on the result.

## Next

[Module 12: The Complete System](../12-the-complete-system/README.md)
