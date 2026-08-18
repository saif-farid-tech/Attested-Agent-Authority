#!/usr/bin/env python3
"""verifier.py — the attestation loop that funds (or defunds) the agent.

Runs on the HOST (standing in for the Ubuntu Core verifier box — see
docs/ARCHITECTURE.md). Every INTERVAL seconds it runs the same six-stage
cycle as attest-once.py. On a pass it signs a short-lived SSH certificate
for the agent's public key and pushes it into the workload VM. On a fail
it simply stops signing.

The one subtle contract (and the whole console depends on it): on a failing
attestation, keep publishing the PREVIOUS cert_expires_at, unchanged. That
stale timestamp is what makes the console's filament drain in real time
instead of resetting. The agent is never revoked — it is defunded.
"""

import atexit
import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
STATE = Path(os.environ.get("AAA_STATE", Path.home() / "attested-agent"))
STATUS = Path(os.environ.get("AAA_STATUS", REPO / "console" / "status.json"))
VM = os.environ.get("AAA_VM", "harden")
# Certificate lifetime. Short on purpose: it bounds the tamper→powerless
# window and keeps the demo watchable. 60 s pairs with the 30 s attestation
# interval so a funded agent's cert is refreshed well before it lapses, while
# the post-tamper drain still finishes inside ~90 s. Override with AAA_CERT_TTL.
CERT_TTL = int(os.environ.get("AAA_CERT_TTL", "60"))        # seconds
INTERVAL = int(os.environ.get("AAA_INTERVAL", "30"))
MAX_EVENTS = 60

# attest-once.py has a dash in its name; load it as a module the boring way
_spec = importlib.util.spec_from_file_location("attest_once", HERE / "attest-once.py")
attest_once = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(attest_once)


# ssh-keygen validity is whole minutes, so the real cert life is minutes*60.
# Everything downstream (expiry, the console's filament scale) uses this so a
# non-multiple-of-60 AAA_CERT_TTL can't desync the display from reality.
CERT_MINUTES = max(1, CERT_TTL // 60)
CERT_SECONDS = CERT_MINUTES * 60


def issue_certificate() -> float:
    """Sign a short-lived certificate for the agent's key and push it into the
    VM. Returns the expiry as a unix timestamp."""
    pub = STATE / "harden_key.pub"
    ca = STATE / "ssh_ca"
    subprocess.run(
        ["ssh-keygen", "-q", "-s", str(ca), "-I", "harden-agent",
         "-n", "harden", "-V", f"+{CERT_MINUTES}m", str(pub)],
        check=True)
    cert = STATE / "harden_key-cert.pub"
    subprocess.run(
        ["lxc", "file", "push", str(cert), f"{VM}/etc/ssh/harden-cert.pub"],
        check=True, capture_output=True)
    return time.time() + CERT_SECONDS


def fresh_status() -> dict:
    """A new verifier process starts from a blank slate.

    It used to resume whatever status.json held, which meant a second run
    inherited the previous one's events and — worse — its cert_expires_at.
    The console then opened on a filament draining from a certificate that no
    longer existed, narrating a run that had already finished. This verifier
    has funded nothing yet, and says so (bug #18)."""
    return {"attestation": "unknown",
            "reason": "verifier starting — no attestation cycle has run yet",
            "cert_expires_at": 0.0, "cert_ttl": CERT_SECONDS, "events": []}


def acquire_lock() -> None:
    """Refuse to start when another verifier is already live.

    Two verifiers race on status.json and both push certificates, so the
    console flickers between their views and the certificate lifetime becomes
    unpredictable — 'make console' plus a demo that started its own was enough
    to do it (bug #22). A stale lock file from a killed process is ignored."""
    lock = STATE / "verifier.pid"
    try:
        other = int(lock.read_text().strip())
    except (FileNotFoundError, ValueError):
        other = 0
    if other and other != os.getpid():
        try:
            os.kill(other, 0)
        except OSError:
            pass          # the pid is gone; the lock is stale, take it
        else:
            sys.exit(f"verifier: another verifier is already running (pid {other}).\n"
                     f"          stop it first, or remove {lock} if it is stale.")
    lock.parent.mkdir(parents=True, exist_ok=True)
    lock.write_text(f"{os.getpid()}\n")
    atexit.register(lambda: lock.unlink(missing_ok=True))


def write_status(status: dict) -> None:
    tmp = STATUS.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(status, indent=1))
    tmp.replace(STATUS)   # atomic: the console never reads a half-written file


def add_event(status: dict, kind: str, text: str) -> None:
    status["events"].insert(0, {"ts": time.time(), "kind": kind, "text": text})
    del status["events"][MAX_EVENTS:]
    print(f"verifier: [{kind}] {text}", flush=True)


def ingest_dropbox(status: dict) -> bool:
    """Merge events other processes (the demo script) left for the console.
    One JSON object per line: {"kind": "act", "text": "..."}. Best-effort —
    a lost line during the read/unlink window is acceptable for narration."""
    box = STATE / "console-events.jsonl"
    if not box.exists():
        return False
    lines = box.read_text().splitlines()
    box.unlink()
    seen = False
    for line in lines:
        try:
            e = json.loads(line)
            add_event(status, e.get("kind", "act"), str(e.get("text", ""))[:300])
            seen = True
        except ValueError:
            continue
    return seen


def main() -> int:
    STATUS.parent.mkdir(parents=True, exist_ok=True)
    acquire_lock()
    status = fresh_status()
    add_event(status, "issue", f"verifier online, attesting every {INTERVAL}s")
    write_status(status)
    was_funded = False
    next_attest = 0.0

    while True:
        now = time.time()

        # fast lane (every ~2 s): narration events and the expiry moment
        dirty = ingest_dropbox(status)
        if was_funded and status["cert_expires_at"] <= now:
            add_event(status, "expire",
                      "Certificate expired — the agent now has NO AUTHORITY")
            was_funded = False
            dirty = True
        if dirty:
            write_status(status)
        if now < next_attest:
            time.sleep(2)
            continue
        next_attest = now + INTERVAL

        # slow lane (every INTERVAL): a full attestation cycle
        try:
            code, reason, _ = attest_once.attest(report=lambda _line: None)
        except Exception as exc:
            add_event(status, "fail",
                      f"attestation cycle crashed: {type(exc).__name__}: {exc}")
            status["attestation"] = "error"
            status["reason"] = f"transient error (will retry): {exc}"
            write_status(status)
            continue
        now = time.time()

        if code == 0:
            entries = sum(1 for l in (STATE / "allowlist.txt").read_text()
                          .splitlines() if l.strip())
            status["attestation"] = "pass"
            status["reason"] = "Measurements match the signed allowlist."
            add_event(status, "pass",
                      f"Quote verified · {entries} measurements recognised")
            try:
                status["cert_expires_at"] = issue_certificate()
                add_event(status, "issue",
                          f"Certificate issued, valid {CERT_MINUTES} min")
                was_funded = True
            except subprocess.CalledProcessError as e:
                status["attestation"] = "fail"
                status["reason"] = f"certificate issuance failed: {e}"
                add_event(status, "fail", status["reason"])
        elif code == attest_once.ATTEST_FAIL:
            # Do NOT touch cert_expires_at. The last certificate is still out
            # there, still valid, still draining. Publishing the stale expiry
            # is what makes that visible.
            if status["attestation"] != "fail":   # log the transition once
                add_event(status, "fail",
                          "Attestation failed — signing stops, certificate left to drain")
            status["attestation"] = "fail"
            status["reason"] = reason.splitlines()[0]
        else:
            status["attestation"] = "error"
            status["reason"] = f"setup problem, not an attestation verdict: {reason}"
            add_event(status, "fail", status["reason"])

        write_status(status)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nverifier: stopped")
        sys.exit(0)
