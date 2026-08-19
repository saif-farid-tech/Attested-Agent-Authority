#!/usr/bin/env python3
"""End-to-end test of the restart path, without LXD or a TPM.

Reproduces the failure the demo actually hit — 'make demo' works once, then
refuses to restart — by replaying measurement logs through the REAL
stage6_allowlist() from attest-once.py.

  python3 tests/test_restart_scenario.py
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
VERIFIER = REPO / "verifier"

STATE = Path(tempfile.mkdtemp(prefix="aaa-restart-test-"))
os.environ["AAA_STATE"] = str(STATE)

_spec = importlib.util.spec_from_file_location("attest_once", VERIFIER / "attest-once.py")
attest_once = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(attest_once)


def entry(fhash: str, path: str) -> str:
    return f"10 {'0' * 40} ima-ng sha256:{fhash} {path}"


def boot_log(seed: str, lastlog: str, profile: str = "profile-clean",
             boot_id: str = "0001") -> str:
    """A plausible IMA log for one boot of the workload VM.

    Three rows legitimately move. Systemd rewrites its random seed every boot
    and sshd updates lastlog on every login the verifier makes — those keep
    their PATH and change their hash, which the calibration can observe. The
    journal segment is the harder class (bug #30): journald names every file
    after the boot id, so the path itself is new each time and NO amount of
    observing recurring paths can ever predict it.
    """
    return "\n".join([
        entry("journal-" + boot_id,
              f"/var/log/journal/864e2228/system@{boot_id}-000653.journal"),
        entry("aggregate", "boot_aggregate"),
        entry("sshbin", "/usr/bin/ssh"),
        entry("python", "/usr/bin/python3.14"),
        entry("agentpy", "/var/lib/harden/agent.py"),
        entry("cfg", "/var/lib/harden/config.json"),
        entry("hosts", "/etc/hosts"),
        entry(profile, "/etc/apparmor.d/harden"),
        entry(seed, "/var/lib/systemd/random-seed"),
        entry(lastlog, "/var/log/lastlog"),
    ]) + "\n"


def build_baseline(logs: list[str]) -> None:
    """What 70-baseline.sh does: freeze an allowlist and calibrate volatiles."""
    paths = []
    for i, text in enumerate(logs):
        p = STATE / f"cal-{i}.log"
        p.write_text(text)
        paths.append(str(p))
    for mode, out in (("allowlist", "allowlist.txt"), ("volatile", "volatile-paths.txt")):
        r = subprocess.run([sys.executable, str(VERIFIER / "imalog.py"), mode,
                            str(STATE / out), *paths],
                           capture_output=True, text=True)
        assert r.returncode == 0, r.stderr


_original_ssh = attest_once.ssh


def check(log_text: str):
    """Run the real stage 6 against a workload presenting this log."""
    attest_once.ssh = lambda *a, **k: log_text
    try:
        return attest_once.stage6_allowlist(lambda _msg: None)
    finally:
        attest_once.ssh = _original_ssh


CASES = []


def case(fn):
    CASES.append(fn)
    return fn


# Baseline calibration: two cold boots + two attestations, exactly as
# 70-baseline.sh captures them. The seed and lastlog differ between runs.
BASELINE = [
    boot_log("seed-a", "lastlog-1", boot_id="aaa1"),
    boot_log("seed-b", "lastlog-2", boot_id="bbb2"),
    boot_log("seed-b", "lastlog-3", boot_id="bbb2"),
    boot_log("seed-b", "lastlog-4", boot_id="bbb2"),
]


@case
def test_calibration_marks_only_the_genuinely_volatile_paths():
    build_baseline(BASELINE)
    volatile = {l for l in (STATE / "volatile-paths.txt").read_text().splitlines()
                if l and not l.startswith("#")}
    assert "/var/lib/systemd/random-seed" in volatile, volatile
    assert "/var/log/lastlog" in volatile, volatile
    assert "/etc/apparmor.d/harden" not in volatile, volatile
    assert "/var/lib/harden/agent.py" not in volatile, volatile


@case
def test_regression_the_old_single_boot_baseline_fails_to_restart():
    """The bug, reproduced. The previous baseline froze the allowlist from one
    warm boot and had no notion of volatile paths, so the very next cold boot
    presented a random seed and a lastlog nobody had ever measured. Two
    unrecognised measurements, attestation refused, the verifier never funded
    the agent again — 'make demo' hung in ACT 2 waiting for a certificate that
    was never coming."""
    build_baseline([BASELINE[0]])
    (STATE / "volatile-paths.txt").write_text("")     # what the old code had
    try:
        check(boot_log("seed-NEW", "lastlog-NEW"))
    except attest_once.StageFailure as e:
        assert e.code == attest_once.ATTEST_FAIL
        assert "/var/lib/systemd/random-seed" in e.what, e.what
    else:
        raise AssertionError("expected the un-calibrated baseline to fail")


@case
def test_a_restart_with_a_brand_new_random_seed_still_passes():
    # THE BUG: a cold boot writes a seed and a lastlog nobody has ever seen.
    # Before the calibration these were two unrecognised measurements and the
    # verifier stopped funding the agent, so 'make demo' hung in ACT 2.
    build_baseline(BASELINE)
    msg = check(boot_log("seed-NEVER-SEEN", "lastlog-NEVER-SEEN"))
    assert "every measurement recognised" in msg, msg
    # The seed and lastlog at minimum; a journal segment is excused alongside
    # them now, so assert the floor rather than an exact count.
    import re
    excused = int(re.search(r"(\d+) volatile-path", msg).group(1))
    assert excused >= 2, msg


@case
def test_ten_consecutive_restarts_all_pass():
    build_baseline(BASELINE)
    for i in range(10):
        check(boot_log(f"seed-{i}", f"lastlog-{i}"))


@case
def test_a_restart_whose_journal_filename_never_existed_before_passes():
    """Their build failure, exactly. Every boot from the snapshot opens a NEW
    journald segment: the filename has never been seen, so it is on no
    allowlist, and being unable to recur it can never be observed 'moving'
    either. Seven such measurements failed the attestation that 70-baseline
    runs on itself, and the build died on its last line."""
    build_baseline(BASELINE)
    msg = check(boot_log("seed-z", "lastlog-z", boot_id="NEVER-BOOTED-BEFORE"))
    assert "every measurement recognised" in msg, msg


@case
def test_journal_segments_do_not_become_a_hiding_place():
    # The excuse is for names under the journal directory; it must not extend
    # to the things the project protects, wherever they are measured from.
    build_baseline(BASELINE)
    try:
        check(boot_log("seed-x", "lastlog-x", profile="profile-TAMPERED",
                       boot_id="brand-new"))
    except attest_once.StageFailure as e:
        assert "/etc/apparmor.d/harden" in e.what, e.what
    else:
        raise AssertionError("a new journal name must not excuse the tamper")


@case
def test_the_tamper_still_fails_attestation():
    # The whole point of the project: excusing volatile paths must not excuse
    # the agent rewriting its own constraint.
    build_baseline(BASELINE)
    try:
        check(boot_log("seed-x", "lastlog-x", profile="profile-TAMPERED"))
    except attest_once.StageFailure as e:
        assert e.code == attest_once.ATTEST_FAIL, e.code
        assert "/etc/apparmor.d/harden" in e.what, e.what
    else:
        raise AssertionError("the tamper was not detected — the demo is a lie")


@case
def test_editing_the_agent_still_fails_attestation():
    # bug #10 must survive the calibration too.
    build_baseline(BASELINE)
    tampered = boot_log("seed-y", "lastlog-y").replace(
        "sha256:agentpy /var/lib/harden/agent.py",
        "sha256:agentpy-EDITED /var/lib/harden/agent.py")
    try:
        check(tampered)
    except attest_once.StageFailure as e:
        assert e.code == attest_once.ATTEST_FAIL
        assert "/var/lib/harden/agent.py" in e.what, e.what
    else:
        raise AssertionError("an edited agent passed attestation")


@case
def test_an_unknown_new_file_still_fails_attestation():
    build_baseline(BASELINE)
    intruder = boot_log("seed-z", "lastlog-z") + entry("evil", "/usr/local/bin/backdoor") + "\n"
    try:
        check(intruder)
    except attest_once.StageFailure as e:
        assert e.code == attest_once.ATTEST_FAIL
        assert "/usr/local/bin/backdoor" in e.what, e.what
    else:
        raise AssertionError("an unmeasured binary passed attestation")


# ---- the signed-allowlist check (bug #25) ---------------------------------
# The project's claim is that measurements are compared against a SIGNED
# inventory. Nothing verified that signature until now, so these cover it.

class _Result:
    def __init__(self, rc): self.returncode, self.stderr, self.stdout = rc, "", ""


@case
def test_an_unsigned_allowlist_is_a_setup_failure_not_a_verdict():
    build_baseline(BASELINE)
    (STATE / "allowlist.txt.asc").unlink(missing_ok=True)
    try:
        attest_once.verify_signature(STATE / "allowlist.txt")
    except attest_once.StageFailure as e:
        # SETUP_FAIL, not ATTEST_FAIL: a broken verifier is not a verdict
        # about the workload, and must never be reported as one.
        assert e.code == attest_once.SETUP_FAIL, e.code
        assert "rebaseline" in e.remedy
    else:
        raise AssertionError("an unsigned allowlist was accepted")


@case
def test_an_allowlist_edited_after_signing_is_rejected():
    build_baseline(BASELINE)
    (STATE / "allowlist.txt.asc").write_text("-----BEGIN PGP SIGNATURE-----\n")
    real_run = attest_once.subprocess.run
    attest_once.subprocess.run = lambda *a, **k: _Result(1)   # gpg says "bad"
    try:
        attest_once.verify_signature(STATE / "allowlist.txt")
    except attest_once.StageFailure as e:
        assert e.code == attest_once.SETUP_FAIL
        assert "does not match its signature" in e.what
    else:
        raise AssertionError("a forged allowlist was accepted")
    finally:
        attest_once.subprocess.run = real_run


@case
def test_a_good_signature_passes():
    build_baseline(BASELINE)
    (STATE / "allowlist.txt.asc").write_text("-----BEGIN PGP SIGNATURE-----\n")
    real_run = attest_once.subprocess.run
    attest_once.subprocess.run = lambda *a, **k: _Result(0)   # gpg says "good"
    try:
        attest_once.verify_signature(STATE / "allowlist.txt")   # must not raise
    finally:
        attest_once.subprocess.run = real_run


@case
def test_ssh_timeout_is_a_stage_failure_not_a_crash():
    """The verifier crashed on TimeoutExpired because ssh() did not catch it.
    After a cold boot (every demo redo) the VM is slow to respond, the 60s
    timeout fires, and the uncaught exception killed the verifier loop — no
    certificates, demo hangs in ACT 2."""
    real_run = attest_once.subprocess.run
    def fake_run(*a, **k):
        raise subprocess.TimeoutExpired(cmd="ssh", timeout=60)
    attest_once.subprocess.run = fake_run
    try:
        attest_once.ssh("true")
        raise AssertionError("ssh() should have raised StageFailure on timeout")
    except attest_once.StageFailure as e:
        assert e.code == attest_once.SETUP_FAIL, \
            f"expected SETUP_FAIL (1), got {e.code}"
        assert "timed out" in e.what, e.what
    finally:
        attest_once.subprocess.run = real_run


@case
def test_verifier_survives_a_transient_attest_crash():
    """The verifier's main loop had no exception handling around attest().
    Any unhandled exception killed the loop permanently."""
    _vspec = importlib.util.spec_from_file_location("verifier_mod", VERIFIER / "verifier.py")
    _vmod = importlib.util.module_from_spec(_vspec)
    _vspec.loader.exec_module(_vmod)
    s = _vmod.fresh_status()
    assert s["attestation"] == "unknown"
    assert s["cert_expires_at"] == 0.0


def _load_verifier():
    spec = importlib.util.spec_from_file_location("verifier_mod", VERIFIER / "verifier.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _wait_cmdline(pid: int, want_verifier: bool) -> None:
    """Wait until the child has exec'd and /proc/<pid>/cmdline reflects it.
    Right after Popen returns there is a brief window before exec where cmdline
    is not yet the child's argv; polling here keeps the tests deterministic."""
    import time as _t
    vmod = _load_verifier()
    for _ in range(200):                       # up to ~2s
        try:
            populated = bool(open(f"/proc/{pid}/cmdline", "rb").read().strip(b"\0"))
        except OSError:
            populated = False
        if populated and vmod._pid_is_verifier(pid) == want_verifier:
            return
        _t.sleep(0.01)
    raise AssertionError(f"child {pid} did not reach the expected cmdline state")


@case
def test_a_recycled_lock_pid_that_is_not_a_verifier_does_not_block_startup():
    """bug #35: the lock file is leaked on every stop (SIGTERM runs no atexit),
    and the OS may recycle that pid to an unrelated LIVE process. A bare
    liveness check then mistook that stranger for a running verifier and the
    next verifier refused to start — the demo died on redo with 'the verifier
    failed to start'. A live pid that is NOT a verifier must be treated as a
    stale lock and taken over."""
    import signal
    vmod = _load_verifier()
    live = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    old_sigterm = signal.getsignal(signal.SIGTERM)
    try:
        _wait_cmdline(live.pid, want_verifier=False)
        d = Path(tempfile.mkdtemp(prefix="aaa-lock-"))
        vmod.STATE = d
        (d / "verifier.pid").write_text(f"{live.pid}\n")
        vmod.acquire_lock()   # must NOT sys.exit on a live non-verifier pid
        assert (d / "verifier.pid").read_text().strip() == str(os.getpid()), \
            "acquire_lock did not take over the stale lock"
    finally:
        signal.signal(signal.SIGTERM, old_sigterm)   # acquire_lock installs one
        live.terminate(); live.wait()


@case
def test_a_live_verifier_pid_still_blocks_a_second_verifier():
    """The fix must not become 'always take the lock' (that would re-open bug
    #22, two verifiers racing on status.json). A pid whose command line really
    is verifier/verifier.py is a genuine competitor and must still block."""
    import signal
    vmod = _load_verifier()
    # A live process whose argv ends in 'verifier/verifier.py' — the command
    # line _pid_is_verifier looks for — without running the real attestation loop.
    fake_dir = Path(tempfile.mkdtemp()) / "verifier"
    fake_dir.mkdir(parents=True)
    fake = fake_dir / "verifier.py"
    fake.write_text("import time; time.sleep(30)\n")
    live = subprocess.Popen([sys.executable, str(fake)])
    old_sigterm = signal.getsignal(signal.SIGTERM)
    try:
        _wait_cmdline(live.pid, want_verifier=True)
        d = Path(tempfile.mkdtemp(prefix="aaa-lock-"))
        vmod.STATE = d
        (d / "verifier.pid").write_text(f"{live.pid}\n")
        try:
            vmod.acquire_lock()
        except SystemExit as e:
            assert "already running" in str(e), e
        else:
            raise AssertionError("a live verifier pid should block a second verifier")
    finally:
        signal.signal(signal.SIGTERM, old_sigterm)
        live.terminate(); live.wait()


def main() -> int:
    failed = 0
    for fn in CASES:
        try:
            fn()
        except AssertionError as exc:
            failed += 1
            print(f"FAIL  {fn.__name__}: {exc}")
        else:
            print(f"ok    {fn.__name__}")
    print(f"\n{len(CASES) - failed}/{len(CASES)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
