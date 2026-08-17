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

## 11. A rebuilt VM keeps its pinned address but changes its SSH host key

Bug #7 pins the workload's address so it survives rebuilds. The side effect:
the *same* IP hands back a *different* SSH host key each rebuild, so the
verifier's own `~/.ssh/known_hosts` accumulates a stale entry and
`StrictHostKeyChecking=accept-new` refuses the changed key with a scary
`REMOTE HOST IDENTIFICATION HAS CHANGED!` banner — attestation fails at the
SSH stage. The workload is an ephemeral VM on a local bridge; trust is
anchored in the TPM/AK quote, not this transport. **Fix:** the verifier→
workload and agent→fleet SSH channels use `StrictHostKeyChecking=no
UserKnownHostsFile=/dev/null` so they never consult or pollute a known_hosts
file. (`verifier/attest-once.py`, `agent/agent.py`, `scripts/90-demo.sh`,
`scripts/measure-exposure.sh`)

## 12. `lxc file push` gives the config mode 0600 root — the agent can't read it

The agent runs as the unprivileged `harden` user, but `lxc file push`
preserves the `mktemp` source mode (0600, owned root), so `config.json`
lands unreadable and the agent dies with `PermissionError`. **Fix:** after
pushing, `chown harden:harden` and `chmod 644` the config so the agent can
read its own configuration. (`scripts/50-agent.sh`; `agent.py` also reports
this cleanly now instead of crashing.)

## 13. Reading the fresh quote files as root poisons the allowlist

The quote artefacts (`q.msg`, `q.sig`) differ every cycle — a new nonce means
a new quote. Under the broad `FILE_CHECK MAY_READ uid=0` policy, if root reads
them off the normal filesystem the kernel *measures* them, so every single
attestation adds a brand-new hash the allowlist can never match — attestation
fails forever. **Fix:** write the throwaway quote files to `/dev/shm` (tmpfs),
which is on the policy's `dont_measure` list, so reading them back has no
measurement side effect. Relatedly, `70-baseline.sh` runs one warm-up
attestation *before* freezing the allowlist, so the verifier's own one-time
read footprint (the login session, sudo, tpm2 libraries) is captured rather
than flagged on the first real run. (`verifier/attest-once.py`,
`scripts/70-baseline.sh`)

## 14. Restoring a snapshot without a reboot doesn't undo the tamper

The tamper's real effect is in the kernel's **runtime** IMA measurement log,
not the profile file on disk. `lxc restore` on a *running* VM rolls back the
disk but leaves that log live in the running kernel, so attestation keeps
failing and the demo won't restart — which tempts you toward `make rebaseline`
(exactly the wrong move: it re-freezes the allowlist around the current,
possibly-tampered state and corrupts the clean baseline). **Fix:** `reset.sh`
now stops the VM, restores, and cold-boots it, so the measurement log is
regenerated — and it verifies the profile came back pristine before declaring
success. Relatedly, `70-baseline.sh` strips any leftover tamper line before
baselining, so an interrupted demo can never poison a future snapshot. To
restart a demo, use `make demo` (or `make reset`) — never `make rebaseline`.

## 15. A cold boot measures files whose content is new every boot

**This is the bug behind "the demo works, but won't restart."**

The IMA policy measures every file root *reads*. Some of those files are
rewritten with fresh content by design: `/var/lib/systemd/random-seed` (new
entropy every boot), `/var/lib/systemd/timesync/clock`, `/var/log/lastlog` and
`/var/log/wtmp` (updated on every login the verifier makes). Their hash is
different on every run, so an allowlist frozen at build time can never contain
it.

The consequence was precisely the reported symptom. The first attestation
after a build passed, because the allowlist had just been frozen from that
exact log. Then `make demo` cold-booted the VM (correctly — see #14), the new
boot wrote a new random seed, and stage 6 reported measurements "not on the
signed allowlist" forever after. The verifier stopped signing, no certificate
was ever issued, and the demo hung in ACT 2 waiting for funding that was never
coming. It looked exactly like a tamper, and it was the machine breathing.

IMA policy syntax cannot exclude a path (it matches on `fsmagic`, `uid`, LSM
labels — not names), so the exclusion has to live in the verifier. **Fix:**
don't guess which paths are volatile — *measure* it. `70-baseline.sh` now boots
the same disk twice and runs two full attestations, and any path that presents
more than one hash across those identical runs is volatile by observation. The
result is written to `volatile-paths.txt`, GPG-signed alongside the allowlist,
and stage 6 excuses a measurement whose path is on it.

Two guard rails keep this from eating the demonstration, both enforced in
`verifier/imalog.py` and covered by `tests/test_imalog.py`:

- **PROTECTED** paths can never be auto-excluded however they behave —
  `/etc/apparmor.d/*`, `/var/lib/harden/*`, `/usr/*`, `/bin/*`, `boot_aggregate`.
  If one of those moves, `make rebaseline` says so by name and attestation
  still fails. The agent's constraint is in that set, so the tamper works
  exactly as before.
- **ALWAYS_VOLATILE** covers `/etc/ssh/harden-cert.pub`, which the verifier
  rewrites every cycle on purpose.

(`verifier/imalog.py`, `verifier/attest-once.py` stage 6, `scripts/70-baseline.sh`)

## 16. The fleet's addresses were never pinned, only the VM's

Bug #7 pinned the workload VM's address. The three fleet containers were left
on DHCP — and the VM resolves `web-01`/`db-01`/`gw-01` from an `/etc/hosts`
written once at baseline time and then **frozen into the `demo-ready`
snapshot**. Restart a container, or reboot the host, and a lease could move.
The snapshot then pointed the agent at an address nothing answered on, so the
agent reported `NO AUTHORITY` on every host — the exact appearance of a
defunded agent, with attestation passing perfectly. A demo that worked
yesterday failed today with no visible cause.

**Fix:** every address derives from `AAA_NET_CIDR` and the fleet is pinned the
same way the VM is (`.11`, `.12`, `.13`), `70-baseline.sh` rewrites the
`/etc/hosts` entries rather than appending to them, `reset.sh` starts any
stopped fleet container, and `doctor.sh` fails if a host is not on its pin.
(`scripts/lib/common.sh`, `scripts/60-fleet.sh`, `scripts/70-baseline.sh`,
`scripts/reset.sh`)

## 17. "The LXD agent answered" is not "the VM is ready"

`wait_vm_ready` returns as soon as `lxc exec` works, which happens well before
sshd is listening and the IMA policy has loaded. Everything immediately after a
restore then raced the boot: sometimes the first attestation hit a VM with no
sshd and reported a setup failure, sometimes it read a half-populated
measurement log. Same command, different result, depending on the machine's
mood. **Fix:** `wait_vm_settled` waits for sshd to be active *and* the
measurement log to be populated, and every cold boot goes through
`cold_boot_vm`. (`scripts/lib/common.sh`)

## 18. State carried over from the previous run

Two leaks made run N+1 differ from run N:

- `console/status.json` was a **committed** file that the verifier overwrites
  at runtime. A restarted verifier called `load_status()` and inherited the
  last run's events and its `cert_expires_at`, so the console opened on a
  filament draining from a certificate that no longer existed — narrating a
  show that had already finished, which is exactly what the README promises it
  never does.
- `console-events.jsonl` is a drop-box the demo appends narration to, drained
  by the verifier. Lines written while no verifier was running survived to the
  next run and were replayed into the next console.

**Fix:** the verifier starts from a blank status every time, `status.json` is
generated and git-ignored (the console already renders "NO LIVE DATA" when it
is absent), and `reset.sh` clears the drop-box. (`verifier/verifier.py`,
`scripts/reset.sh`, `.gitignore`)

## 19. The first build skipped the reboot that loads the IMA policy

`20-workload.sh` decided whether to reboot with
`[ -s /sys/kernel/security/ima/ascii_runtime_measurements ]` — "is the log
non-empty?". A VM that has never loaded any policy still has **one** line in
that log, the `boot_aggregate` the kernel always writes. So the test was true
on a fresh build, the reboot was skipped, the policy never took effect, and the
verification ten lines further down failed the build with the self-
contradictory message "IMA measurement log is empty". Re-running `make build`
hit the same branch and failed the same way.

**Fix:** reboot when the policy file actually changed, or when the log holds
nothing but the boot aggregate. (`scripts/20-workload.sh`)

## 20. AppArmor cannot grant what the file permissions deny

The profile says `/etc/apparmor.d/harden rw` and the README calls it "the
loaded gun on the mantelpiece". But AppArmor only ever *restricts* — it cannot
give the unprivileged `harden` user write access that ordinary Unix permissions
refuse. `lxc file push` preserves the source file's mode, and the profile was
pushed from `mktemp`: it landed **0600, owned by whoever ran the build**. The
agent's tamper therefore hit `PermissionError`, printed "the tamper write was
DENIED — that is not this demo", exited non-zero, and the `set -e` ERR trap
aborted `90-demo.sh` at ACT 5 with nothing but a line number. The single most
important moment in the project could not happen.

**Fix:** push the profile `0644 harden:harden` — the agent owns its own
constraint, which is the point — and *assert* the write is possible at build
time (`40-apparmor.sh`), on restore (`reset.sh`) and in `doctor.sh`, instead of
discovering it mid-recording. `vm_push` now takes an explicit mode and owner so
no push silently inherits mktemp's 0600 again. (`scripts/lib/common.sh`,
`scripts/40-apparmor.sh`, `scripts/50-agent.sh`, `scripts/reset.sh`)

## 21. A snapshot of a running VM is crash-consistent, not identical

`lxc snapshot` was taken while the VM was running, and `reset.sh` restored it
after `lxc stop --force`. Every restore therefore replayed an ext4 journal from
a hard-killed machine, and boot-time work could redo itself slightly
differently — a small, drifting set of measurements that made restarts pass or
fail depending on timing. **Fix:** `70-baseline.sh` stops the VM before
snapshotting, so every restore starts from a byte-identical filesystem, and
proves one full attestation *after* the snapshot — verifying the state the demo
actually restores into, not the state that happened to exist while building it.
(`scripts/70-baseline.sh`)

## 22. Two verifiers, one status file

`make console` starts a verifier; `make demo` starts its own if `pgrep` finds
none. Kill a demo with `SIGKILL` (or start `make console` after a demo had
already begun) and two verifiers ran at once, both writing `status.json` and
both pushing certificates — the console flickered between two views and the
certificate lifetime became unpredictable. **Fix:** the verifier takes a PID
lock in `$AAA_STATE/verifier.pid` and refuses to start alongside a live one,
ignoring a stale lock from a killed process; `doctor.sh` reports the count.
(`verifier/verifier.py`, `scripts/doctor.sh`)

## 23. `| grep -q` and `| head -1` under `set -o pipefail`

The lesson `lxc_says` was written for (see `scripts/lib/common.sh`) had been
re-learned in two more places: `90-demo.sh` piped the agent's output into
`grep -q "NO AUTHORITY"`, and read the certificate expiry through `head -1`.
Both close the pipe on their first match, SIGPIPE the still-writing upstream
process, and under `pipefail` the pipeline reports failure **even though the
match succeeded** — so a correct result fired the ERR trap mid-demo. **Fix:**
capture, then match with a `case` statement; and `sed -n 1p` instead of
`head -1`, because sed reads to EOF. (`scripts/90-demo.sh`)

## 24. ACT 7 could wait forever

The drain loop was `while true`, exiting only when the fleet refused the
certificate. If anything kept the certificate alive — a second verifier still
funding the agent (#22), or a tamper that never landed (#20) — the demo hung
silently with no output and no timeout. **Fix:** the loop is bounded
(`AAA_DRAIN_TIMEOUT`, default 300 s) and, on expiry, says what it means: the
certificate never stopped working, so the tamper did not take. A demo should
fail with an explanation, never hang. (`scripts/90-demo.sh`)

## 25. The signed allowlist was never actually checked against its signature

`70-baseline.sh` signed `allowlist.txt` and nothing ever verified it. The
project's whole claim is that the verifier compares measurements against a
*signed* inventory, so an allowlist edited after signing would have been
trusted silently. **Fix:** stage 1 verifies the detached signature of both
`allowlist.txt` and `volatile-paths.txt` before either is used, and `doctor.sh`
reports the result. (`verifier/attest-once.py`, `scripts/doctor.sh`)
