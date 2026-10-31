#!/bin/bash
# Destructive cleanup of ONLY the disposable guests created for these tests.
set -Eeuo pipefail
case "$(hostname)" in prerc-v026-lab|prerc-v026-clean) ;; *) exit 90;; esac
cmp -s /etc/machine-id /etc/twebproxy-disposable-lab || exit 91
host=${1:?fixture hostname}
[[ $host == upgrade-lab.invalid || $host == clean-lab.invalid ]] || exit 92
src=${2:-/root/candidate26}
printf 'y\n' | /usr/local/sbin/twebproxy delete "$host"
printf 'y\n' | /usr/local/sbin/twebproxy core-uninstall
[[ ! -d /etc/twebproxy && -x /usr/local/sbin/twebproxy ]]
! nft list table inet twebproxy_backend >/dev/null 2>&1
! nft list table inet twebproxy_guard >/dev/null 2>&1
systemctl is-active --quiet ssh
echo NORMAL_UNINSTALL_MANAGER_RETAINED_SSH_PRESERVED=PASS

# These paths did not exist on the pristine test image. Remove the Manager's
# deliberately retained test-only files after checking normal uninstall first.
rm -f /usr/local/sbin/twebproxy
rm -rf /opt/twebproxy-manager /usr/local/libexec/twebproxy /srv/twebproxy
find /etc/systemd/system -maxdepth 1 -type d -name 'twebproxy*' -empty -delete
systemctl daemon-reload
export TWEBPROXY_LAB_MODE=disposable-vm TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1
bash "$src/tests/stagea/sa1-real-nft-validation.sh"
echo REAL_DPI_KERNEL_COMMIT_JSON_VERIFICATION_RC=0
systemctl is-active --quiet ssh
echo DISPOSABLE_CLEANUP_SSH_PRESERVED=PASS
