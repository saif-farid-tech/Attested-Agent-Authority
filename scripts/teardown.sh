#!/usr/bin/env bash
# teardown.sh — Phase 0. Remove all project state from the host.
#
# Safe to run when nothing exists; prints what it removed and what was
# already absent. Never touches ~/.ssh, ~/.gnupg, or anything under
# ~/salvage/ — those are the user's personal keys and rescued data.

cd "$(dirname "$0")/.." || exit 1
source scripts/lib/common.sh
guard_host

removed=(); absent=()

note_removed() { removed+=("$1"); ok "removed  $1"; }
note_absent()  { absent+=("$1");  log "absent   $1"; }

# ---- LXD instances and network --------------------------------------------
if command -v lxc >/dev/null 2>&1; then
  for inst in "$AAA_VM" "${AAA_FLEET[@]}"; do
    if instance_exists "$inst"; then
      lxc delete "$inst" --force
      note_removed "LXD instance $inst"
    else
      note_absent "LXD instance $inst"
    fi
  done
  if lxc network show "$AAA_NET" >/dev/null 2>&1; then
    lxc network delete "$AAA_NET"
    note_removed "LXD network $AAA_NET"
  else
    note_absent "LXD network $AAA_NET"
  fi
else
  warn "lxc not installed — no LXD state to remove"
  absent+=("all LXD instances and networks (lxc not installed)")
fi

# ---- host directories ------------------------------------------------------
for dir in /var/lib/harden "$HOME/attested-agent"; do
  # Refuse to remove anything that could be personal. Belt and braces: these
  # paths are constants, but check anyway before rm -rf.
  case "$dir" in
    "$HOME/.ssh"*|"$HOME/.gnupg"*|"$HOME/salvage"*)
      die "refusing to delete $dir" "protected personal path" ;;
  esac
  if [ -e "$dir" ]; then
    if [ -w "$(dirname "$dir")" ]; then rm -rf "$dir"; else sudo rm -rf "$dir"; fi
    note_removed "$dir"
  else
    note_absent "$dir"
  fi
done

# ---- stray AppArmor profile on the HOST ------------------------------------
# A previous manual run installed the workload's profile on the laptop by
# mistake. It belongs inside the VM only.
if [ -e /etc/apparmor.d/harden ]; then
  sudo apparmor_parser -R /etc/apparmor.d/harden 2>/dev/null || true
  sudo rm -f /etc/apparmor.d/harden
  note_removed "/etc/apparmor.d/harden (host — should never have been there)"
else
  note_absent "/etc/apparmor.d/harden (host)"
fi

# ---- verify the machine is clean ------------------------------------------
if command -v lxc >/dev/null 2>&1; then
  leftovers=$(lxc list -f csv -c n 2>/dev/null | grep -Ex "$AAA_VM|web-01|db-01|gw-01" || true)
  [ -z "$leftovers" ] || die "instances still present after teardown: $leftovers" \
      "lxc delete failed silently" "lxc delete --force $leftovers"
  if lxc network list -f csv 2>/dev/null | cut -d, -f1 | grep -qx "$AAA_NET"; then
    die "network $AAA_NET still present" "network delete failed" \
        "lxc network delete $AAA_NET"
  fi
fi
[ ! -e /var/lib/harden ] && [ ! -e "$HOME/attested-agent" ] || \
  die "host directories still present" "rm failed" \
      "sudo rm -rf /var/lib/harden ~/attested-agent"

echo
log "teardown complete: ${#removed[@]} removed, ${#absent[@]} already absent"
ok  "machine is clean — proceed with scripts/00-preflight.sh"
