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
    "boot_aggregate",
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

ALWAYS_VOLATILE: tuple[str, ...] = ("/etc/ssh/harden-cert.pub",)


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


def derive_volatile(texts: list[str]) -> list[str]:
    """Paths observed with more than one hash across identical runs.

    'Identical runs' is the caller's contract: 70-baseline.sh passes logs from
    two cold boots of the same disk and two consecutive attestations. A file
    whose content is stable can only ever show one hash there; a file that
    shows two is volatile by demonstration, not by assumption.
    """
    moved = {p for p, hs in hashes_by_path(texts).items()
             if len(hs) > 1 and not is_protected(p)}
    moved.update(ALWAYS_VOLATILE)
    return sorted(moved)


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
                 "# more than one hash across identical boots/attestations.",
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
