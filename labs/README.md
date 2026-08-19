# Linux Security Labs: From Zero to Attested Agent Authority

These thirteen labs teach you Linux — from opening a terminal for the first
time to building a system where an AI agent's authority is cryptographically
bound to the measured state of its own constraints.

Every lab teaches one concept by having you do it on your own machine. There
are no hypothetical examples: every command produces real, verifiable output,
and every concept is load-bearing in the final system. By the end you will
understand — from direct experience — how to build a system where an agent
that modifies its own constraint automatically loses all authority, not
because someone catches it, but because the hardware reports the truth and
the evidence stops passing.

## The learning path

The labs are ordered. Each one builds on the skills and concepts from the
ones before it. Skipping ahead will leave you missing vocabulary and tools
that later labs assume you have.

```
 Module 00   The Terminal
    |
 Module 01   Files, Users, Permissions
    |
 Module 02   Shell Scripting
    |
 Module 03   Networking
    |
 Module 04   Virtual Machines (LXD)
    |
 Module 05   Cryptographic Hashing
    |
 Module 06   SSH Fundamentals
    |
 Module 07   SSH Certificates
    |
 Module 08   AppArmor
    |
 Module 09   TPM and Trusted Hardware
    |
 Module 10   IMA (Integrity Measurement)
    |
 Module 11   The Attestation Pipeline
    |
 Module 12   The Complete System
```

## What each module covers

| Module | Title | What you learn |
|--------|-------|----------------|
| 00 | The Terminal | Opening a terminal, navigating the filesystem, running commands |
| 01 | Files, Users, Permissions | How Linux controls who can read, write, and execute what |
| 02 | Shell Scripting | Writing scripts that automate tasks safely and repeatably |
| 03 | Networking | IP addresses, ports, bridges, and how machines find each other |
| 04 | Virtual Machines (LXD) | Creating and managing VMs and containers with LXD |
| 05 | Cryptographic Hashing | How one-way fingerprints detect even a single changed byte |
| 06 | SSH Fundamentals | Connecting to remote machines securely with key pairs |
| 07 | SSH Certificates | Short-lived, scoped authority instead of permanent keys |
| 08 | AppArmor | Constraining what even the root user can do |
| 09 | TPM and Trusted Hardware | A chip that cannot lie about what it measured |
| 10 | IMA (Integrity Measurement) | The kernel logging every file the agent touches |
| 11 | The Attestation Pipeline | Tying measurement, quoting, and signing into one loop |
| 12 | The Complete System | Building and running the full Attested Agent Authority demo |

## What you will be able to do by the end

After completing all thirteen modules, you will:

- Understand every line of the project's build scripts, because you will have
  learned each underlying concept by doing it yourself first.
- Be able to explain, from the ground up, why an agent that edits its own
  AppArmor profile loses all SSH access within a minute — and why putting the
  original file back does not restore it.
- Have built and run the complete demonstration on your own machine.
- Have a working knowledge of Linux administration, shell scripting,
  networking, SSH, mandatory access control, TPM attestation, and integrity
  measurement — not as abstract topics, but as tools you have used.

## Prerequisites

- A computer running **Ubuntu 22.04 or 24.04**. A laptop or desktop is fine.
  You need about 6 GB of free memory and 25 GB of free disk for the later
  modules that build virtual machines.
- An internet connection for initial package downloads.
- No prior Linux experience. Module 00 starts from "how do I open a
  terminal."

## How these labs work

Each module follows the same structure:

1. **Concepts** — plain-language explanation of the theory, with examples.
   Every technical term is defined when it first appears.
2. **Exercises** — numbered, hands-on tasks you perform on your machine. Each
   one tells you exactly what to type, shows you what you should see, and
   explains what just happened.
3. **Checkpoint** — a specific command you run to verify you completed the
   module. If you see the expected output, you are ready to move on.
4. **How this connects to the project** — an explicit link between what you
   just learned and a specific part of the Attested Agent Authority system.

The pedagogy is learn-by-doing. You will understand AppArmor because you
wrote a profile and watched it block root. You will understand TPM quotes
because you requested one and verified its signature. Reading about these
things is not a substitute for doing them, which is why every module is
built around real commands that produce real results.

## Getting started

Open Module 00: [The Terminal](00-the-terminal/README.md)
