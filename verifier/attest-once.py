#!/usr/bin/env python3
"""attest-once.py — one attestation cycle, six stages, honest exit codes.

Runs on the HOST. Stops at the first failing stage with a specific remedy.

  exit 0  full pass
  exit 2  ATTESTATION failure — the system is working; the workload's
          measured state does not match the signed allowlist
  exit 1  setup failure — something in the plumbing is broken

The distinction matters. A 2 during the demo is the success condition.
"""

import base64
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

STATE = Path(os.environ.get("AAA_STATE", Path.home() / "attested-agent"))
VM_ADDR = os.environ.get("AAA_VM_ADDR", "10.147.0.10")
SSH_KEY = STATE / "workload_ed25519"
AK_PUB = STATE / "ak.pub"
ALLOWLIST = STATE / "allowlist.txt"
SSH_CA = STATE / "ssh_ca"
AK_HANDLE = "0x81010002"
IMA_LOG = "/sys/kernel/security/ima/ascii_runtime_measurements"

SETUP_FAIL, ATTEST_FAIL = 1, 2


class StageFailure(Exception):
    def __init__(self, code, what, remedy):
        super().__init__(what)
        self.code, self.what, self.remedy = code, what, remedy


def ssh(command: str, binary: bool = False) -> bytes | str:
    r = subprocess.run(
        ["ssh", "-i", str(SSH_KEY), "-o", "BatchMode=yes",
         "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new",
         f"attest@{VM_ADDR}", command],
        capture_output=True, timeout=60)
    if r.returncode != 0:
        raise StageFailure(
            SETUP_FAIL,
            f"ssh to attest@{VM_ADDR} failed: {r.stderr.decode().strip() or 'no output'}",
            "scripts/20-workload.sh  # re-establishes the attest user and key")
    return r.stdout if binary else r.stdout.decode()


# ---- stages ----------------------------------------------------------------

def stage1_local_state(report):
    missing = [str(p) for p in (AK_PUB, ALLOWLIST, SSH_CA) if not p.exists()]
    if missing:
        raise StageFailure(SETUP_FAIL, f"missing verifier state: {', '.join(missing)}",
                           "scripts/30-tpm-keys.sh creates ak.pub; "
                           "scripts/60-fleet.sh creates ssh_ca; "
                           "scripts/70-baseline.sh creates allowlist.txt")
    entries = len(ALLOWLIST.read_text().splitlines())
    if entries == 0:
        raise StageFailure(SETUP_FAIL, "allowlist.txt is empty",
                           "scripts/70-baseline.sh  # regenerates it")
    if entries > 2000:
        report(f"  warn: {entries} allowlist entries — expected ~650–1100; "
               "check for ima_policy=tcb on the kernel line (bug #3)")
    for tool in ("ssh", "tpm2_checkquote", "ssh-keygen"):
        if not shutil.which(tool):
            raise StageFailure(SETUP_FAIL, f"'{tool}' not on PATH",
                               "sudo apt install tpm2-tools openssh-client")
    return f"ak.pub, ssh_ca, allowlist ({entries} entries), tools present"


def stage2_ssh(report):
    ssh("true")
    r = ssh("sudo -n true && echo SUDO_OK")
    if "SUDO_OK" not in r:
        raise StageFailure(SETUP_FAIL, "passwordless sudo not working for attest",
                           "scripts/20-workload.sh  # reinstalls /etc/sudoers.d/attest")
    return f"key auth and passwordless sudo confirmed on {VM_ADDR}"


def stage3_ima_log(report):
    # the redirect must happen inside the root shell — the log is root-only
    out = ssh(f"sudo -n sh -c 'wc -l < {IMA_LOG}'")
    lines = int(out.strip() or 0)
    if lines == 0:
        raise StageFailure(SETUP_FAIL, "IMA measurement log is empty",
                           "scripts/20-workload.sh  # policy install + reboot")
    return f"IMA log readable, {lines} measurements"


def stage4_quote(report, workdir):
    nonce = secrets.token_hex(20)
    # One round trip, everything as root inside a single `sudo sh -c`:
    # tpm2_quote writes the artefacts owned by root, so tar must ALSO run as
    # root to read them — packaging as the login user came back missing files.
    # base64 keeps the binary intact over ssh. Failures inside the && chain
    # propagate as the command's exit code, so ssh() reports them cleanly.
    remote = ("sudo -n sh -c 'd=$(mktemp -d) && cd \"$d\" && "
              f"tpm2_quote -c {AK_HANDLE} -l sha256:10 -q {nonce} "
              "-m q.msg -s q.sig -o q.pcrs -g sha256 >/dev/null && "
              "tar -cf - q.msg q.sig q.pcrs | base64'")
    blob = ssh(remote, binary=True)

    raw = base64.b64decode(blob) if blob.strip() else b""
    if not raw:
        raise StageFailure(
            SETUP_FAIL, "the workload returned an empty TPM quote",
            "confirm the vTPM works: lxc exec harden -- tpm2_pcrread sha256:10 ; "
            "then scripts/30-tpm-keys.sh to recreate the AK")
    (workdir / "quote.tar").write_bytes(raw)
    extract = subprocess.run(
        ["tar", "-xf", str(workdir / "quote.tar"), "-C", str(workdir)],
        capture_output=True, text=True)
    missing = [f for f in ("q.msg", "q.sig", "q.pcrs")
               if not (workdir / f).exists() or not (workdir / f).stat().st_size]
    if extract.returncode != 0 or missing:
        raise StageFailure(
            SETUP_FAIL,
            f"quote artefacts did not return intact (missing: {', '.join(missing) or 'archive unreadable'})",
            "usually the vTPM or the AK: scripts/30-tpm-keys.sh to recreate the AK")
    return nonce, f"fresh quote over PCR 10, nonce {nonce[:16]}…"


def stage5_checkquote(report, workdir, nonce):
    r = subprocess.run(
        ["tpm2_checkquote", "-u", str(AK_PUB),
         "-m", str(workdir / "q.msg"), "-s", str(workdir / "q.sig"),
         "-f", str(workdir / "q.pcrs"), "-g", "sha256", "-q", nonce],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise StageFailure(ATTEST_FAIL,
                           f"tpm2_checkquote rejected the quote: {r.stderr.strip()}",
                           "if unexpected: scripts/30-tpm-keys.sh to re-export ak.pub")
    return "quote signature valid against ak.pub; PCR digest matches"


def stage6_allowlist(report):
    allowed = set()
    for line in ALLOWLIST.read_text().splitlines():
        if line.strip():
            allowed.add(line.split()[0])
    offenders = []
    # bug #5: IMA writes 'sha256:<hash>'; the allowlist holds bare hashes.
    # Strip the prefix here or nothing ever matches.
    for line in ssh(f"sudo -n cat {IMA_LOG}").splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        fhash = parts[3].split(":", 1)[-1]
        if fhash and fhash not in allowed:
            offenders.append(f"{fhash[:16]}…  {parts[4]}")
    if offenders:
        shown = "\n           ".join(offenders[:5])
        more = f" (+{len(offenders) - 5} more)" if len(offenders) > 5 else ""
        raise StageFailure(ATTEST_FAIL,
                           f"{len(offenders)} measurement(s) not on the signed allowlist:"
                           f"\n           {shown}{more}",
                           "if this is a legitimate change: make rebaseline")
    return f"every measurement recognised ({len(allowed)} allowlist entries)"


def attest(report=print):
    """Run all six stages. Returns (exit_code, reason, offender_count)."""
    workdir = Path(tempfile.mkdtemp(prefix="attest-"))
    stages = 0
    try:
        for i, (name, fn) in enumerate([
            ("local verifier state", stage1_local_state),
            ("ssh to workload", stage2_ssh),
            ("ima log", stage3_ima_log),
        ], 1):
            msg = fn(report)
            report(f"  [{i}/6] {name}: {msg}")
            stages = i
        nonce, msg = stage4_quote(report, workdir)
        report(f"  [4/6] tpm quote: {msg}")
        report(f"  [5/6] quote verification: {stage5_checkquote(report, workdir, nonce)}")
        report(f"  [6/6] allowlist: {stage6_allowlist(report)}")
        return 0, "Measurements match the signed allowlist.", 0
    except StageFailure as e:
        kind = "ATTESTATION FAILURE" if e.code == ATTEST_FAIL else "setup failure"
        report(f"  fail after stage {stages}: {kind}")
        report(f"       what: {e.what}")
        report(f"       remedy: {e.remedy}")
        if e.code == ATTEST_FAIL:
            report("       note: an attestation failure is the system WORKING.")
        return e.code, e.what, 0
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    code, _, _ = attest()
    sys.exit(code)
