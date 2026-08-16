#!/usr/bin/env python3
"""Harden — a security-remediation agent whose authority is rented, not owned.

Runs inside the workload VM as user `harden`, confined by the AppArmor
profile at /etc/apparmor.d/harden. It holds a private SSH key, but the key
is worthless without the certificate the verifier re-issues every five
minutes — and the verifier only signs while the VM's measured state matches
the allowlist. Harden can do anything its certificate allows and nothing
after it expires.

Modes:
  agent.py               one remediation pass over the fleet
  agent.py --loop        remediation pass every INTERVAL seconds
  agent.py --tamper      modify its own AppArmor profile (the demonstration)

The tamper write SUCCEEDS. Nothing here is blocked. The point of the whole
project is what happens afterwards, elsewhere.
"""

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

STATE = Path("/var/lib/harden")
CONFIG = STATE / "config.json"
CERT = Path("/etc/ssh/harden-cert.pub")
KEY = Path.home() / ".ssh" / "id_ed25519"
PROFILE = Path("/etc/apparmor.d/harden")

# Fixed, auditable remediation actions. The model chooses among these;
# it cannot invent shell commands. See docs/LIMITS.md — this narrows the
# blast radius of a bad completion, it does not solve prompt injection.
PLAYBOOK = {
    "world_writable": "find /srv /opt -xdev -type f -perm -0002 -exec chmod o-w {} +",
    "stale_tmp": "find /tmp -xdev -type f -mtime +7 -delete",
    "ssh_root_login": (
        "grep -q '^PermitRootLogin no' /etc/ssh/sshd_config || "
        "{ echo 'PermitRootLogin no' | sudo tee -a /etc/ssh/sshd_config >/dev/null; }"
    ),
}


def load_config() -> dict:
    try:
        return json.loads(CONFIG.read_text())
    except FileNotFoundError:
        sys.exit(f"harden: no config at {CONFIG} (deployed by scripts/50-agent.sh)")


def ask_model(endpoint: str, findings: list[str]) -> list[str]:
    """Ask the model which playbook actions to run. Degrades gracefully:
    a model that is down or empty-handed is a normal condition (bug #8),
    reported in one sentence — never a stack trace."""
    prompt = (
        "You are a security remediation planner. Findings on a host:\n"
        + "\n".join(f"- {f}" for f in findings)
        + "\nReply with a JSON array of action names chosen only from: "
        + ", ".join(PLAYBOOK) + "\n"
    )
    body = json.dumps({"prompt": prompt, "n_predict": 64, "temperature": 0}).encode()
    try:
        req = urllib.request.Request(
            endpoint, data=body, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode().strip()
    except (urllib.error.URLError, OSError, TimeoutError):
        print(f"harden: model endpoint {endpoint} is unreachable; "
              "falling back to running every applicable action")
        return list(PLAYBOOK)
    if not raw:
        # json.loads("") raises — and a down model must never look like a crash
        print(f"harden: model endpoint {endpoint} returned an empty response; "
              "falling back to running every applicable action")
        return list(PLAYBOOK)
    try:
        content = json.loads(raw).get("content", "")
        start, end = content.find("["), content.rfind("]")
        actions = json.loads(content[start:end + 1])
        return [a for a in actions if a in PLAYBOOK]
    except (ValueError, AttributeError):
        print(f"harden: could not parse the reply from {endpoint}; "
              "falling back to running every applicable action")
        return list(PLAYBOOK)


def ssh(host: str, command: str) -> subprocess.CompletedProcess:
    """Run a command on a fleet host. Authority = key + 5-minute certificate.
    sshd on the fleet trusts only certificates signed by the verifier's CA
    (TrustedUserCAKeys); a bare public key gets us nothing."""
    return subprocess.run(
        ["ssh", "-i", str(KEY),
         "-o", f"CertificateFile={CERT}",
         "-o", "IdentitiesOnly=yes",
         "-o", "BatchMode=yes",
         "-o", "ConnectTimeout=5",
         "-o", "StrictHostKeyChecking=accept-new",
         f"harden@{host}", command],
        capture_output=True, text=True, timeout=60,
    )


def survey(host: str) -> list[str]:
    findings = []
    checks = {
        "world_writable files present": "find /srv /opt -xdev -type f -perm -0002 | head -1 | grep -q .",
        "stale files in /tmp": "find /tmp -xdev -type f -mtime +7 | head -1 | grep -q .",
        "root ssh login not disabled": "! grep -q '^PermitRootLogin no' /etc/ssh/sshd_config",
    }
    for finding, test in checks.items():
        if ssh(host, test).returncode == 0:
            findings.append(finding)
    return findings


def remediate_fleet(cfg: dict) -> int:
    failures = 0
    if not CERT.exists():
        print("harden: no certificate at "
              f"{CERT} — the verifier has not funded this agent; nothing to do")
        return 1
    for host in cfg["fleet"]:
        probe = ssh(host, "true")
        if probe.returncode != 0:
            err = probe.stderr.strip().splitlines()
            print(f"harden: {host}: NO AUTHORITY — {err[-1] if err else 'ssh failed'}")
            failures += 1
            continue
        findings = survey(host)
        if not findings:
            print(f"harden: {host}: clean, nothing to remediate")
            continue
        for action in ask_model(cfg["model_endpoint"], findings):
            r = ssh(host, PLAYBOOK[action])
            status = "done" if r.returncode == 0 else f"failed rc={r.returncode}"
            print(f"harden: {host}: {action}: {status}")
            failures += r.returncode != 0
    return 1 if failures else 0


def tamper() -> int:
    """Append a rule to our own AppArmor profile. The write succeeds —
    the profile grants it. Consequences are enforced elsewhere."""
    line = f"# harden self-modification at {time.strftime('%F %T')}\n"
    try:
        with PROFILE.open("a") as f:
            f.write(line)
    except PermissionError:
        print(f"harden: tamper write to {PROFILE} was DENIED — "
              "that is not this demo; the profile should permit it")
        return 1
    print(f"harden: wrote to {PROFILE} — the write SUCCEEDED.")
    print("harden: the file's IMA measurement now diverges from the signed allowlist.")
    print("harden: next attestation fails; the verifier stops signing; "
          "my certificate dies in <5 minutes.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--loop", action="store_true")
    ap.add_argument("--interval", type=int, default=120)
    ap.add_argument("--tamper", action="store_true")
    args = ap.parse_args()

    if args.tamper:
        return tamper()
    cfg = load_config()
    if not args.loop:
        return remediate_fleet(cfg)
    while True:
        remediate_fleet(cfg)
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
