#!/bin/bash
# Run ONLY on the freshly created, owner-marked disposable pre-RC guest.
set -Eeuo pipefail
[[ $(hostname) == prerc-v026-lab && $(cat /proc/1/comm) == systemd ]] || exit 90
[[ -f /etc/twebproxy-disposable-lab ]] || exit 91
cmp -s /etc/machine-id /etc/twebproxy-disposable-lab || exit 91
src=${1:-/root/candidate26}
cd "$src"
export TWEBPROXY_LAB_MODE=disposable-vm TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1
date -u --iso-8601=seconds
uname -r
nft --version
systemctl --version | head -n 1
awk '/CapEff/{print}' /proc/self/status
systemctl list-units --no-legend >/dev/null
nft list tables
for script in tests/stageb/real-nft-validation.sh tests/stageb/real-systemd-validation.sh tests/fieldgate/tg1-real-nft-six-mode-gate.sh; do
  printf '\nCOMMAND bash %s\n' "$script"
  rc=0; timeout 300 bash "$script" || rc=$?
  printf 'RETURN_CODE %s %s\n' "$script" "$rc"
  (( rc == 0 )) || exit "$rc"
done
systemctl is-active --quiet ssh
echo CLEAN_KERNEL_SSH_PRESERVED=PASS
