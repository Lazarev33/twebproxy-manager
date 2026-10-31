#!/usr/bin/env bash
# REAL-HOST harness (v0.2.23 pre-RC corrections): P1-INHERITED-01. Can an
# unrelated unprivileged local account recover the MTProxy client secret (the
# `-S` argument) of a running backend from procfs? Prints booleans only; the
# argument value is never printed or stored. Read-only.
# Runs only with TWEBPROXY_PRERC_REAL=installed-test-host (else exit 77).
set -u
source "$(dirname "${BASH_SOURCE[0]}")/../lib/lab-gate.sh"
installed_host_gate_or_exit prerc-proc-secret
pids=($(pgrep -x mtproto-proxy)); (( ${#pids[@]} )) || { echo "FAIL no running backend"; exit 1; }
echo "procfs options: $(findmnt -no OPTIONS /proc)"
exposed=0
for user in www-data nobody caddy; do
  id "$user" >/dev/null 2>&1 || { echo "reader $user: absent, skipped"; continue; }
  uid=$(id -u "$user"); gid=$(id -g "$user")
  for p in "${pids[@]}"; do
    vis=$(setpriv --reuid="$uid" --regid="$gid" --clear-groups cat "/proc/$p/cmdline" 2>/dev/null | tr '\0' '\n' | grep -A1 -x -- '-S' | tail -1 | grep -Ecx '[0-9a-f]{32}')
    listed=$(setpriv --reuid="$uid" --regid="$gid" --clear-groups sh -c "test -d /proc/$p && echo yes || echo no")
    printf 'reader=%-9s pid=%s pid_visible=%s secret_readable=%s\n' "$user" "$p" "$listed" "$([[ $vis == 1 ]] && echo YES || echo no)"
    [[ $vis == 1 ]] && exposed=$((exposed+1))
  done
done
echo "root still sees backends: $(ls -d /proc/[0-9]* | wc -l) pids visible to root; secret exposures to unprivileged readers: $exposed"
(( exposed == 0 ))
