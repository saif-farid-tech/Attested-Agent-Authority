#!/usr/bin/env python3
"""imalog.py — parse IMA measurement logs and calibrate what is volatile.

Shared by scripts/70-baseline.sh (freezing the allowlist) and
verifier/attest-once.py (checking against it), so both sides can never drift
apart on how a log line is read.

Why "volatile paths" exist at all
---------------------------------
The IMA policy measures every file root READS. Some of the files root reads
have different CONTENT on every boot or every login by design — the systemd
random seed, the timesync clock stamp, lastlog/wtmp. Their hash is therefore
new every time, and no allowlist frozen at build time can ever contain it.
That is not tampering; it is the machine breathing.

The wrong fix is to guess a list of such paths. The right one is to MEASURE
which paths move: boot the same disk twice, attest twice, and any path that
shows more than one hash across those identical runs is volatile by
observation. That is what derive_volatile() does, and 70-baseline.sh feeds it
the logs. The result is written to volatile-paths.txt and signed alongside the
allowlist.

Two guard rails keep this from quietly eating the demonstration:

  PROTECTED    paths that may NEVER be auto-excluded, however they behave.
               The agent's own constraint (/etc/apparmor.d/harden), its code,
               and the system binaries live here. If one of these ever varies,
               attestation must fail loudly rather than learn to ignore it.

  ALWAYS_VOLATILE  paths that are ephemeral by construction and are excluded
               even if a short calibration happened not to catch them moving.
               Only the agent's short-lived certificate qualifies.
"""

from __future__ import annotations

import sys
from fnmatch import fnmatch

# fnmatch's '*' crosses '/', so "/usr/*" covers every depth below /usr.
PROTECTED: tuple[str, ...] = (
    "/etc/apparmor.d/*",
    "/etc/ima/*",
    "/etc/sudoers",
    "/etc/sudoers.d/*",
    "/var/lib/harden/*",
    "/usr/*",
    "/bin/*",
    "/sbin/*",
    "/lib/*",
    "/lib64/*",
    "/opt/*",
    "/srv/*",
)

# /etc/ssh is protected EXCEPT the certificate the verifier rewrites every
# cycle: that file is supposed to have new content constantly.
PROTECTED_EXCEPT: tuple[str, ...] = ("/etc/ssh/harden-cert.pub",)
PROTECTED_EXTRA: tuple[str, ...] = ("/etc/ssh/*",)

# bug #37: 'boot_aggregate' — IMA's own summary of the pre-kernel PCRs — was
# originally PROTECTED on the assumption that it is stable across identical
# boots, the same way the agent's own files are. It isn't, on this project's
# LXD/QEMU/OVMF stack: `tpm2_eventlog` on two cold boots of the byte-identical
# 'demo-ready' snapshot showed every event IDENTICAL except one — EventNum 13,
# PCRIndex 1, EV_PLATFORM_CONFIG_FLAGS ("ACPI DATA") — whose recorded digest
# differed both times. OVMF's generated ACPI tables embed boot-time addresses
# (a documented QEMU/OVMF measured-boot quirk, unrelated to this project), so
# PCR1 — and therefore boot_aggregate — is never reproducible here, tamper or
# not. Treating it as PROTECTED gave zero detective power (it never matched
# twice) while failing attestation on literally every cold boot: baseline's
# own final proof, 'make reset', and ACT 0 of every 'make demo' alike. That is
# the other half of "the demo works, but won't restart" — bug #15 fixed the
# userspace files that vary by design; this is the same fact one layer down,
# at the firmware measurement IMA reports as its very first log line.
ALWAYS_VOLATILE: tuple[str, ...] = ("/etc/ssh/harden-cert.pub", "boot_aggregate")

# Paths whose FILE NAME is generated at run time (bug #30). A calibration can
# only observe a path moving if the path recurs; these never recur, so five
# sample logs prove nothing about them and no allowlist frozen before a boot
# can contain the files that boot is about to create. journald names every
# segment after the boot id and a sequence number; dmesg is rotated at boot.
# They are excused as glob patterns, matched with fnmatch (whose '*' crosses
# '/', so one pattern covers a whole tree).
VOLATILE_PATTERNS: tuple[str, ...] = (
    "/var/log/journal/*",     # system@<boot-id>-<seq>-<realtime>.journal
    "/var/log/dmesg*",        # dmesg, dmesg.0, dmesg.N.gz — rotated every boot
)


def is_protected(path: str) -> bool:
    """True if this path must never be treated as volatile."""
    if any(fnmatch(path, pat) for pat in PROTECTED_EXCEPT):
        return False
    return any(fnmatch(path, pat) for pat in PROTECTED + PROTECTED_EXTRA)


def parse(text: str) -> list[tuple[str, str]]:
    """Return [(file_hash, path)] from an ascii_runtime_measurements dump.

    Line format: PCR TEMPLATE_HASH TEMPLATE_NAME FILE_HASH PATH
    The file hash is written 'sha256:<hex>' (bug #5) — the prefix is stripped
    here, once, so no caller has to remember to do it. PATH is taken as the
    rest of the line so paths containing spaces survive.
    """
    out: list[tuple[str, str]] = []
    for line in text.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        fhash = parts[3].split(":", 1)[-1].strip()
        path = parts[4].strip()
        if fhash and path:
            out.append((fhash, path))
    return out


def hashes_by_path(texts: list[str]) -> dict[str, set[str]]:
    """Every distinct hash each path presented across all the given logs."""
    seen: dict[str, set[str]] = {}
    for text in texts:
        for fhash, path in parse(text):
            seen.setdefault(path, set()).add(fhash)
    return seen


def _covers_protected(directory: str) -> bool:
    """Would a '<directory>/*' glob reach anything the project protects?

    Emitting '/etc/*' because one file under /etc came and went would excuse
    /etc/apparmor.d/harden — the demonstration itself. A directory glob is
    refused whenever a protected pattern lives beneath it, and is_volatile()
    refuses protected paths a second time at match time.
    """
    prefix = directory.rstrip("/") + "/"
    return any(pat.startswith(prefix) for pat in PROTECTED + PROTECTED_EXTRA)


def derive_dir_globs(texts: list[str]) -> list[str]:
    """Directories whose FILE NAMES differ between identical runs.

    The same epistemology as derive_volatile, one level up: if a directory
    holds a file in one run of a pair of identical runs and not in the other,
    the names in that directory are generated at run time, and no build-time
    allowlist can enumerate them. Observed, not assumed — and never for a
    directory that contains something protected.
    """
    per_run: list[dict[str, set[str]]] = []
    for text in texts:
        names: dict[str, set[str]] = {}
        for _, path in parse(text):
            d, _, name = path.rpartition("/")
            if d:
                names.setdefault(d, set()).add(name)
        per_run.append(names)

    samples: dict[str, list[set[str]]] = {}
    for names in per_run:
        for d, ns in names.items():
            samples.setdefault(d, []).append(ns)

    out = []
    for d, seen in samples.items():
        if len(seen) < 2:
            continue                       # one sighting proves nothing
        if set().union(*seen) == set.intersection(*seen):
            continue                       # same filenames every run: stable
        if is_protected(d + "/probe") or _covers_protected(d):
            continue
        out.append(d + "/*")
    return sorted(out)


def derive_volatile(texts: list[str]) -> list[str]:
    """Paths observed with more than one hash across identical runs.

    'Identical runs' is the caller's contract: 70-baseline.sh passes logs from
    two cold boots of the same disk and two consecutive attestations. A file
    whose content is stable can only ever show one hash there; a file that
    shows two is volatile by demonstration, not by assumption.

    Two more sources join it, both for files a recurring-path test cannot see
    (bug #30): directories whose filenames are observed to churn, and the
    by-construction patterns for journald and dmesg.
    """
    moved = {p for p, hs in hashes_by_path(texts).items()
             if len(hs) > 1 and not is_protected(p)}
    moved.update(ALWAYS_VOLATILE)
    moved.update(VOLATILE_PATTERNS)
    moved.update(derive_dir_globs(texts))
    return sorted(moved)


def is_volatile(path: str, entries) -> bool:
    """May this measurement be excused by the calibrated volatile list?

    Protection is checked HERE as well as at derivation time. The entries are
    signed, but they are still a list of strings on disk: if one of them ever
    widens to cover the agent's constraint, its code, or a system binary, the
    answer is still no. The excuse can never reach what the project defends.
    """
    if is_protected(path):
        return False
    if path in entries:
        return True
    return any(_is_glob(e) and fnmatch(path, e) for e in entries)


def _is_glob(entry: str) -> bool:
    return any(c in entry for c in "*?[")


def protected_that_moved(texts: list[str]) -> list[str]:
    """Protected paths that varied anyway — always a real finding, never
    silently excluded. 70-baseline.sh warns about these by name."""
    return sorted(p for p, hs in hashes_by_path(texts).items()
                  if len(hs) > 1 and is_protected(p))


def allowlist_lines(texts: list[str]) -> list[str]:
    """'<hash> <path>' for every measurement seen, sorted and deduplicated."""
    return sorted({f"{h} {p}" for text in texts for h, p in parse(text)})


def load_volatile(path) -> set[str]:
    """Read a volatile-paths.txt (one path per line, '#' comments allowed)."""
    out: set[str] = set()
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.add(line)
    return out


def _read(paths: list[str]) -> list[str]:
    return [open(p, encoding="utf-8", errors="replace").read() for p in paths]


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print("usage: imalog.py {allowlist|volatile|protected-moved} OUT LOG...",
              file=sys.stderr)
        return 2
    mode, out, logs = argv[1], argv[2], argv[3:]
    texts = _read(logs)
    if mode == "allowlist":
        lines = allowlist_lines(texts)
    elif mode == "volatile":
        lines = ["# Derived by observation, not assumption: paths that showed",
                 "# more than one hash across identical boots/attestations, plus",
                 "# glob patterns for directories whose FILE NAMES are generated",
                 "# at run time (journald segments, rotated dmesg) — those can",
                 "# never appear in an allowlist frozen before the boot that",
                 "# creates them. No entry here can excuse a protected path.",
                 "# Regenerate with 'make rebaseline'. See verifier/imalog.py.",
                 *derive_volatile(texts)]
    elif mode == "protected-moved":
        lines = protected_that_moved(texts)
    else:
        print(f"imalog.py: unknown mode {mode!r}", file=sys.stderr)
        return 2
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + ("\n" if lines else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
