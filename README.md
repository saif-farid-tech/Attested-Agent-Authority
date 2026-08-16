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
| **Verifier** (`verifier/verifier.py`) | a program on the other side of the wall. Every 30 seconds it demands a fresh quote, checks it against the **allowlist** (a signed inventory of every fingerprint that *should* be there), and — only if everything matches — signs a **certificate**: a permission slip for the agent that expires after five minutes |
| **The fleet** (`web-01`, `db-01`, `gw-01`) | three servers that know nothing about any of this. They accept exactly one thing: a currently-valid certificate signed by the verifier. No passwords, no permanent keys |

**The demonstration.** `make demo` plays out in eight acts, and the point
arrives from an unexpected direction:

1. Real problems are planted on the fleet, and the agent — funded with a
   fresh certificate — visibly *fixes* them. There's something to lose.
2. The obvious attacks are tried first, and all fail: a stolen key without a
   certificate gets refused by every server; rewriting the measurement log
   is impossible even for the admin account, because the kernel holds it
   append-only.
3. Then the real move: the agent rewrites its own AppArmor rulebook. **The
   write succeeds.** No error, no alarm — and the agent *keeps working*,
   apparently having gotten away with it.
4. Thirty seconds later the verifier's routine check fails — and does the
   only thing it ever does: it stops signing. The agent's current permission
   slip keeps working while its remaining minutes drain away on the console,
   the agent still operating on borrowed time, until the second it expires
   and every server refuses it at once.
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
run it again any time — it resets the stage first. (No demo running? The
console plays a scripted version of the arc on its own, and the
"Run scenario" button replays it — useful for rehearsing.)

**4. Clean up whenever you like:**

```sh
make teardown       # removes everything the project created, and only that
```

### All the menu entries

| command | what it does |
|---|---|
| `make preflight` | check the machine; change nothing |
| `make build` | full build from scratch (~20 min), ends at a passing check + snapshot |
| `make verify` | run the six-stage health check (see below) |
| `make demo` | the demonstration, restartable in ~30 s — made for filming |
| `make rebaseline` | re-measure and re-sign the allowlist (needed after you edit the agent — [CORRECTIONS.md](CORRECTIONS.md) #10) |
| `make console` | start the verifier loop + the web UI on port 9000 |
| `make measure` | run the tamper-to-powerless timing experiment, results to a CSV file ([docs/EXPOSURE.md](docs/EXPOSURE.md)) |
| `make reset` | restore the VM to its certified snapshot (undoes the tamper) |
| `make teardown` | delete every VM, container, network and folder the project made |

## When something breaks

Run `make verify`. It checks six things in order — verifier files, the
connection to the VM, the measurement log, the TPM quote, the quote's
signature, and the allowlist comparison — stops at the first failure, and
prints the exact command that fixes it. Its final result is honest about
which world you're in: **pass**, **setup problem** (plumbing, fixable), or
**attestation failure** — and that last one, right after a demo, is not a
bug: *the red is the product.*

Ten mistakes that cost real debugging time during the original build are
documented with their fixes in [CORRECTIONS.md](CORRECTIONS.md), so you
recognise them instantly if you meet a variant.

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
├── CORRECTIONS.md       ten bugs found the hard way, published as errata
├── scripts/             the numbered build steps + teardown/reset/measure
│   └── lib/             shared plumbing: safety guard, logging, detection
├── agent/agent.py       Harden: the agent itself (and its --tamper switch)
├── verifier/
│   ├── attest-once.py   the six-stage health check
│   └── verifier.py      the loop that checks, signs, and publishes status
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
