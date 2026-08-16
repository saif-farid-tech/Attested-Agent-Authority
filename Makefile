# attested-agent-authority — the only interface most users need.
# Every target delegates to a script in scripts/; all of them run on the
# host and reach into instances themselves. Never open a shell in a VM.

SHELL := /bin/bash
CONSOLE_PORT ?= 9000

.PHONY: help preflight build verify demo rebaseline console measure reset teardown doctor selftest

help:
	@echo "attested-agent-authority"
	@echo
	@echo "  make preflight    environment checks only (changes nothing)"
	@echo "  make build        full build from scratch (~20 min), ends at a passing verify"
	@echo "  make doctor       one-shot health check of the whole chain (run this when stuck)"
	@echo "  make selftest     check the scripts and the verifier logic (no LXD needed)"
	@echo "  make verify       run the six-stage attestation diagnostic"
	@echo "  make demo         run/RESTART the demo — resets to a clean state first"
	@echo "  make reset        return to the clean, passing state (cold-boot restore)"
	@echo "  make console      serve the UI on :$(CONSOLE_PORT) and start the verifier loop"
	@echo "  make measure      exposure-window experiment, CSV out"
	@echo "  make rebaseline   ONLY after you EDIT the agent — re-freezes the allowlist"
	@echo "  make teardown     remove everything this project created"
	@echo
	@echo "  to restart the demo: just run 'make demo' again (or 'make reset')."
	@echo "  do NOT use 'make rebaseline' to restart — it re-freezes the baseline."

preflight:
	scripts/00-preflight.sh

build: preflight
	scripts/10-network.sh
	scripts/20-workload.sh
	scripts/30-tpm-keys.sh
	scripts/40-apparmor.sh
	scripts/50-agent.sh
	scripts/60-fleet.sh
	scripts/70-baseline.sh
	@echo
	@echo "build complete — snapshot 'demo-ready' taken."
	@echo "next: 'make console' in one terminal, 'make demo' in another."

doctor:
	scripts/doctor.sh

# Runs anywhere — no LXD, no VM, no TPM. Catches the class of bug that used to
# be found only halfway through a recording: a shell script that parses wrong,
# and the measurement-log logic the restart depends on.
selftest:
	@for f in scripts/*.sh scripts/lib/*.sh; do bash -n "$$f" || exit 1; done
	@echo "  ok  all shell scripts parse"
	@python3 -m py_compile agent/agent.py verifier/*.py
	@echo "  ok  python sources compile"
	@python3 tests/test_imalog.py
	@python3 tests/test_restart_scenario.py

verify:
	scripts/80-verify.sh

demo:
	scripts/90-demo.sh

# bug #10: editing agent.py (or anything the VM executes) changes its IMA
# hash. That is IMA doing its job — the fix is to re-baseline, not to fight it.
rebaseline:
	scripts/70-baseline.sh

console:
	@echo "console: http://localhost:$(CONSOLE_PORT)  (Ctrl-C stops verifier + console)"
	@trap 'kill 0' EXIT INT TERM; \
	  python3 verifier/verifier.py & \
	  python3 -m http.server $(CONSOLE_PORT) --directory console

measure:
	scripts/measure-exposure.sh

reset:
	scripts/reset.sh

teardown:
	scripts/teardown.sh
