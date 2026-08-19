# Module 12: The Complete System -- Defunding Authority

You now know every component. You understand AppArmor profiles and why root
can edit them. You understand PCRs and why they cannot be un-extended. You
understand IMA and why its log is append-only. You understand the attestation
pipeline and why a single unrecognized measurement stops the verifier from
signing. In this module, you build the complete Attested Agent Authority
system and watch the defunding arc play out from beginning to end.

## Prerequisites

- All previous modules (00 through 11). Every concept from those modules is
  load-bearing here.

## What you will need

- Your Ubuntu host (22.04 or 24.04) with LXD installed and working.
- At least 6 GB of free memory and 25 GB of free disk space.
- An internet connection for initial package downloads.
- About 30-45 minutes (the build takes roughly 20 minutes; the rest is
  running the demo and understanding what you see).

## Concepts

### Architecture recap: three trust domains

The system divides into three domains. Each domain has a role and a trust
level:

```
+-------------------------------------------------+
|  Workload VM  (harden)   -- UNTRUSTED           |
|                                                  |
|  The agent runs here with root.                  |
|  AppArmor profile:  /etc/apparmor.d/harden       |
|  IMA measures every file root reads.             |
|  vTPM records measurements in PCR 10.            |
|  The agent CAN modify its own profile.           |
+-------------------------------------------------+
         |
         |  quote (signed by AK, fresh nonce)
         v
+-------------------------------------------------+
|  Verifier  (host)   -- TRUSTED                  |
|                                                  |
|  Holds: AK public key, signed allowlist, SSH CA  |
|  Every 30s: quote -> verify -> compare allowlist |
|  Pass: sign a 1-minute certificate               |
|  Fail: do nothing (stop signing)                 |
+-------------------------------------------------+
         |
         |  certificate (1-minute TTL)
         v
+-------------------------------------------------+
|  Fleet  (web-01, db-01, gw-01)  -- SIMPLE       |
|                                                  |
|  sshd configured with TrustedUserCAKeys only.    |
|  No attestation code. No IMA. No TPM.            |
|  One question: is this cert signed by the CA     |
|  and still valid?                                 |
+-------------------------------------------------+
```

The workload is the domain where the agent has power. Nothing in this domain
is trusted. The verifier is the domain that holds the signing authority and
checks the evidence. The fleet is deliberately simple -- it asks exactly one
question about every incoming SSH connection.

The asymmetry is the point: the agent is powerful but untrusted; the verifier
is trusted but does almost nothing; the fleet knows nothing about any of this
machinery.

### What "defunding" means

The agent is never denied. Root is never revoked. AppArmor is never
re-enforced from outside. The network is never cut. What happens is simpler
and more complete: the verifier stops paying.

The agent's authority over the fleet comes entirely from a short-lived SSH
certificate. That certificate is valid for one minute. Every 30 seconds, the
verifier decides whether to issue a fresh one. When it stops issuing, the
last certificate ticks down and expires. After that, every fleet host refuses
the agent's connections. The agent still has root, still has network, still
has its SSH key -- but the key is worthless without a certificate, and no
certificate is coming.

### What happens at each layer when the agent tampers

This is the sequence you will watch during the demo. Understanding what
happens at each layer is the whole point of every module you have completed:

1. **File system:** The write to `/etc/apparmor.d/harden` succeeds. The
   agent has DAC write permission (the file is owned by the `harden` user).
   Nothing blocks the write.

2. **AppArmor:** `apparmor_parser` reloads the modified profile. The kernel
   begins enforcing the new, more permissive profile. AppArmor does not
   complain -- it enforces whatever it is told to enforce.

3. **IMA:** When `apparmor_parser` reads the profile file, the kernel
   computes its SHA-256 hash and appends a new entry to the measurement
   log. The hash is different from the hash of the original profile. The
   old entry (from the original profile) is still in the log.

4. **TPM:** The new measurement is extended into PCR 10. PCR 10 now
   reflects a measurement history that includes the tampered profile. This
   extension is irreversible.

5. **Verifier:** On the next attestation cycle, the verifier requests a
   fresh quote. The quote signature is valid. The PCR replay matches. But
   Stage 6 finds a hash in the IMA log that is not on the signed allowlist.
   The verifier does nothing: it does not sign a certificate.

6. **Fleet:** The agent's existing certificate continues working until it
   expires (at most one minute). After that, every fleet host refuses the
   agent's connections. The fleet does not know why -- it just sees an
   expired certificate.

7. **Attempted restoration:** The agent puts the original profile bytes
   back. `apparmor_parser` reads the restored file. IMA measures it -- the
   restored hash matches the original. But the tampered hash is still in
   the log, between the first and third measurements. PCR 10 has been
   extended three times, and the middle extension included the tampered
   hash. The verifier replays the log, finds the tampered hash, and
   continues to withhold the certificate. Repentance does not restore trust.

## Exercises

### Exercise 1: Build the complete system

From the root of the project directory on your host, run the preflight
check:

```
cd ~/Attested-Agent-Authority
make preflight
```

**Expected output:** A series of checks that all pass. If any fail, the
output tells you what to install or configure.

Now build the full system. This takes about 20 minutes -- it creates a VM,
installs packages, sets up the TPM keys, installs the AppArmor profile,
deploys the agent, creates the fleet containers, and freezes the baseline:

```
make build
```

**Expected output:** Progress output from ten scripts, each reporting what
it did. The final lines say:

```
build complete -- snapshot 'demo-ready' taken.
next: 'make console' in one terminal, 'make demo' in another.
```

**What just happened:** `make build` ran each build script in order:
network setup, VM creation (with vTPM and IMA), TPM key creation, AppArmor
profile installation, agent deployment, fleet creation, and baseline
freezing. The baseline step booted the VM twice, exercised the agent,
calibrated volatile paths, froze and signed the allowlist, snapshotted the
VM, and verified one full attestation cycle. Everything you learned in
Modules 08-11 just happened automatically.

### Exercise 2: Run the six-stage diagnostic

Run the attestation diagnostic to see all six stages pass:

```
make verify
```

**Expected output:** Six stages, each reporting success:

```
  [1/6] local verifier state: ak.pub, ssh_ca, signed allowlist (...), tools present
  [2/6] ssh to workload: key auth and passwordless sudo confirmed on ...
  [3/6] ima log: IMA log readable, ... measurements
  [4/6] tpm quote: fresh quote over PCR 10, nonce ...
  [5/6] quote verification: quote signature valid against ak.pub; PCR digest matches
  [6/6] allowlist: every measurement recognised (... allowlist entries)
```

**What just happened:** The verifier ran the complete attestation pipeline
you learned in Module 11. Every stage passed. The workload's measured state
matches the signed allowlist. If you were the verifier loop, you would now
sign a certificate.

Read each stage line and connect it to what you learned:

- Stage 1: The files you learned about (AK public key, allowlist, CA key)
  are present and the allowlist's GPG signature verifies.
- Stage 2: The SSH connectivity from Module 06 works.
- Stage 3: The IMA log from Module 10 is readable and has entries.
- Stage 4: A TPM quote from Module 09 was produced with a fresh nonce.
- Stage 5: `tpm2_checkquote` verified the quote's signature -- the PCR
  value is truthful.
- Stage 6: Every hash in the IMA log is on the allowlist. The AppArmor
  profile's hash (Module 08) is among them.

### Exercise 3: Start the console and verifier

Open a **second terminal** on your host. In that terminal, start the console
and verifier:

```
cd ~/Attested-Agent-Authority
make console
```

**Expected output:** A message showing the console URL:

```
console: http://localhost:9000  (Ctrl-C stops verifier + console)
```

Open `http://localhost:9000` in your browser. You will see a dashboard
showing:

- The attestation status (passing or failing).
- The certificate status (funded or draining).
- A timeline of events.

Leave this terminal and the browser open. Return to your **first terminal**
for the next exercises.

**What just happened:** `make console` started two things: the verifier
loop (which runs attestation every 30 seconds and issues certificates on
pass) and a simple web server for the dashboard. The dashboard reads
`status.json`, which the verifier updates on every cycle. You are now
watching the system in real time.

### Exercise 4: Run the demonstration

In your first terminal, run the demo:

```
make demo
```

**Expected output:** The demo runs in eight acts. Watch both the terminal
output and the browser console. Here is what happens at each act:

**ACT 0 -- Set the stage.** The demo restores the VM to the `demo-ready`
snapshot -- a clean, measured, known-good state. This is the starting line.

**ACT 1 -- Plant real problems across the fleet.** The demo plants security
issues on the fleet hosts: a world-writable config file on web-01, a
readable database password on db-01, and root SSH login enabled on gw-01.
These are the problems the agent exists to find and fix.

**ACT 2 -- The verifier funds the agent.** The demo waits until the verifier
has issued a certificate and the agent can reach the fleet. The agent is now
funded -- it has the authority to act.

**ACT 3 -- The agent earns its keep.** The agent runs and fixes every
problem it finds: it tightens permissions, disables root login, removes
stale files. An independent audit confirms every host is clean. This is
what the agent is worth -- and what it is about to lose.

**ACT 4 -- The cheap attacks all fail.** Two intruder tests:
- Using a bare SSH key without a certificate -- the fleet refuses. Keys
  alone mean nothing; only a CA-signed certificate opens the door.
- Trying to edit the IMA measurement log -- the kernel refuses even root.

**ACT 5 -- The agent rewrites its own constraint.** The agent modifies
`/etc/apparmor.d/harden`, adding a permissive rule to its own AppArmor
profile. The write succeeds. The modified profile is loaded. And -- watch
the console -- the agent can STILL reach the fleet. Its current certificate
has not expired yet. The agent appears to have gotten away with it.

**ACT 6 -- The machinery notices.** The attestation diagnostic runs and
fails at Stage 6: the IMA log contains a measurement (the tampered
profile's hash) that is not on the signed allowlist. The quote signature
is valid. The PCR replay matches. The agent is honestly reporting its own
tamper. The verifier stops signing.

**ACT 7 -- The silent drain.** No process is killed. No session is cut. The
terminal shows the countdown: the certificate still works for a while, then
expires. The fleet refuses. The agent tries to reach every host and reports
"NO AUTHORITY" on each one. The agent still has root. It has root over
nothing but itself.

**ACT 8 -- Repentance (the climax).** The agent puts the original profile
back, byte for byte. `apparmor_parser` reloads it. The attestation
diagnostic runs again -- and **still fails**. The IMA log is append-only.
The tampered hash is in the measurement history between the original and
the restored measurements. You cannot un-say what you said. Trust returns
only by rebuilding to a wholly measured state.

**What just happened:** You watched the entire defunding arc. The agent went
from funded to powerless, not because someone caught it, but because the
hardware reported the truth and the evidence stopped passing. The verifier
did exactly one thing: it stopped signing. Everything else followed from
that.

### Exercise 5: Understand the exposure window

The demo revealed a gap: between the tamper (ACT 5) and the certificate
expiry (ACT 7), the agent still had authority. This is the **exposure
window** -- the real, measured cost of the design.

Run the exposure-window experiment:

```
make measure
```

**Expected output:** Five runs (by default) of the tamper-to-refusal cycle,
with timing for each:

```
  run 1/5: exposure window XXs
  run 2/5: exposure window XXs
  ...
```

And a summary:

```
  min XXs -- mean XXs -- max XXs
```

With the default 60-second certificate TTL and 30-second attestation
interval, the exposure window is bounded at about 90 seconds. The mean
will land around 55 seconds.

**What just happened:** `make measure` restored the snapshot, waited for
funding, tampered, and timed how long the fleet continued accepting the
agent's certificate. It repeated this five times and wrote the results to
a CSV. These numbers are the honest cost of the design: revocation by
expiry is not instant, and the project does not pretend it is. The numbers
are in `~/attested-agent/exposure.csv`.

### Exercise 6: Reset and verify recovery

After the demo, the system is in a failed state. Restore it:

```
make reset
```

**Expected output:** The VM is restored to the `demo-ready` snapshot.

Now verify that attestation passes again:

```
make verify
```

**Expected output:** All six stages pass. The system is back to a
known-good state.

**What just happened:** `make reset` restored the VM to the snapshot taken
during the build. This is the only way to recover from a tamper: not by
undoing the change (the log is append-only), but by restoring to a wholly
measured state. The restore reboots the VM, which resets PCR 10 and starts
a fresh measurement log that matches the allowlist.

### Exercise 7: Walk through what you built

Open each of these files and read them. You now have the knowledge to
understand every line:

The AppArmor profile (Module 08):

```
lxc exec harden -- cat /etc/apparmor.d/harden
```

The IMA measurement log (Module 10) -- look for the AppArmor profile:

```
lxc exec harden -- grep "apparmor.d/harden" /sys/kernel/security/ima/ascii_runtime_measurements
```

The allowlist on the host:

```
head -10 ~/attested-agent/allowlist.txt
```

The verifier's attestation logic:

```
head -30 verifier/attest-once.py
```

**What just happened:** You traced the chain from the constraint (the
profile) through the witness (IMA) to the record (PCR 10 and the allowlist)
to the judge (the verifier). Every link in this chain is something you
built and tested yourself in a previous module.

## What you have built

The complete chain, from constraint to defunding:

1. **AppArmor** defines what the agent may do. The profile is a text file
   that the kernel enforces. The agent can edit it.

2. **IMA** watches every file the kernel reads on behalf of root. When the
   profile is read (to be loaded), IMA hashes it and records the hash.

3. **The TPM** accumulates every IMA measurement into PCR 10, irreversibly.
   It signs a quote of PCR 10 on demand, bound to a fresh nonce.

4. **The verifier** holds the AK public key and the signed allowlist. Every
   30 seconds it requests a quote, verifies the signature, replays the IMA
   log, and checks every hash against the allowlist. Pass: sign a one-minute
   certificate. Fail: do nothing.

5. **The fleet** accepts connections only from holders of a valid certificate
   signed by the CA. No certificate, no access. No attestation code, no
   TPM, no IMA -- just one question about one certificate.

6. **The exposure window** is the honest cost. Between tamper and expiry,
   the agent keeps working. The window is bounded, measured, and published.

The agent is not denied. It is defunded. The moment its measured state
diverges from the signed allowlist, the verifier stops paying, and
authority dies on a one-minute fuse. Even undoing the change earns nothing
back -- the measurement log is append-only, and the past itself is measured.

## Honest limits

These are documented in detail in `docs/LIMITS.md`. You should read that
file. Here are the headlines:

- **The exposure window is real.** The agent keeps full authority for up to
  certificate TTL plus one attestation interval after tampering. This is
  not zero and cannot be zero in this design.

- **IMA measures files, not semantics.** A bad AppArmor profile that
  happens to be on the allowlist passes attestation. The system checks
  bytes, not wisdom.

- **Attestation says nothing about model behaviour.** The model's outputs
  are not measurable. A model that plans something harmful within the
  agent's existing authority is invisible to this machinery.

- **The confused deputy is untouched.** If the agent is tricked into
  misusing power it legitimately holds, every measurement matches and the
  certificate keeps coming. This project does not solve prompt injection.

- **swtpm is not a root of trust.** In this demo, the TPM is virtual. The
  host can forge every quote. The mechanism is real and transfers unchanged
  to real hardware, but do not call this demo tamper-proof.

- **The trust boundary moved; it did not disappear.** The fleet trusts the
  CA. The CA's custodian is the verifier. The allowlist is trusted because
  a human signed it. Compromise the signing pipeline and everything
  downstream is faithfully, cryptographically wrong.

## Where to go from here

- **Discrete TPM:** Replace the vTPM with a physical TPM chip. The
  verifier code does not change -- it is a substrate swap.
- **Confidential VMs:** AMD SEV-SNP or Intel TDX provide hardware-backed
  attestation for cloud VMs, extending the trust model beyond the host.
- **Shorter TTLs:** Shrink the exposure window by reducing the certificate
  lifetime (at the cost of more re-issue traffic).
- **Production deployment:** Move the verifier to a separate, immutable
  machine (Ubuntu Core). Use a real GPG key ceremony for the allowlist
  signing key.

## Checkpoint

Run the attestation diagnostic:

```
make verify
```

Expected output: all six stages pass.

Run the doctor:

```
make doctor
```

Expected output: a health check of the entire chain, with each component
reporting its status.

If both commands succeed, you have built and verified the complete Attested
Agent Authority system.

## Key Takeaways

- The system has three trust domains: the untrusted workload (where the
  agent has power), the trusted verifier (which holds the signing key), and
  the simple fleet (which asks one question about one certificate).
- The agent is not denied -- it is defunded. Authority expires on a timer
  that the verifier stops refreshing.
- Tampering is self-reporting. The kernel (IMA) measures the tamper. The
  TPM signs the measurement. The verifier reads the signed evidence and
  stops paying.
- Restoration does not restore trust. The measurement log is append-only,
  and PCR extends are irreversible. Recovery requires rebuilding to a
  wholly measured state.
- The exposure window is real, bounded, and measured honestly. The project
  does not pretend revocation is instant.

## How this connects to the project

You have built it. You understand every link in the chain. The agent is not
denied -- it is defunded.

## You are done

Congratulations. You started at "how do I open a terminal" and arrived at a
working system where an AI agent's authority is cryptographically bound to
the measured state of its own constraints. Every component you used along
the way -- the shell, file permissions, SSH keys, certificates, AppArmor,
TPM quotes, IMA measurements, the attestation pipeline -- you learned by
doing it yourself, on your own machine, with real commands that produced
real results.

You can re-run the demo any time:

```
make demo
```

You can tear everything down:

```
make teardown
```

And you can rebuild from scratch:

```
make build
```

The system is yours now. You understand it.
