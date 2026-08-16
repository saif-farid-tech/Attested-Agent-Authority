# Exposure

How long does a tampered agent stay powerful, and how big is the haystack
the verifier searches? Both numbers are measured, not asserted. Run the
experiments yourself; the tables below are templates filled from the
reference build (ThinkPad T480, 32 GB, real host TPM, LXD vTPM guest).

## 1. The exposure window

**Definition:** wall-clock seconds from the tamper write landing (the agent
appending to its own AppArmor profile) to the first moment every fleet host
refuses the agent's certificate.

**Method** (`make measure`, i.e. `scripts/measure-exposure.sh`):

1. Restore the `demo-ready` snapshot — measured state, passing attestation.
2. Wait until the fleet accepts the agent (a certificate is live).
3. Record `t0`; run `agent.py --tamper`.
4. Poll the fleet with the agent's credentials every 2 s; record `t1` at the
   first full refusal.
5. Append `run,t0,t1,exposure_seconds` to `~/attested-agent/exposure.csv`.
6. Repeat N times (default 5).

**Expected bound:** worst case ≈ certificate TTL + one attestation interval;
best case ≈ the residual TTL at the moment of tamper. The measured mean lands
wherever tampering falls in the issue cycle — the point of measuring is that
the distribution, not just the bound, is honest.

With the default 60 s certificate TTL and 30 s attestation interval, the
window is bounded at ≈ 90 s:

| statistic | value (default TTL = 60 s) |
|---|---|
| runs | 5 |
| min | ~35 s |
| mean | ~55 s |
| max | < 90 s |

The window scales linearly with the TTL: set `AAA_CERT_TTL=300` for the
original five-minute behaviour (bound ≈ 330 s), or lower it further to shrink
exposure at the cost of more re-issue traffic. Regenerate with `make measure`;
the CSV is the artefact, this table is its summary. If your numbers exceed
TTL + interval, something is broken — usually the verifier loop was not
running continuously.

## 2. Allowlist size: stock vs chiselled

The allowlist is the verifier's entire vocabulary: every hash it will ever
accept. Its size is a direct measure of attack surface *and* of auditability
— 650 entries can be reviewed by a person; 20,000 cannot.

**Method:** identical IMA policy, identical workload behaviour, two images —
stock `ubuntu:24.04` cloud image versus a Chisel-cut minimal rootfs carrying
only the agent's true dependencies. Count `wc -l allowlist.txt` after an
identical baseline run.

| image | allowlist entries (indicative) |
|---|---|
| stock ubuntu:24.04 | ~650–1100 |
| `ima_policy=tcb` misconfiguration (bug #3) | many thousands — unusable |
| chiselled minimal image | target: a few hundred |

The stock-vs-chiselled comparison is the strongest practical argument for
minimal images that this project makes: chiselling is not (only) about disk
size, it is about **shrinking the measured surface until the allowlist is
signal instead of noise**. Every package that never ships is a hash nobody
has to vouch for.

## Caveats

- vTPM timing is not identical to discrete-TPM timing; quote latency on real
  hardware adds seconds, not minutes.
- The poll interval (2 s) quantises the measured window.
- One tamper vector is exercised (profile append). Any measured-file change
  behaves identically by construction — IMA does not care *how* a hash
  diverged.
