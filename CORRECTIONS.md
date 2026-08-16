# CORRECTIONS

Bugs found the hard way during the original manual build. Each one cost real
time. They are published here as errata so nobody pays for them twice, and so
you can recognise them if you hit a variant. The scripts already contain every
fix; the file references point at where.

## 1. `/etc/ima/` does not exist on a fresh image

Writing the IMA policy to `/etc/ima/ima-policy` fails silently or loudly
depending on the tool, because the directory is not there. **Fix:** `mkdir -p
/etc/ima` before writing. (`scripts/20-workload.sh`)

## 2. `/var/lib/harden/` does not exist either

`tpm2_createek` will not create its output directory and fails with an opaque
error that says nothing about a missing path. **Fix:** `mkdir -p` before any
TPM key ceremony. (`scripts/30-tpm-keys.sh`)

## 3. `ima_policy=tcb` on the kernel line contradicts a custom policy file

You get the union of both policies: the custom rules *and* the very broad
built-in `tcb` rules. The allowlist balloons to an unusable size and every
rebaseline takes forever. **Choose one.** This project uses a custom policy
file only, and `20-workload.sh` actively strips `ima_policy=tcb` from
`/etc/default/grub` if a previous attempt left it there.

## 4. AppArmor `/usr/bin/python3*` does not match `python3.14`

An AppArmor glob does not cross a dot. `python3*` matches `python3` but not
`python3.14`, so the agent dies with a permission error the moment the
interpreter is the versioned binary. **Fix:** `/usr/bin/python3{,.*}`.
(`scripts/40-apparmor.sh`)

## 5. The allowlist generator must strip the `sha256:` prefix

IMA writes measurements as `sha256:<hash>`; the verifier compares bare
hashes. If one side keeps the prefix, *nothing ever matches* and every single
measurement reads as a violation — which looks exactly like a catastrophic
compromise and is actually a string-prefix bug. **Fix:**

```sh
awk '{split($4,h,":"); print h[2], $5}' ascii_runtime_measurements
```

(`scripts/70-baseline.sh` generating; `verifier/attest-once.py` comparing.)

## 6. Fleet SSH CA setup — three separate traps

- Push the **CA public key** to each fleet host (not the private key, not the
  agent's key).
- Trust it via **`TrustedUserCAKeys`** in `sshd_config`. `@cert-authority`
  looks like the same thing but lives in `known_hosts` and governs **host**
  keys — a different mechanism that will never authenticate a user.
- Create the **`harden` user** on every fleet host. A valid certificate for a
  principal that does not exist authenticates nobody.

(`scripts/60-fleet.sh`)

## 7. DHCP reassigns the VM address on every rebuild

The verifier's SSH target silently goes stale. **Fix:** pin the address on
the instance's NIC device (`lxc config device set … ipv4.address=…`), and
detect the interface name from inside the guest rather than assuming `eth0` —
on the reference build it is `enp5s0`. (`scripts/20-workload.sh`,
`scripts/lib/detect.sh`)

## 8. The agent crashes on an empty model response

`json.loads("")` raises `ValueError`. A model endpoint that is down or
returns nothing is a *normal operating condition*, and it must produce one
clear sentence naming the endpoint — not a stack trace in the middle of a
recording. (`agent/agent.py`, `ask_model`)

## 9. apport turns every failure into forty lines of noise

Any nonzero exit inside the VM sprouted crash-report chatter that made
recordings unreadable. **Fix:** disable apport in the VM during provisioning.
(`scripts/20-workload.sh`)

## 10. Editing the agent invalidates the allowlist

Change one byte of `agent.py` and the next attestation fails, because IMA
measures the new binary. **This is correct behaviour** — the system cannot
tell a legitimate edit from a malicious one, and must not try. The workflow
is: edit, redeploy (`scripts/50-agent.sh`), then `make rebaseline` to
regenerate and re-sign the allowlist. If attestation fails right after you
changed something, you are looking at bug #10, not a compromise.
