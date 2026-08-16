# Limits

What this project does **not** solve. Read this before citing it.

## The exposure window is real

Between the tamper and the last certificate's expiry, the agent keeps full
authority. The window is bounded — certificate TTL plus one attestation
interval, worst case — but it is not zero and cannot be zero in this design:
revocation-by-expiry trades immediacy for the enormous simplification of
stateless fleet hosts. The window is measured, not hand-waved:
`make measure` reproduces the numbers in [EXPOSURE.md](EXPOSURE.md). If your
threat model cannot tolerate minutes of exposure, you need shorter TTLs (and
the re-issue traffic that implies), or online revocation (and the
infrastructure *that* implies).

## IMA measures files, not semantics

Attestation says: *the bytes that executed and the bytes root read are the
bytes on the signed allowlist.* It does not say the configuration is wise,
the profile is tight, or the code is correct. A disastrous AppArmor profile
measures just as cleanly as a good one, provided it is the profile you
signed. Garbage in, attested garbage out.

## Attestation says nothing about model behaviour

The model's weights are on the allowlist; its *outputs* are not measurable.
A model that plans something harmful within the agent's existing authority is
completely invisible to this machinery. What the design bounds is the blast
radius and the duration of authority — not the quality of decisions made
while authority lasts.

## The confused deputy is untouched

Authority binds to *state*, not *intent*. If the agent is tricked into
misusing power it legitimately holds — remediating the wrong host, deleting
the right file for the wrong reason — every measurement matches, every quote
verifies, and the certificate keeps coming. **This project does not solve
prompt injection.** Nothing here inspects, filters, or judges the agent's
inputs or intentions. Anyone claiming measured state solves injection is
selling something.

## The trust boundary moved; it did not disappear

The fleet now trusts the CA key; the CA key's custodian is the verifier; the
allowlist is trusted because a human signed it. Compromise the signing
pipeline — the verifier box, the GPG key, the enrolment step that exported
the AK — and everything downstream is faithfully, cryptographically wrong.
The claim is that a small immutable verifier is a *better* place to
concentrate trust than an agent with root on a workload, not that trust went
away.

## swtpm is not a root of trust

In this demo the TPM is virtual (swtpm via LXD). The host that runs the VM
can forge every quote. The measured-boot chain, IMA, quote verification and
the revocation behaviour are all real and transfer unchanged to real
hardware — a discrete TPM or a confidential VM is a substrate swap, not a
redesign — but do not point at this repo running on a laptop and call it
tamper-proof. It is a working model of the mechanism, honest about its
foundations.
