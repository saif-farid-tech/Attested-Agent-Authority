# attested-agent-authority

An AI agent's authority is cryptographically bound to the measured state of
its own constraints: the Linux kernel (IMA) hashes everything the agent runs
and everything root reads — including the agent's AppArmor profile — into a
TPM, and a separate verifier signs a five-minute SSH certificate only while
those measurements match a signed allowlist. When the agent modifies its own
constraint, the write **succeeds** — and the measurements diverge, attestation
fails, the verifier stops signing, and within five minutes the agent cannot
touch anything. The agent is not denied; **it is defunded.**

```sh
make preflight && make build     # ~20 min, ends at a passing attestation
make console                     # UI on http://localhost:9000 (one terminal)
make demo                        # the full arc, narrated (another terminal)
```

---

## The idea, from zero

Skip this section if the three sentences above were enough.

**The problem.** We give agents credentials so they can act. A traditional
credential keeps working no matter what the agent becomes: if the agent (or
whatever compromised it) removes its own guardrails, the SSH key in its
pocket is just as valid as it was a minute before. Permission systems answer
*"may you do this?"* — but they are enforced by the same machine the agent
has root on.

**The inversion.** This project never tries to *stop* the agent from doing
anything. Instead, its authority is made perishable and conditioned on
evidence. Think of a mining lamp that only stays lit while the safety
inspector keeps refilling it — and an inspector who refills it only after
checking, every few minutes, that the equipment is exactly as certified. Bolt
anything onto the drill and nobody fights you; the inspector simply stops
refilling, and your lamp dies mid-shift.

**The cast:**

| Piece | Plain-language role |
|---|---|
| **Harden** (`agent/agent.py`) | the agent: does security clean-up on three servers over SSH; has root on its own VM |
| **AppArmor profile** | the agent's written constraint — which files and programs it may touch. The kernel enforces it; crucially, the profile *permits the agent to edit the profile itself* |
| **IMA** (kernel Integrity Measurement Architecture) | a court stenographer inside the kernel: every program executed and every file root reads gets its SHA-256 hash appended to a log the agent cannot rewrite |
| **TPM** (Trusted Platform Module) | a tiny vault chip holding a running fingerprint (PCR 10) of that log. It will *sign a statement* of the current fingerprint — a "quote" — and it is physically unable to sign a false one. Hashes can be added but never removed: the agent cannot un-say what it did |
| **Verifier** (`verifier/verifier.py`) | a separate machine's process that, every 30 s, demands a fresh quote, checks it against the **allowlist** (the signed inventory of every hash that *should* be there), and — only on a pass — signs a five-minute SSH certificate for the agent |
| **The fleet** (`web-01`, `db-01`, `gw-01`) | three servers that know nothing about any of this. Their sshd accepts *only* certificates signed by the verifier's CA (`TrustedUserCAKeys`); no passwords, no plain keys |

**The demonstration.** `make demo` restores a known-good snapshot, waits for
the agent to be funded, shows it working on the fleet — then has it append a
line to its own AppArmor profile. Nothing objects; the write succeeds. But
the next time root reads that file, IMA logs a new hash, the TPM fingerprint
diverges from the allowlist, and the verifier's next check fails. It doesn't
raise an alarm or kill a process. It just *stops signing*. The certificate
already in the agent's pocket keeps working for its remaining minutes — you
watch it drain on the console — and then every server refuses the agent, and
there is no way for it to earn a new certificate short of returning to the
measured state (`make reset`).

One detail worth savouring on the console: during the failure, the quote
signature is still *valid* and the PCR replay still *matches*. The agent
isn't lying about what it did — it can't. The kernel and the TPM report over
its head. Attestation fails precisely because the reporting stays honest.

**Why this is interesting for AI agents.** You cannot review an agent's every
intention, but you can make its power depend on evidence about its
constraints, renewed every few minutes, checked by a machine it cannot reach.
Misbehaviour that touches the measured state doesn't have to be caught by
anyone — it *self-reports at the hardware level* and the consequence is
automatic, silent bankruptcy. (What this does **not** buy you — prompt
injection above all — is spelled out in [docs/LIMITS.md](docs/LIMITS.md).)

---

## What actually gets built

Everything lives in LXD on one machine; every command runs **on the host**.
Scripts reach into instances with `lxc exec` — you never open a shell inside
a VM, and `scripts/lib/common.sh` refuses to run if you somehow are in one.

- **VM `harden`** — Ubuntu 24.04 with secure boot and a virtual TPM; IMA
  measuring under a custom policy; the AppArmor-confined agent; users
  `harden` (the agent) and `attest` (the verifier's login).
- **Containers `web-01` `db-01` `gw-01`** — the fleet, on bridge `fleet0`,
  trusting only the CA.
- **On the host** — `~/attested-agent/` holds the verifier's state: the AK
  public key (the TPM's identity, exported once), the GPG-signed allowlist,
  the SSH CA, and the exposure CSV. `verifier/verifier.py` runs here, standing
  in for the immutable Ubuntu Core box of the full design
  ([docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
- **`console/index.html`** — a single-file UI: the certificate-lifetime
  "filament" draining in real time, the three trust domains, and the event
  log. When authority hits zero the whole page visibly loses power. It also
  plays a scripted arc offline ("Run scenario"), so you can rehearse without
  the stack.

## Requirements

Ubuntu host (24.04 tested; the reference build is a ThinkPad T480, 32 GB),
with: LXD ≥ 4.4 initialised, `/dev/kvm`, `tpm2-tools`, a GPG secret key for
signing the allowlist, and `ssh-keygen`. Roughly 6 GB free RAM and 25 GB
disk. `make preflight` checks all of it, changes nothing, and prints a
numbered fix list. Everything is open source; the verifier is scratch-built
(~500 lines) so there is no attestation vendor to take on faith.

## Using it

| target | what it does |
|---|---|
| `make preflight` | environment checks only |
| `make build` | full build from scratch (~20 min), ends at a passing verify + `demo-ready` snapshot |
| `make verify` | the six-stage diagnostic (below) |
| `make demo` | instant replay from snapshot (~30 s to the tamper) — for filming and re-runs |
| `make rebaseline` | regenerate + re-sign the allowlist (required after editing the agent — see [CORRECTIONS.md](CORRECTIONS.md) #10) |
| `make console` | verifier loop + UI on `:9000` |
| `make measure` | N tamper-to-powerless runs, CSV out ([docs/EXPOSURE.md](docs/EXPOSURE.md)) |
| `make reset` | restore the snapshot (undoes the tamper) |
| `make teardown` | remove every instance, network and directory the project created |

**When something breaks**, run `make verify`. It walks six stages — verifier
files, SSH to the workload, IMA log, TPM quote, quote signature, allowlist
comparison — stops at the first failure, and names the exact command that
fixes it. Exit codes are honest: `0` pass, `1` setup problem, `2` attestation
failure. **A `2` is the system working** — if you just ran the demo, that
red is the product. Ten pre-paid mistakes (why your Python glob doesn't
match, why nothing on the allowlist ever matches, why `@cert-authority` is
the wrong knob…) are documented in [CORRECTIONS.md](CORRECTIONS.md).

## Honest limits

**A software TPM is not a root of trust.** The vTPM here is swtpm; the host
can forge it. Measured boot, IMA, the quotes and the revocation chain are
all real and carry to production unchanged — a discrete TPM or confidential
VM is a substrate swap, not a design change — but this repo on a laptop is a
working model of the mechanism, not a tamper-proof deployment.

Also true, and covered in [docs/LIMITS.md](docs/LIMITS.md): the exposure
window (tamper → powerless) is real, bounded, and measured rather than
hidden; IMA measures files, not semantics; attestation says nothing about
model *behaviour*; the confused-deputy problem is untouched because authority
binds to state, not intent; and the trust boundary has moved to the signing
pipeline, not vanished. **This project does not solve prompt injection**, and
no claim here should be read as saying it does.

## Repository layout

```
├── README.md            you are here
├── Makefile             the only interface most users need
├── CORRECTIONS.md       ten bugs found the hard way, published as errata
├── scripts/             numbered host-side build steps + teardown/reset/measure
│   └── lib/             common.sh (guard, traps, logging) · detect.sh (never assume)
├── agent/agent.py       Harden: fleet remediation, model-planned, cert-powered
├── verifier/
│   ├── attest-once.py   the six-stage diagnostic (exit 0/1/2)
│   └── verifier.py      attestation loop, cert issuance, status.json
├── console/index.html   self-contained UI (no frameworks, no external requests)
└── docs/
    ├── ARCHITECTURE.md  trust domains, sequence diagrams, why each component
    ├── LIMITS.md        what this does not solve — read before citing
    └── EXPOSURE.md      measurement methodology and results
```

This is a portfolio artifact accompanying a video series, built to be
reproduced by strangers on their own hardware. If a script fails on yours,
that's a bug in the script's assumptions — the contract in
[CORRECTIONS.md](CORRECTIONS.md) is that nobody pays for the same lesson
twice.
