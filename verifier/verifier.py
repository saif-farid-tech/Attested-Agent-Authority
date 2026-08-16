#!/usr/bin/env python3
"""verifier.py — the attestation loop that funds (or defunds) the agent.

Runs on the HOST (standing in for the Ubuntu Core verifier box — see
docs/ARCHITECTURE.md). Every INTERVAL seconds it runs the same six-stage
cycle as attest-once.py. On a pass it signs a five-minute SSH certificate
for the agent's public key and pushes it into the workload VM. On a fail
it simply stops signing.

The one subtle contract (and the whole console depends on it): on a failing
attestation, keep publishing the PREVIOUS cert_expires_at, unchanged. That
stale timestamp is what makes the console's filament drain in real time
instead of resetting. The agent is never revoked — it is defunded.
"""

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
CERT_TTL = int(os.environ.get("AAA_CERT_TTL", "300"))       # seconds
INTERVAL = int(os.environ.get("AAA_INTERVAL", "30"))
MAX_EVENTS = 60

# attest-once.py has a dash in its name; load it as a module the boring way
_spec = importlib.util.spec_from_file_location("attest_once", HERE / "attest-once.py")
attest_once = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(attest_once)


def issue_certificate() -> float:
    """Sign a 5-minute certificate for the agent's key and push it into the
    VM. Returns the expiry as a unix timestamp."""
    pub = STATE / "harden_key.pub"
    ca = STATE / "ssh_ca"
    minutes = max(1, CERT_TTL // 60)
    subprocess.run(
        ["ssh-keygen", "-q", "-s", str(ca), "-I", "harden-agent",
         "-n", "harden", "-V", f"+{minutes}m", str(pub)],
        check=True)
    cert = STATE / "harden_key-cert.pub"
    subprocess.run(
        ["lxc", "file", "push", str(cert), f"{VM}/etc/ssh/harden-cert.pub"],
        check=True, capture_output=True)
    return time.time() + minutes * 60


def load_status() -> dict:
    try:
        return json.loads(STATUS.read_text())
    except (FileNotFoundError, ValueError):
        return {"attestation": "unknown", "reason": "verifier starting",
                "cert_expires_at": 0.0, "events": []}


def write_status(status: dict) -> None:
    tmp = STATUS.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(status, indent=1))
    tmp.replace(STATUS)   # atomic: the console never reads a half-written file


def add_event(status: dict, kind: str, text: str) -> None:
    status["events"].insert(0, {"ts": time.time(), "kind": kind, "text": text})
    del status["events"][MAX_EVENTS:]
    print(f"verifier: [{kind}] {text}", flush=True)


def main() -> int:
    STATUS.parent.mkdir(parents=True, exist_ok=True)
    status = load_status()
    add_event(status, "issue", f"verifier online, attesting every {INTERVAL}s")
    write_status(status)
    was_funded = status.get("cert_expires_at", 0) > time.time()

    while True:
        code, reason, _ = attest_once.attest(report=lambda _line: None)
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
                          f"Certificate issued, valid {CERT_TTL // 60} min")
                was_funded = True
            except subprocess.CalledProcessError as e:
                status["attestation"] = "fail"
                status["reason"] = f"certificate issuance failed: {e}"
                add_event(status, "fail", status["reason"])
        elif code == attest_once.ATTEST_FAIL:
            # Do NOT touch cert_expires_at. The last certificate is still out
            # there, still valid, still draining. Publishing the stale expiry
            # is what makes that visible.
            status["attestation"] = "fail"
            status["reason"] = reason.splitlines()[0]
            add_event(status, "fail",
                      "Attestation failed — signing stops, certificate left to drain")
        else:
            status["attestation"] = "error"
            status["reason"] = f"setup problem, not an attestation verdict: {reason}"
            add_event(status, "fail", status["reason"])

        if was_funded and status["cert_expires_at"] <= now:
            add_event(status, "expire",
                      "Certificate expired — the agent now has NO AUTHORITY")
            was_funded = False

        write_status(status)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nverifier: stopped")
        sys.exit(0)
