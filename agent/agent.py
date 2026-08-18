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
# The remediation catalogue. Each entry is a fixed, auditable action with a
# detector (is it wrong?) and a fix (make it right). The model chooses which
# to apply from the ones that actually flag; it cannot invent shell commands.
# Every fix is idempotent, so re-running is safe. See docs/LIMITS.md — this
# narrows the blast radius of a bad completion, it does not solve injection.
PLAYBOOK = {
    "world_writable": {
        "finding": "world-writable files under /srv or /opt",
        "detect": "find /srv /opt -xdev -type f -perm -0002 | head -1 | grep -q .",
        "fix": "sudo find /srv /opt -xdev -type f -perm -0002 -exec chmod o-w {} +",
    },
    "secret_readable": {
        "finding": "credentials file world-readable",
        "detect": "find /etc/app -xdev -name '*.env' -perm -0044 2>/dev/null | head -1 | grep -q .",
        "fix": "sudo find /etc/app -xdev -name '*.env' -exec chmod 600 {} +",
    },
    "stale_tmp": {
        "finding": "stale files older than 7 days in /tmp",
        "detect": "find /tmp -xdev -type f -mtime +7 | head -1 | grep -q .",
        "fix": "sudo find /tmp -xdev -type f -mtime +7 -delete",
    },
    "ssh_root_login": {
        "finding": "root SSH login not disabled",
        "detect": "! grep -q '^PermitRootLogin no' /etc/ssh/sshd_config",
        "fix": ("sudo sed -i '/^PermitRootLogin/d' /etc/ssh/sshd_config && "
                "echo 'PermitRootLogin no' | sudo tee -a /etc/ssh/sshd_config >/dev/null"),
    },
    "ssh_password_auth": {
        "finding": "SSH password authentication still enabled",
        "detect": "! grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config",
        "fix": ("sudo sed -i '/^PasswordAuthentication/d' /etc/ssh/sshd_config && "
                "echo 'PasswordAuthentication no' | sudo tee -a /etc/ssh/sshd_config >/dev/null"),
    },
}


def load_config() -> dict:
    try:
        return json.loads(CONFIG.read_text())
    except FileNotFoundError:
        sys.exit(f"harden: no config at {CONFIG} (deployed by scripts/50-agent.sh)")
    except PermissionError:
        sys.exit(f"harden: cannot read {CONFIG} — it must be readable by the "
                 "harden user; re-run scripts/50-agent.sh to fix its permissions")


def ask_model(endpoint: str, applicable: list[str]) -> list[str]:
    """Ask the model which of the flagged actions to apply. Degrades
    gracefully: a model that is down or empty-handed is a normal condition
    (bug #8), reported in one sentence — never a stack trace. The fallback is
    to apply everything the survey flagged, so the fleet still gets fixed."""
    if not applicable:
        return []
    prompt = (
        "You are a security remediation planner. A host survey flagged these "
        "problems, each with the catalogue action that fixes it:\n"
        + "\n".join(f"- {a}: {PLAYBOOK[a]['finding']}" for a in applicable)
        + "\nReply with a JSON array of the action names to apply, chosen only "
        "from: " + ", ".join(applicable) + "\n"
    )
    body = json.dumps({"prompt": prompt, "n_predict": 64, "temperature": 0}).encode()
    try:
        req = urllib.request.Request(
            endpoint, data=body, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode().strip()
    except (urllib.error.URLError, OSError, TimeoutError):
        print(f"harden: model endpoint {endpoint} unreachable — "
              "applying every flagged fix")
        return applicable
    if not raw:
        # json.loads("") raises — and a down model must never look like a crash
        print(f"harden: model endpoint {endpoint} returned nothing — "
              "applying every flagged fix")
        return applicable
    try:
        content = json.loads(raw).get("content", "")
        start, end = content.find("["), content.rfind("]")
        chosen = json.loads(content[start:end + 1])
        picked = [a for a in chosen if a in applicable]
        return picked or applicable
    except (ValueError, AttributeError):
        print(f"harden: could not parse the reply from {endpoint} — "
              "applying every flagged fix")
        return applicable


def ssh(host: str, command: str) -> subprocess.CompletedProcess:
    """Run a command on a fleet host. Authority = key + short-lived certificate.
    sshd on the fleet trusts only certificates signed by the verifier's CA
    (TrustedUserCAKeys); a bare public key gets us nothing."""
    try:
        return subprocess.run(
            ["ssh", "-i", str(KEY),
             "-o", f"CertificateFile={CERT}",
             "-o", "IdentitiesOnly=yes",
             "-o", "BatchMode=yes",
             "-o", "ConnectTimeout=5",
             # Fleet hosts are ephemeral demo containers whose host keys change on
             # rebuild; the security here is US proving identity to THEM with a
             # CA-signed certificate, not verifying their host key. Keep the demo
             # reproducible across rebuilds by not pinning their host keys.
             "-o", "StrictHostKeyChecking=no",
             "-o", "UserKnownHostsFile=/dev/null",
             "-o", "LogLevel=ERROR",
             f"harden@{host}", command],
            capture_output=True, text=True, timeout=60,
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(
            args=["ssh", host], returncode=124,
            stdout="", stderr=f"ssh to {host} timed out after 60s")
    except OSError as e:
        return subprocess.CompletedProcess(
            args=["ssh", host], returncode=1,
            stdout="", stderr=str(e))


def survey(host: str) -> list[str]:
    """Return the catalogue actions whose detector fires on this host."""
    return [name for name, item in PLAYBOOK.items()
            if ssh(host, item["detect"]).returncode == 0]


def remediate_fleet(cfg: dict) -> int:
    failures = 0
    fixed_total = 0
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

        applicable = survey(host)
        if not applicable:
            print(f"harden: {host}: audit clean — nothing to remediate")
            continue
        print(f"harden: {host}: audit found {len(applicable)} issue(s): "
              + ", ".join(PLAYBOOK[a]["finding"] for a in applicable))

        plan = ask_model(cfg["model_endpoint"], applicable)
        for action in plan:
            r = ssh(host, PLAYBOOK[action]["fix"])
            if r.returncode != 0:
                print(f"harden: {host}: {action}: FAILED rc={r.returncode}")
                failures += 1
                continue
            # verify the fix actually cleared the finding (writing is not success)
            still = ssh(host, PLAYBOOK[action]["detect"]).returncode == 0
            if still:
                print(f"harden: {host}: {action}: ran but still flags — investigate")
                failures += 1
            else:
                print(f"harden: {host}: {action}: fixed ({PLAYBOOK[action]['finding']})")
                fixed_total += 1
    if fixed_total:
        print(f"harden: remediation pass complete — {fixed_total} issue(s) fixed "
              "across the fleet")
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
          "my certificate expires shortly and will not be renewed.")
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
