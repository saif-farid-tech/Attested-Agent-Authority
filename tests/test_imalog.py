#!/usr/bin/env python3
"""Tests for verifier/imalog.py — the calibration logic the whole restart
story depends on. Runs without pytest:  python3 tests/test_imalog.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "verifier"))
import imalog  # noqa: E402


def line(fhash: str, path: str) -> str:
    return f"10 0000000000000000000000000000000000000000 ima-ng sha256:{fhash} {path}"


def log(*entries: tuple[str, str]) -> str:
    return "\n".join(line(h, p) for h, p in entries) + "\n"


CASES = []


def case(fn):
    CASES.append(fn)
    return fn


@case
def test_parse_strips_the_sha256_prefix():
    # bug #5: keeping the prefix means nothing ever matches.
    assert imalog.parse(log(("abc123", "/usr/bin/ssh"))) == [("abc123", "/usr/bin/ssh")]


@case
def test_parse_keeps_paths_containing_spaces():
    assert imalog.parse(log(("aa", "/var/lib/a b/c"))) == [("aa", "/var/lib/a b/c")]


@case
def test_parse_skips_short_and_blank_lines():
    assert imalog.parse("10 deadbeef ima-ng\n\n   \n") == []


@case
def test_stable_paths_are_not_volatile():
    a = log(("h1", "/usr/bin/ssh"), ("h2", "/etc/hosts"))
    b = log(("h1", "/usr/bin/ssh"), ("h2", "/etc/hosts"))
    assert "/etc/hosts" not in imalog.derive_volatile([a, b])


@case
def test_a_path_that_moves_between_identical_runs_is_volatile():
    # /var/lib/systemd/random-seed is rewritten every boot: this is THE bug
    # that made 'make demo' fail to restart.
    a = log(("seed1", "/var/lib/systemd/random-seed"))
    b = log(("seed2", "/var/lib/systemd/random-seed"))
    assert "/var/lib/systemd/random-seed" in imalog.derive_volatile([a, b])


@case
def test_lastlog_moving_between_attestations_is_volatile():
    a = log(("l1", "/var/log/lastlog"))
    b = log(("l2", "/var/log/lastlog"))
    assert "/var/log/lastlog" in imalog.derive_volatile([a, b])


@case
def test_the_agents_constraint_is_never_auto_excluded():
    # If this ever regressed, the tamper would stop failing attestation and
    # the entire demonstration would silently become a lie.
    a = log(("clean", "/etc/apparmor.d/harden"))
    b = log(("tampered", "/etc/apparmor.d/harden"))
    assert "/etc/apparmor.d/harden" not in imalog.derive_volatile([a, b])
    assert imalog.protected_that_moved([a, b]) == ["/etc/apparmor.d/harden"]


@case
def test_the_agents_own_code_is_never_auto_excluded():
    a = log(("v1", "/var/lib/harden/agent.py"))
    b = log(("v2", "/var/lib/harden/agent.py"))
    assert "/var/lib/harden/agent.py" not in imalog.derive_volatile([a, b])


@case
def test_system_binaries_are_never_auto_excluded():
    a = log(("v1", "/usr/bin/ssh"))
    b = log(("v2", "/usr/bin/ssh"))
    assert imalog.derive_volatile([a, b]) == list(imalog.ALWAYS_VOLATILE)


@case
def test_boot_aggregate_is_never_auto_excluded():
    a = log(("agg1", "boot_aggregate"))
    b = log(("agg2", "boot_aggregate"))
    assert "boot_aggregate" not in imalog.derive_volatile([a, b])
    assert "boot_aggregate" in imalog.protected_that_moved([a, b])


@case
def test_the_rotating_certificate_is_volatile_even_under_etc_ssh():
    # /etc/ssh/* is protected, but the cert is rewritten every cycle by design.
    assert "/etc/ssh/harden-cert.pub" in imalog.derive_volatile([log(("c1", "/x"))])
    assert not imalog.is_protected("/etc/ssh/harden-cert.pub")
    assert imalog.is_protected("/etc/ssh/sshd_config")


@case
def test_allowlist_is_deduplicated_and_sorted():
    a = log(("h2", "/b"), ("h1", "/a"))
    b = log(("h1", "/a"))
    assert imalog.allowlist_lines([a, b]) == ["h1 /a", "h2 /b"]


@case
def test_load_volatile_ignores_comments_and_blanks(tmp=Path("/tmp")):
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
        fh.write("# a comment\n\n/var/log/lastlog\n  /var/lib/systemd/random-seed  \n")
        name = fh.name
    got = imalog.load_volatile(name)
    Path(name).unlink()
    assert got == {"/var/log/lastlog", "/var/lib/systemd/random-seed"}


@case
def test_load_volatile_of_a_missing_file_is_empty_not_an_error():
    assert imalog.load_volatile("/nonexistent/volatile-paths.txt") == set()


def main() -> int:
    failed = 0
    for fn in CASES:
        try:
            fn()
        except AssertionError as exc:
            failed += 1
            print(f"FAIL  {fn.__name__}: {exc or 'assertion failed'}")
        else:
            print(f"ok    {fn.__name__}")
    print(f"\n{len(CASES) - failed}/{len(CASES)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
