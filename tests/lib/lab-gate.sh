#!/usr/bin/env bash
# Gate for REAL privileged tests: kernel nft, systemd units, namespaces, mounts,
# genuine ENOSPC. Such a test may run only on a disposable lab host that was
# explicitly prepared for it. Every other host - in particular a production
# TWebProxy server, even when the opt-in variable is set by mistake - gets
# NOT_EXECUTED (exit 77) before any privileged command is attempted.
#
# Lab preparation (on the disposable VM only, see tests/LAB.md):
#   cat /etc/machine-id > /etc/twebproxy-disposable-lab   # as root
#   export TWEBPROXY_LAB_MODE=disposable-vm
#
# The decision uses file tests only. The filesystem root is a function argument
# for the gate's own fixture; scripts always call lab_gate_or_exit, which uses
# the real root, so no environment variable can redirect the checks.

LAB_GATE_MODE_VALUE=disposable-vm
LAB_GATE_MARKER=/etc/twebproxy-disposable-lab
# Present on any host where TWebProxy is (or was) installed.
LAB_GATE_FINGERPRINTS=(
  /etc/twebproxy
  /usr/local/libexec/twebproxy
  /usr/local/sbin/twebproxy
  /opt/twebproxy-manager
  /srv/twebproxy
)

# Prints the refusal reason and returns 1, or returns 0 when authorized.
#   $1 = filesystem root ("" for the real host)  $2 = effective uid
lab_gate_check() {
  local root="$1" uid="$2" path marker id
  if [[ "${TWEBPROXY_LAB_MODE:-}" != "$LAB_GATE_MODE_VALUE" ]]; then
    printf 'TWEBPROXY_LAB_MODE=%s is not set (default runs are model/static only)' "$LAB_GATE_MODE_VALUE"
    return 1
  fi
  for path in "${LAB_GATE_FINGERPRINTS[@]}"; do
    if [[ -e "$root$path" || -L "$root$path" ]]; then
      printf 'TWebProxy fingerprint %s exists: refusing on a possibly productive host' "$path"
      return 1
    fi
  done
  if compgen -G "$root/etc/systemd/system/twebproxy*" >/dev/null; then
    printf 'TWebProxy systemd units exist under /etc/systemd/system: refusing on a possibly productive host'
    return 1
  fi
  marker="$root$LAB_GATE_MARKER"
  if [[ -L "$marker" || ! -f "$marker" ]]; then
    printf 'lab marker %s missing (or not a regular file)' "$LAB_GATE_MARKER"
    return 1
  fi
  if [[ "$(stat -c '%u' -- "$marker" 2>/dev/null)" != 0 ]]; then
    printf 'lab marker %s is not owned by root' "$LAB_GATE_MARKER"
    return 1
  fi
  id="$(head -n1 -- "$root/etc/machine-id" 2>/dev/null)" || id=""
  if [[ ! "$id" =~ ^[0-9a-f]{32}$ || "$(head -n1 -- "$marker" 2>/dev/null)" != "$id" ]]; then
    printf 'lab marker %s does not contain this host machine-id' "$LAB_GATE_MARKER"
    return 1
  fi
  if [[ "$uid" != 0 ]]; then
    printf 'real lab tests need root'
    return 1
  fi
  return 0
}

# For scripts whose whole body is a real test.  $1 = test label.
lab_gate_or_exit() {
  local reason
  if reason="$(lab_gate_check "" "$EUID")"; then
    printf 'LAB_GATE: authorized disposable lab host for %s\n' "$1"
    return 0
  fi
  printf 'NOT_EXECUTED_ENVIRONMENT_LIMITATION %s: %s\n' "$1" "$reason"
  exit 77
}

# For mixed scripts: returns 0 when authorized, else prints the reason.
lab_gate_allows() {
  local reason
  reason="$(lab_gate_check "" "$EUID")" && return 0
  printf '%s' "$reason"
  return 1
}
