#!/usr/bin/env bash
# REAL-HOST harness (v0.2.23): the owned guard table is the SAME kernel object
# (same table handle, same owning nft session PID) across every nftables.service
# transition - i.e. it is never deleted and re-created, so there is no gap.
# Runs only with TWEBPROXY_PRERC_REAL=installed-test-host.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/../lib/lab-gate.sh"
installed_host_gate_or_exit prerc-guard-continuity
handle() { nft -j list tables 2>/dev/null | jq -r '.nftables[] | select(.table) | .table | select(.name=="twebproxy_guard") | .handle'; }
owner() { pgrep -P "$(systemctl show -p MainPID --value twebproxy-firewall.service)" -x nft; }
h0=$(handle); o0=$(owner); fail=0
echo "start: guard handle=$h0 owner_nft_pid=$o0"
for a in start reload restart stop; do
  systemctl "$a" nftables.service; h=$(handle); o=$(owner)
  same=$([[ -n "$h0" && "$h" == "$h0" && "$o" == "$o0" ]] && echo yes || echo NO)
  printf 'after nftables %-8s guard handle=%s owner=%s same_object=%s\n' "$a" "${h:-absent}" "${o:-none}" "$same"
  [[ $same == yes ]] || fail=1
done
echo "VERDICT: $([[ $fail == 0 ]] && echo PASS || echo FAIL)"; exit $fail
