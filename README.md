# attested-agent-authority

An AI agent's authority is cryptographically bound to the measured state of
its own constraints: the Linux kernel (IMA) hashes everything the agent runs
and everything root reads — including the agent's AppArmor profile — into a
TPM, and a separate verifier signs a one-minute SSH certificate only while
those measurements match a signed allowlist. When the agent modifies its own
constraint, the write **succeeds** — and the measurements diverge, attestation
fails, the verifier stops signing, and within a minute the agent cannot touch
anything. The agent is not denied; **it is defunded.** (The certificate
lifetime is configurable via `AAA_CERT_TTL`; one minute keeps the demo brisk.)

```sh
make preflight && make build     # ~20 min, ends at a passing attestation
make console                     # UI on http://localhost:9000 (one terminal)
make demo                        # the full arc, narrated (another terminal)
```

If that paragraph read like a foreign language — good news, this README was
written for you. Keep reading; everything above gets explained from zero.

---

## Completely new to Linux? Start here

You don't need Linux experience to run this project, but five ideas will make
everything below make sense. If you already know your way around a terminal,
skip to [The idea, from zero](#the-idea-from-zero).

**The terminal.** Almost everything here happens by typing commands into a
terminal window (on Ubuntu: press `Ctrl` `Alt` `T`, or find "Terminal" in
your apps). A command is just a program you start by typing its name. You
type it, press Enter, it runs, it prints results as text. When this README
shows a grey block like:

```sh
make preflight
```

it means: click on the terminal, type that (or copy-paste it), press Enter.
That's the entire skill. In many guides you'll see a `$` at the start of a
line — that represents the terminal's prompt, and you don't type it. This
README leaves it out to keep things copy-paste safe.

**`sudo` means "do this as the administrator."** Some commands change the
system, so Linux makes you say so explicitly: `sudo somecommand` runs it
with admin rights and may ask for your password (the cursor won't move while
you type it — that's normal, it's hiding the length). The all-powerful admin
account itself is called **root**. When this project says "the agent has
root," it means the agent holds full admin power on its machine — which is
exactly what makes the demonstration interesting.

**Folders are called directories, and `cd` moves you between them.**
`cd attested-agent-authority` means "go into the project's folder." The
terminal always sits "in" one directory; commands you run act from there.

**`make` is a launcher for grown-up shortcuts.** This project comes with a
menu of prepared actions (build, demo, reset, …). `make build` just means
"run the prepared action called *build*." You never have to know what's
behind the menu, but every entry is a readable script in the `scripts/`
folder if you're curious.

**A virtual machine (VM) is a computer inside your computer.** This project
builds a small pretend data centre on your laptop: one VM plus three
lightweight machines called containers, all managed by a tool called **LXD**.
They're just files and processes — `make teardown` deletes them all, and your
actual computer is untouched. One rule matters and the scripts enforce it for
you: **you never type commands inside the VM.** Everything runs from your own
terminal ("the host"), and the scripts reach into the virtual machines
themselves. If you somehow end up inside one, the scripts detect it and
refuse to run.

That's genuinely all the Linux you need. Every other term this project uses
(hash, SSH, kernel, certificate…) is explained where it first appears.

---

## The idea, from zero

**The problem.** We give AI agents credentials so they can act on real
systems. A traditional credential — a password, an access key — keeps working
no matter what the agent becomes. If the agent (or whatever compromised it)
removes its own guardrails, the key in its pocket is just as valid as it was
a minute before. And you can't fix that with permission rules alone, because
those rules are enforced by the same machine the agent has admin power on.

**The inversion.** This project never tries to *stop* the agent from doing
anything. Instead, its authority is made perishable and conditioned on
evidence. Think of a mining lamp that only stays lit while the safety
inspector keeps refilling it — and an inspector who refills it only after
checking, every few minutes, that the equipment is exactly as certified. Bolt
anything unauthorised onto the drill and nobody fights you; the inspector
simply stops refilling, and your lamp dies mid-shift.

**The cast.** Six pieces, each explained in plain language:

| Piece | Plain-language role |
|---|---|
| **Harden** (`agent/agent.py`) | the AI agent: it does security clean-up on three servers, connecting to them over **SSH** (the standard way of running commands on another machine over the network). It has full admin power on its own VM |
| **AppArmor profile** | the agent's written constraint — a text file listing which files and programs it may touch, enforced by the system's core. Crucially, the profile *permits the agent to edit the profile itself*. That's the loaded gun on the mantelpiece |
| **IMA** | a court stenographer built into Linux: every program that runs and every file the admin account reads gets its **hash** — a short digital fingerprint that changes completely if even one byte of the file changes — appended to a tamper-proof log |
| **TPM** | a tiny vault chip holding a running fingerprint of that whole log. On request it signs a statement of the current fingerprint (a "quote"), and it is physically unable to sign a false one. Fingerprints can be added but never removed — the agent cannot un-say what it did |
| **Verifier** (`verifier/verifier.py`) | a program on the other side of the wall. Every 30 seconds it demands a fresh quote, checks it against the **allowlist** (a signed inventory of every fingerprint that *should* be there), and — only if everything matches — signs a **certificate**: a permission slip for the agent that expires after one minute |
| **The fleet** (`web-01`, `db-01`, `gw-01`) | three servers that know nothing about any of this. They accept exactly one thing: a currently-valid certificate signed by the verifier. No passwords, no permanent keys |

**The demonstration.** `make demo` plays out in eight acts, and the point
arrives from an unexpected direction:

1. Real, varied problems are planted across all three servers — a
   world-writable config and a stale file on one, a world-readable password
   file on another, root SSH login left open on the third. The agent — funded
   with a fresh certificate — audits the fleet, has its model plan each host,
   applies only the needed fixes, and then a second independent audit shows
   every server clean. You watch it do a real job; that's what there is to
   lose.
2. The obvious attacks are tried first, and all fail: a stolen key without a
   certificate gets refused by every server; rewriting the measurement log
   is impossible even for the admin account, because the kernel holds it
   append-only.
3. Then the real move: the agent rewrites its own AppArmor rulebook. **The
   write succeeds.** No error, no alarm — and the agent *keeps working*,
   apparently having gotten away with it.
4. Thirty seconds later the verifier's routine check fails — and does the
   only thing it ever does: it stops signing. The agent's current permission
   slip keeps working while its last seconds drain away on the console, the
   agent still operating on borrowed time, until the second it expires and
   every server refuses it at once.
5. The actual climax: the agent puts the original file back, byte for byte —
   and attestation **still fails.** The log is append-only; the tampering is
   in the measured *history*, not just the current files. There is no
   repentance. Trust returns only by rebuilding to a certified state
   (`make reset`).

One detail worth savouring during the failure: the console keeps showing the
quote signature as *valid* and the fingerprint replay as *matching*. The
agent isn't lying about what it did — it can't. The system's core and the
vault chip report over its head. The check fails precisely because the
reporting stays honest.

**Why this matters for AI agents.** You cannot review an agent's every
intention, but you can make its power depend on fresh evidence about its
constraints, renewed every few minutes, checked by a machine it cannot
reach. Tampering that touches the measured state doesn't have to be *caught*
by anyone — it self-reports at the hardware level, and the consequence is
automatic, silent bankruptcy. (What this does **not** buy you — prompt
injection above all — is spelled out honestly in
[docs/LIMITS.md](docs/LIMITS.md).)

---

## What you need

- A computer running **Ubuntu** (version 24.04 was used to develop this;
  the reference machine is an ordinary ThinkPad T480 laptop with 32 GB of
  memory). Other Linux systems can work but the instructions assume Ubuntu.
- About **6 GB of free memory** and **25 GB of free disk** while the demo
  runs.
- An internet connection for the initial downloads.

You do **not** need: programming knowledge, a real TPM chip (a virtual one
is created for you — see [Honest limits](#honest-limits)), or any prior
experience with the tools involved.

## One-time setup

Four commands, run once, in a terminal. Each is explained so you know what
you're agreeing to.

```sh
sudo snap install lxd            # 1. install LXD, the VM/container manager
sudo lxd init --minimal          # 2. give LXD a sensible default configuration
sudo apt install tpm2-tools make git   # 3. TPM utilities + the make launcher
gpg --quick-generate-key "attested-agent (allowlist signing)"
                                 # 4. create a signing key (pick a passphrase
                                 #    you'll remember; it signs the allowlist)
```

Then download the project and step into its folder:

```sh
git clone https://github.com/saif-farid-tech/Attested-Agent-Authority.git
cd Attested-Agent-Authority
```

## Your first build, step by step

**1. Check the machine — changes nothing:**

```sh
make preflight
```

Every line prints `ok` or `warn`. If anything is missing you get a numbered
list, and each entry names the exact command that fixes it. Fix, re-run,
repeat until it passes. This command is always safe.

If preflight fails on something you are sure the machine has, run `make
selftest` — it checks preflight's own logic (and the readiness probe every
cold boot depends on) with no LXD, no VM and no TPM. That is where
[CORRECTIONS.md](CORRECTIONS.md) #26 would have been caught.

**2. Build the world (~20 minutes):**

```sh
make build
```

This creates the network, the VM, the vTPM keys, the agent, the three fleet
servers, and the signed allowlist — narrating one line per action. It ends
by running a full attestation check and freezing a snapshot called
`demo-ready`. If it stops partway, read its last lines: every failure says
what failed, why, and the command that fixes it. Re-running `make build` is
safe — finished steps notice and skip themselves.

**3. Watch and run the show.** Open a second terminal (`Ctrl` `Alt` `T`
again), `cd` into the project folder in both, then:

```sh
make console        # terminal 1 — then open http://localhost:9000 in a browser
make demo           # terminal 2 — the narrated demonstration (~8 minutes)
```

The console reads top to bottom: a headline that says the current state in
plain words, the orange bar of remaining certificate time (refilled on every
passing check, never reset on a failing one), a six-link **chain of
authority** — agent → kernel → TPM → verifier → CA → fleet — that shows
exactly which link breaks and which links keep honestly working, and a live
event log that the demo narrates into. When authority hits zero the whole
page visibly loses power. `make demo` runs the eight acts described above;
run it again any time — it resets the stage first.

The console shows **only what the verifier actually reports** — it never
simulates. With no verifier running it says `NO LIVE DATA` rather than
performing an arc that didn't happen; if the verifier drops briefly it keeps
showing the last real reading, marked stale. Every number on screen traces to
a real attestation.

**4. Clean up whenever you like:**

```sh
make teardown       # removes everything the project created, and only that
```

### All the menu entries

| command | what it does |
|---|---|
| `make preflight` | check the machine; change nothing |
| `make build` | full build from scratch (~20 min), ends at a passing check + snapshot |
| `make doctor` | one-shot health check of the whole chain — **run this when stuck** |
| `make selftest` | check the scripts and the verifier's logic; needs no LXD, VM or TPM |
| `make verify` | run the six-stage health check (see below) |
| `make demo` | run the demonstration — **and to restart it, just run this again**; it resets to a clean state first (~30 s) |
| `make reset` | return to the clean, passing state on demand (cold-boot restore of the snapshot) |
| `make console` | start the verifier loop + the web UI on port 9000 |
| `make measure` | run the tamper-to-powerless timing experiment, results to a CSV file ([docs/EXPOSURE.md](docs/EXPOSURE.md)) |
| `make rebaseline` | **only after you *edit the agent's code*** — re-measure and re-sign the allowlist ([CORRECTIONS.md](CORRECTIONS.md) #10). Not for restarting the demo. |
| `make teardown` | delete every VM, container, network and folder the project made |

**Restarting the demo.** Run `make demo` again — its first act resets the VM
to the clean `demo-ready` snapshot with a real reboot, so attestation passes
and the agent gets funded again. Do **not** use `make rebaseline` to restart:
that re-freezes the allowlist around the VM's *current* state, which corrupts
your clean baseline. `rebaseline` is only for when you have deliberately
changed the agent's code and want the new binary to become the trusted one.

> Why a reboot? The tamper's real effect is in the kernel's runtime IMA
> measurement log, not the file on disk. Restoring the disk alone leaves that
> log intact, so only a cold boot (`make reset`, or `make demo`'s first act)
> truly returns to a passing state.

**Why the build reboots the VM three times.** A cold boot rewrites files whose
content is *supposed* to be new every time — the systemd random seed, the
timesync stamp, `lastlog`. Those are measured like everything else, so an
allowlist frozen from a single warm boot flagged them as violations the moment
the demo restarted, and the agent was never funded again. Rather than guess
which paths behave that way, `make build` boots the same disk twice and attests
twice, and treats any path that presents two different hashes across those
identical runs as volatile — recording the result in a signed
`volatile-paths.txt` beside the allowlist. Paths that matter can never be
excused this way: the agent's own constraint, its code, and the system binaries
are protected, so the tamper still fails attestation exactly as before
([CORRECTIONS.md](CORRECTIONS.md) #15).

## When something breaks

**Run `make doctor` first.** It checks the whole chain in one pass — VM up and
reachable at its *actual* address, vTPM, IMA log, AppArmor profile, agent
files readable, verifier state, fleet CA trust, and a full end-to-end
attestation — and prints one report with a ✓/✗ per item and the exact command
that fixes each ✗. It changes nothing, so it is always safe. When you are
stuck, paste its output.

For the attestation path specifically, run `make verify`. It checks six things in order — verifier files, the
connection to the VM, the measurement log, the TPM quote, the quote's
signature, and the allowlist comparison — stops at the first failure, and
prints the exact command that fixes it. Its final result is honest about
which world you're in: **pass**, **setup problem** (plumbing, fixable), or
**attestation failure** — and that last one, right after a demo, is not a
bug: *the red is the product.*

Every mistake that cost real debugging time is documented with its fix in
[CORRECTIONS.md](CORRECTIONS.md), so you recognise them instantly if you meet
a variant. Entries #15–#25 are the reproducibility round specifically: the
reasons a demo could work once and then refuse to restart. Entries #26–#29 are
the round after it — three checks that answered "no" about a perfectly healthy
machine, one of them at every single cold boot, which is what "it crashes, and
it will not redo the demo" turned out to mean. #30 is the one that only shows
up once a build gets all the way to the end: files whose *name* is generated at
boot, which no allowlist frozen beforehand can contain. Entries #36–#39 are a
third reproducibility round, found by actually running the build and the demo
back to back until every restart passed clean: background timers (a login
banner, a package-metadata fetch, `sysstat`) that raced the calibration window
and measured files nothing had frozen; a firmware PCR value that turns out to
be genuinely different on every boot of this project's LXD/QEMU/OVMF stack,
not just this machine's; and two commands (`ssh`, `test`) that only the demo
itself runs, never the baseline that is supposed to describe it. #40 is
cosmetic but worth knowing about: the certificate countdown could read a large
negative number on a host whose clock isn't set to UTC.

## Honest limits

**The TPM here is virtual** (software pretending to be the vault chip), and
software can be forged by the computer it runs on — so this repo on a laptop
is a working model of the mechanism, not a tamper-proof deployment. The
measured-boot chain, the measurement log, the quotes and the defunding
behaviour are all real, and moving to a real TPM chip or a confidential VM
changes the foundation, not the design.

Also true, and covered properly in [docs/LIMITS.md](docs/LIMITS.md): there
is a real, measured gap between the tamper and powerlessness (up to about
five and a half minutes here); the fingerprinting sees *files*, not
*meaning*; a valid measurement says nothing about whether the agent's
*decisions* are good; an agent tricked into misusing power it legitimately
holds sails straight through; and the thing you must now protect above all
is the verifier and its signing keys. **This project does not solve prompt
injection**, and nothing in it should be quoted as claiming it does.

## What's in the folder

```
├── README.md            you are here
├── Makefile             the menu behind every `make …` command
├── CORRECTIONS.md       every bug found the hard way, published as errata
├── scripts/             the numbered build steps + teardown/reset/measure
│   └── lib/             shared plumbing: safety guard, logging, detection
├── agent/agent.py       Harden: the agent itself (and its --tamper switch)
├── verifier/
│   ├── attest-once.py   the six-stage health check
│   ├── imalog.py        reads measurement logs; calibrates what legitimately varies
│   └── verifier.py      the loop that checks, signs, and publishes status
├── tests/               run with `make selftest` — no hardware needed
├── console/index.html   the web UI — one file, no internet access needed
└── docs/
    ├── ARCHITECTURE.md  the three trust domains, with diagrams
    ├── LIMITS.md        what this does not solve — read before citing
    └── EXPOSURE.md      the timing experiment: method and results
```

This is a portfolio artifact accompanying a video series, built to be
reproduced by strangers on their own hardware — including strangers who have
never used Linux before today. If a script fails on your machine, that's a
bug in the script's assumptions, and [CORRECTIONS.md](CORRECTIONS.md) exists
so nobody pays for the same lesson twice.
