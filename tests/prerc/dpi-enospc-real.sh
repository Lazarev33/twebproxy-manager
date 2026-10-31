#!/usr/bin/env bash
# REAL-HOST harness (v0.2.23 pre-RC corrections): DPI state truthfulness under a
# real ENOSPC. /etc/twebproxy/dpi is overmounted with a 16 KiB tmpfs that holds a
# copy of the state and is then filled; `dpi set` must either keep the kernel in
# the previous mode it claims to have restored, or report the real (incomplete)
# outcome. After the tmpfs is removed, `dpi status` and the kernel must agree.
# Ends at STOCK. Runs only with TWEBPROXY_PRERC_REAL=installed-test-host.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/../lib/lab-gate.sh"
installed_host_gate_or_exit prerc-dpi-enospc
H="${1:?host}"; d=/etc/twebproxy/dpi
kmode() { local r; r=$(nft list table ip twebproxy_dpi 2>/dev/null | grep -o 'comment "twebproxy:[^"]*"' | sed -E 's/.*:([a-z0-9_]+)"$/\1/' | sort -u | tr '\n' '+'); r=${r%+}; case "$r" in "") echo stock;; window1152+nfqws|nfqws+window1152) echo window1152_nfqws;; mss88+nfqws|nfqws+mss88) echo mss88_nfqws;; *) echo "$r";; esac; }
smode() { twebproxy --raw dpi status "$H" 2>/dev/null | grep -m1 -oiE '(mode|режим)[^a-z0-9_]*[a-z0-9_]+' | awk '{print tolower($NF)}' ; }
smode2() { twebproxy dpi status "$H" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^(Mode|Режим)' | head -1 | awk '{print tolower($NF)}'; }
twebproxy dpi set "$H" window1152 --accept-shared-scope >/dev/null 2>&1
echo "before: kernel=$(kmode) status=$(smode2)"
work=$(mktemp -d); cp -a "$d/." "$work/"
mount -t tmpfs -o size=16k,mode=0700 tmpfs "$d"; cp -a "$work/." "$d/" 2>/dev/null; dd if=/dev/zero of="$d/.fill" bs=1k count=64 2>/dev/null
twebproxy dpi set "$H" mss88 --accept-shared-scope > "$work/out" 2>&1; rc=$?
msg=$(sed 's/\x1b\[[0-9;]*m//g' "$work/out" | grep -E 'НЕ удалось|could NOT be restored|DPI_(RESULT|INCOMPLETE)|восстановлен|restored|INCOMPLETE|незаверш' | tail -2 | tr '\n' ' ')
k_during=$(kmode)
umount "$d"; rm -f "$d/.fill"
k_after=$(kmode); s_after=$(smode2)
echo "dpi set mss88 under ENOSPC: rc=$rc kernel_during=$k_during"
echo "   messages: $msg"
echo "after tmpfs removed: kernel=$k_after status=$s_after"
claims_restored=0; grep -qiE 'предыдущее состояние восстановлено|previous state was restored|previous exact state was restored' "$work/out" && claims_restored=1
v=PASS
(( rc != 0 )) || v=FAIL
if (( claims_restored )) && [[ "$k_during" != window1152 ]]; then v=FAIL; echo "   FALSE CLAIM: restored reported, kernel=$k_during"; fi
if [[ "$k_after" != "$s_after" ]]; then
  if twebproxy dpi status "$H" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -qE 'DO NOT match|НЕ совпадают'; then
    echo "   status reports the divergence explicitly (recorded=$s_after kernel=$k_after)"
  else v=FAIL; echo "   SILENT DIVERGENCE: status=$s_after kernel=$k_after"; fi
fi
twebproxy dpi disable "$H" >/dev/null 2>&1; echo "cleanup: kernel=$(kmode) status=$(smode2)"; rm -rf "$work"
echo "VERDICT: $v"; [[ $v == PASS ]]
