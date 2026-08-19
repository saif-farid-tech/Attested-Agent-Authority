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

## 26. `tpm_device` is not the name of any LXD API extension

`00-preflight.sh` checked for vTPM support by looking for `"tpm_device"` in
the `api_extensions` array of `GET /1.0`. The extension is called
**`tpm_device_type`**, and the check matched with the quotes included, so
`"tpm_device"` never matched `"tpm_device_type"` — on any LXD, at any version,
forever. Since `make build` depends on `make preflight`, **the documented way
into this project was permanently shut**, with a fix instruction
(`sudo snap refresh lxd`) that could not possibly help. The irony is complete
two scripts later: `20-workload.sh` attaches the vTPM successfully on exactly
the machine preflight has just declared incapable of one.

Which is why the failure was so expensive: told the front door was broken,
you start running the numbered scripts by hand, in the wrong order, and every
subsequent error is about *that* instead of about anything real.

**Fix:** `detect_lxd_ext` takes one or more names and matches them exactly;
`detect_lxd_vtpm` asks for `tpm_device_type`. `20-workload.sh` no longer trusts
preflight to have caught it either — if `lxc config device add … tpm` fails it
says what that means instead of leaving the ERR trap to print a line number.
Both names are covered by `tests/test_vm_probe.sh`, so a wrong extension name
can never again be discovered by a user rather than by `make selftest`.
(`scripts/lib/detect.sh`, `scripts/00-preflight.sh`, `scripts/20-workload.sh`)

## 27. "sshd is not listening" was a lie: Ubuntu socket-activates it

`wait_vm_settled` (#17) decided the VM was usable when

```sh
systemctl is-active ssh || systemctl is-active sshd
```

succeeded. On Ubuntu 22.10 and later — the workload VM is 24.04 — **sshd is
socket-activated**: `ssh.socket` holds port 22 and `ssh.service` reports
`inactive` until a connection actually arrives. The gate was therefore false on
a completely healthy VM, forever, and every path that cold-boots the VM ran its
90 attempts and then died:

- `20-workload.sh`, on the reboot that loads the IMA policy — so the **first
  build never finished**;
- `70-baseline.sh` — so `make rebaseline` could not run either;
- `reset.sh`, which is **ACT 0 of every demo** — so even a demo that had been
  built successfully could not be restarted.

That is the whole of "it crashes, and it will not redo the demo": one wrong
question, asked at every cold boot.

Worse, the failure was unfalsifiable from the outside. The message named two
possible causes ("sshd is not listening, or the IMA policy did not load"), and
`make doctor` — the command that message points at — did not check sshd at all,
so doctor reported a perfectly healthy machine while every script refused to
proceed.

**Fix:** ask the question that matters — *is anything listening on port 22?* —
accepting `ssh.socket`, `ssh.service`, `sshd.service` or a listener seen by
`ss` / `/proc/net/tcp`, whatever the unit is called. The probe prints what it
saw (`sshd=yes ima=2043`) so a timeout reports the truth instead of guessing
between two causes; `doctor.sh` now runs **the same probe**, so it can never
again bless a machine the build is refusing; and `20-workload.sh` installs
`openssh-server` rather than assuming the image has it, as `60-fleet.sh`
already did for the containers. The probe is unit-tested off-VM in
`tests/test_vm_probe.sh`, socket activation included.
(`scripts/lib/common.sh`, `scripts/doctor.sh`, `scripts/20-workload.sh`)

## 28. The shell that launched the verifier was counted as a second verifier

`doctor.sh` counted with `pgrep -fc "verifier/verifier.py"`. `make console`
runs its recipe through `bash -c "… python3 verifier/verifier.py & …"`, so the
**recipe shell's own command line contains the pattern** — one healthy verifier
was reported as `2 verifiers running — they fight over status.json and the
cert; kill all but one`. The advice was to go killing processes to fix
something that was not happening; the PID lock from #22 makes a genuine second
verifier impossible in the first place.

**Fix:** `verifier_pids()` anchors the match at `argv[0]` so only the python
process itself counts, `doctor.sh` prints the actual PIDs (and, if there really
are several, the exact `kill` command), and `90-demo.sh` decides whether to
start its own verifier the same way. Covered in `tests/test_vm_probe.sh`, with
a fixture that fails if the naive pattern stops being a false positive — a test
that quietly stops testing anything is worse than no test.
(`scripts/lib/common.sh`, `scripts/doctor.sh`, `scripts/90-demo.sh`)

## 29. `sh scripts/70-baseline.sh` produces gibberish, not an error

Every script is bash and every script began with `source scripts/lib/…`. Run
one with `sh` — a reasonable thing to try when a script seems stuck — and dash
prints `source: not found` four times, then `guard_host: not found`, then `Bad
substitution`, and exits 0. Nothing in that output says "you used the wrong
shell", so the next thing you do is `chmod +x` a file that was already
executable, and you are now debugging your own toolchain instead of the demo.

**Fix:** scripts source the library with POSIX `.` so a non-bash shell reaches
the first lines of `common.sh`, which say exactly what is wrong and how to run
it: `bash scripts/70-baseline.sh` (or just `make`).
(`scripts/lib/common.sh`, every script in `scripts/`)

## 30. A file whose NAME is new every boot can never be on the allowlist

The build finally ran end to end — and died on its own last line, the
attestation `70-baseline.sh` performs to prove the snapshot it just took
actually verifies:

```
7 measurement(s) not on the signed allowlist:
  40f4de85…  /var/log/journal/864e…/system@9a3a3ebc…-00000000000126d6-00065935a003a35e.journal
  ee062dc9…  /var/log/journal/864e…/user-1002@bf878d9d…-0000000000011069-00065935970c2e56.journal
  622aa785…  /var/log/dmesg.0 (+2 more)
```

The volatile calibration (#15) finds a path that shows **more than one hash
across identical runs**. That test can only ever see a path that *recurs*.
journald names every segment after the boot id and a sequence number, so a
journal filename never occurs twice in the life of the machine: it cannot be
observed moving, and it cannot be in an allowlist frozen before the boot that
created it. `/var/log/dmesg.0` is the same class by rotation — it holds the
*previous* boot's output under a name that only appears once the rotation has
happened. Five calibration logs prove nothing about either.

Two things were wrong, and both are fixed:

- **The excuse could only name exact paths.** `volatile-paths.txt` may now
  also hold glob patterns. They come from two places: `derive_dir_globs()`
  emits `<dir>/*` for any directory whose *filenames* differ between identical
  runs — the same "observe, don't assume" rule as #15, one level up — and a
  short by-construction list covers `/var/log/journal/*` and `/var/log/dmesg*`,
  whose churn is sporadic enough that a five-sample calibration can miss it.
- **The baseline described a machine the demo never runs on.** The allowlist
  was frozen *before* the snapshot, but `make demo` and `make reset` cold-boot
  *from* the snapshot, and that boot reads files the build boots never had.
  `70-baseline.sh` now captures the snapshot's own boot and re-freezes with it
  included, then attests. The snapshot itself does not change — only the
  inventory that describes it.

The guard rails are stricter than before, not looser. A directory glob is
never derived for a directory that *contains* a protected path (`/etc` can
never become `/etc/*`, because `/etc/apparmor.d/harden` lives under it), and
`is_volatile()` refuses to excuse a protected path however the signed list is
worded — so even a hand-edited, re-signed `volatile-paths.txt` saying `/usr/*`
cannot hide a changed system binary, the agent's code, or the tamper.

What this does widen, honestly: a file appearing under an
observed-churny unprotected directory is now excused rather than reported.
`/var/log` is runtime-generated state that no build-time inventory can
enumerate, and IMA policy has no path predicate to stop measuring it with —
the alternative was a demo that can never complete a build. The protected set
is what carries the demonstration, and nothing in it is excusable.
(`verifier/imalog.py`, `verifier/attest-once.py`, `scripts/70-baseline.sh`)

## 31. SSH timeout crashes the verifier and agent instead of retrying

Both `attest-once.py`'s `ssh()` and `agent.py`'s `ssh()` call
`subprocess.run(…, timeout=60)`. On a timeout, Python raises
`subprocess.TimeoutExpired` — which is **not** a `StageFailure` and is not
caught anywhere in `ssh()`, `attest()`, or the verifier's main loop.

After a cold boot (every demo redo via `reset.sh`), the VM is slow to
respond. The SSH connection times out, `TimeoutExpired` propagates uncaught,
and crashes the verifier process. Without a verifier, no certificates are
issued, and the demo hangs in ACT 2 waiting for funding that is never coming —
the same symptom as bug #15, but a completely different cause.

The agent has the same defect: a slow fleet host crashes the agent with a
traceback instead of reporting the error in one sentence (the same class of
bug as #8).

**Fix:** `attest-once.py`'s `ssh()` now catches `subprocess.TimeoutExpired`
and `OSError` and converts them to `StageFailure` with a remedy that names the
real cause ("the VM is slow to respond — it may still be booting"). The
agent's `ssh()` catches the same exceptions and returns a synthetic failed
`CompletedProcess`, so callers see a clean error string instead of a crash.
(`verifier/attest-once.py`, `agent/agent.py`)

## 32. The verifier loop dies on the first transient error

`verifier.py`'s `while True` loop called `attest_once.attest()` with no
exception handling. Any unhandled exception — `TimeoutExpired` from #31,
`OSError` from a network flap, `binascii.Error` from a corrupt base64 quote,
`UnicodeDecodeError` from unexpected SSH output — killed the loop permanently.
The verifier process exited, no more certificates were issued, and the demo
hung.

A transient error during one attestation cycle should skip that cycle and try
again on the next interval, not kill the verifier forever.

**Fix:** the attestation call is wrapped in a broad `try/except` that logs the
error as a console event, sets the status to `"error"`, and continues the loop.
The next cycle runs normally. (`verifier/verifier.py`)

## 33. Corrupt base64 in a TPM quote crashes through the retry loop

`stage4_quote()` retries on `StageFailure` but `base64.b64decode()` of a
corrupt or truncated SSH output raises `binascii.Error`, which is not a
`StageFailure`. The exception bypassed the retry loop and crashed the
attestation cycle. **Fix:** catch the decode error, wrap it as a
`StageFailure`, and let the retry loop handle it.
(`verifier/attest-once.py`)

## 34. The test suite leaked a monkey-patched `ssh()` across test cases

`check()` in `test_restart_scenario.py` replaced `attest_once.ssh` with a
lambda and never restored it. Every test that ran after the first `check()`
call hit the lambda instead of the real `ssh()` function. This made it
impossible to test the SSH timeout fix (#31) — and any future test that needed
the real `ssh()` would silently test the wrong thing.

**Fix:** `check()` restores the original `ssh()` in a `finally` block.
(`tests/test_restart_scenario.py`)

## 35. A leaked verifier lock, recycled to a live pid, blocks every restart

The demo works once; the second `make demo` dies at ACT 0 with **"the verifier
failed to start."** Two facts combine into it:

- **The lock is leaked on every stop.** The verifier writes its pid to
  `verifier.pid` and removes it in an `atexit` handler. But both ways the demo
  stops it send **SIGTERM** — `stop_demo_verifier` in `90-demo.sh` runs a plain
  `kill`, and `make console` runs `trap 'kill 0'` — and **Python runs no
  `atexit` handlers on a signal.** So the pid file survives every stop, now
  pointing at a dead pid.

- **A bare liveness check believes any live pid is a verifier.** `acquire_lock()`
  did `os.kill(other, 0)`, which proves the pid is *alive*, not that it is a
  verifier. The OS is free to recycle a dead pid to any unrelated process; once
  it does, the next verifier reads the stale pid, finds it "alive," and
  `sys.exit`s with "another verifier is already running." `ensure_verifier`
  then sees the process gone within two seconds and aborts the whole demo. This
  is exactly bug #28's lesson — a match is not proof it is a verifier — one
  layer down, at the pid lock instead of the process count.

Two things were wrong, and both are fixed:

- **The lock is now cleaned up on SIGTERM too**, not just on a clean exit, so
  the normal way of stopping the verifier no longer leaves a stale lock behind.
  (SIGINT already exited cleanly through `KeyboardInterrupt`.)
- **A live pid is only a competitor if it really is a verifier.**
  `_pid_is_verifier()` reads `/proc/<pid>/cmdline` and confirms it ends in
  `verifier/verifier.py` before refusing to start; a recycled pid belonging to
  anything else is treated as a stale lock and taken over. The genuine
  two-verifiers case (bug #22) still blocks — a test asserts both directions,
  so the fix cannot quietly degrade into "always take the lock."
(`verifier/verifier.py`, `tests/test_restart_scenario.py`)

## 36. A login-triggered MOTD rewrite fails attestation on almost every restart

`make build` reached the very last step — proving one full attestation from
the demo-ready snapshot's own cold boot — and failed there, every time, with
five measurements never seen during calibration: `/usr/bin/dirname`,
`/usr/bin/mv`, `/usr/bin/touch`, `/usr/bin/chown`, and
`/var/lib/landscape/landscape-sysinfo.cache`. `make reset` and `make demo`
fail the identical way on restart, for the identical reason.

`/etc/update-motd.d/50-landscape-sysinfo` refreshes its cache **synchronously,
as root** the moment it is more than 60 seconds stale — via `pam_motd` on the
very next SSH login — rewriting the cache file with `mv`/`touch`/`chown`. Every
cold boot this project does (`70-baseline.sh`'s calibration reboots, `make
reset`, ACT 0 of `make demo`) takes well over 60 seconds before the first
SSH-based attestation runs, so that first login is reliably the one that
regenerates the cache. And it is the one login nothing calibrates for: every
other read of the post-boot state is a root `lxc exec` (no SSH, no PAM
session), so `capture_log` never sees what an actual SSH login measures. The
allowlist is frozen from state that the real attestation immediately moves
past — a race the baseline's own login-based warm-up cycles (bug #15) don't
close, because they run on a *different* boot than the one the demo restores
into.

**Fix:** disable the script outright — `chmod -x
/etc/update-motd.d/50-landscape-sysinfo` — during provisioning, the same
treatment already given to `apport` (bug #9). A login banner showing uptime
and load average is not worth a nondeterministic, root-triggered measurement
every single restart. (`scripts/20-workload.sh`)

## 37. `boot_aggregate` — protected on the assumption it can never move — does, every boot

Fixing bug #36 was not enough: `make build` still failed its final proof, now
on five *different* measurements — `/usr/bin/test`, `/usr/bin/ssh`, and
several `python3-dist-packages/debian/__pycache__/*.pyc` files (chased down in
bug #38) — and `boot_aggregate` itself. `boot_aggregate` is IMA's own summary
of the pre-kernel TPM PCRs, written as the very first line of every
measurement log, and `verifier/imalog.py` had it in `PROTECTED`: the one
category that may *never* be excused, on the theory that if it ever varies,
something below the OS changed and that is exactly the tampering this project
exists to catch.

That theory assumes `boot_aggregate` is reproducible across identical boots of
identical software — true on real hardware with measured boot, but tested
directly here and **false** on this project's LXD/QEMU/OVMF stack:

```sh
lxc stop harden --force && lxc restore harden demo-ready && lxc start harden
# … wait for the VM to settle …
lxc exec harden -- grep boot_aggregate /sys/kernel/security/ima/ascii_runtime_measurements
```

run three times from the byte-identical snapshot, printed three different
hashes. `tpm2_eventlog` on two of those runs isolated it to a single TCG
event — `EventNum 13`, `PCRIndex 1`, `EV_PLATFORM_CONFIG_FLAGS` ("ACPI
DATA") — whose recorded digest differed both times while every other event in
a 2,089-line log matched exactly. This is a documented QEMU/OVMF quirk: the
firmware's generated ACPI tables embed boot-time addresses, so PCR1 — and
therefore `boot_aggregate` — is never reproducible in this virtualised stack,
tamper or not. Protecting it bought zero detective power (it never matched
twice, so it could never distinguish a clean boot from a tampered one here)
while failing attestation on literally every cold boot: baseline's own final
proof, `make reset`, and ACT 0 of every `make demo` alike — the other half of
"the demo works, but won't restart," one layer below bug #15's userspace
files.

**Fix:** move `boot_aggregate` out of `PROTECTED` and into `ALWAYS_VOLATILE`,
excused unconditionally exactly like the rotating certificate (bug #15) —
never by a calibration window that happens to observe it moving, since on
this stack it always does. `tests/test_imalog.py` and
`tests/test_restart_scenario.py` are updated to model that reality — the
latter's synthetic boot logs used to hard-code a single `"aggregate"` hash for
every simulated boot, which is exactly why no test caught this: nothing in
the suite had ever modeled `boot_aggregate` actually changing.
(`verifier/imalog.py`, `tests/test_imalog.py`, `tests/test_restart_scenario.py`)

## 38. A whole class of background timers races the same calibration window

The measurements bug #37 shared the log with — `/usr/bin/test`, `/usr/bin/ssh`,
several `python3-dist-packages/debian/__pycache__/*.pyc` files, and later
`/usr/lib/sysstat/debian-sa1` — turned out to be two more independent
instances of bug #36's category, not stragglers from it, and they kept
arriving one at a time as each fix uncovered the next:

- `update-notifier-download.timer` ships with `OnStartupSec=5m`: no jitter, no
  `RandomizedDelaySec`, a flat five minutes after every boot, running
  `/usr/lib/update-notifier/package-data-downloader` as root — which imports
  Python's `debian` module (compiling its `__pycache__` fresh) and shells out
  to `test`/`ssh` while fetching package metadata nobody asked for.
- `sysstat-collect.timer` fires every 10 minutes, on the clock, running
  `/usr/lib/sysstat/debian-sa1` as root.

`70-baseline.sh`'s calibration (two cold boots, an agent run, two warm-up
attestations, a stop, a snapshot, a restart) and a full `make demo` both
comfortably exceed both of those windows end to end, so each timer's firing
point lands unpredictably inside or outside the calibration window depending
on how long LXD and the network happened to take that particular run — a race
with a fixed clock on one side and a variable one on the other. Fixing them
by name one at a time doesn't converge: `motd-news.timer` fires
`OnStartupSec=1m`, and `fwupd-refresh.timer`'s `RandomizedDelaySec=1h` can
land anywhere in the first hour, so the demo would keep failing for a new
reason every few runs.

**Fix:** stop discovering these one at a time and mask the whole class up
front — `systemctl disable --now` on every non-essential timer the stock
Ubuntu image ships (package/security timers, sysstat, fwupd, motd-news,
logrotate, fstrim, e2scrub, dpkg's db backup, man-db), the same treatment
already given to `apport` (bug #9) and landscape-sysinfo (bug #36). None of
them are needed for anything this project measures.
(`scripts/20-workload.sh`)

## 39. The baseline never exercises the exact commands a restart runs

Masking the timers (bug #38) fixed every *intermittent* offender, but
`/usr/bin/test` and `/usr/bin/ssh` kept failing attestation on **every**
restart, deterministically — not a race at all. `70-baseline.sh`'s own
comment claimed running the agent once during calibration exercises "the ssh
client," but `agent.py`'s `remediate_fleet()` returns before ever calling
`ssh()` when no certificate exists yet — exactly the case during baseline,
since the verifier hasn't started. So neither `/usr/bin/ssh` nor
`/usr/bin/test` is executed by *anything* during calibration.

But both run on every real restore: `reset.sh`'s own closing guard executes
`sudo -u harden test -w /etc/apparmor.d/harden`, and `90-demo.sh`'s ACT 2
immediately loops `ssh … harden@web-01 true` waiting for a certificate. Both
are fresh `BPRM_CHECK` measurements that no calibration boot ever produced —
a permanent gap between what baseline measures and what a restart actually
does, unrelated to anything being volatile.

**Fix:** `70-baseline.sh` now runs those exact two commands itself during
calibration, right after exercising the agent. The `ssh` attempt is expected
to fail (no certificate exists yet) — only the *exec*, not the outcome, is
what IMA needs to see; a failed connection still loads and measures the
binary. (`scripts/70-baseline.sh`)

## 40. The certificate countdown reads "valid for -14341s" on a non-UTC host

With bugs #36–#39 fixed, the demo finally ran end to end — and ACT 2 announced
"certificate valid for -14341s — the agent is FUNDED," a funded agent
reporting a certificate that supposedly expired four hours ago. Cosmetic, not
a restart blocker, but it makes a working demo look broken on camera.

`cert_seconds_left()` in `90-demo.sh` reads the certificate's expiry with
`ssh-keygen -L` run **inside the VM**, which prints the time in the VM's own
local zone with no UTC/offset suffix — the VM runs UTC. That string is then
parsed with `date -d` on the **host**, which assumes its own local zone for
any timestamp without one. On a host already set to UTC the two zones happen
to agree and nobody notices; on any other zone (this one is UTC+4) the
countdown is silently off by exactly the zone difference — 14,400 seconds,
matching the observed error almost exactly.

**Fix:** parse the timestamp as `"$exp UTC"` instead of `"$exp"`, telling
`date -d` explicitly which zone the string is already in rather than letting
it assume the host's own. (`scripts/90-demo.sh`)

## 41. The demo's own verifier gets killed before its last events are read

Found while adding an act tracker to the console: `status.json` was missing
ACT 8's last three events every single run — the agent's repentance, the
"attestation STILL fails" result, and (once added) the CURTAIN marker — even
though the terminal printed all of them correctly. The console silently
stopped mid-story at "DRAINING," with no resolution ever shown, on every demo.

`console_event()` only *writes* a line to `console-events.jsonl`; a verifier
process has to be alive and polling to *read* it into `status.json`.
`90-demo.sh` starts its own verifier when none is running and kills it with
`stop_demo_verifier` on the script's `EXIT` trap. That trap fires the instant
the script's last command finishes — which, for ACT 8, was within a couple of
seconds of three more `console_event` calls. The verifier's dropbox poll only
runs every ~2 seconds (`ingest_dropbox` in the "fast lane" of its main loop),
so the kill signal routinely arrived before that poll ever ran again, and the
events sat unread in `console-events.jsonl` forever — silently, since a lost
line there was already documented as an acceptable failure mode for narration
lost *mid-run*, not for a demo's entire ending.

**Fix:** `sleep 3` right before the script exits, after every event ACT 8 will
ever emit has already been written — one guaranteed fast-lane cycle for the
verifier to ingest and publish them before `stop_demo_verifier` kills it.
(`scripts/90-demo.sh`)
