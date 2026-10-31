#!/bin/bash
# Actual installed units on the owner-marked disposable guest, never live nodes.
set -Eeuo pipefail
case "$(hostname)" in prerc-v026-lab|prerc-v026-clean) ;; *) exit 90;; esac
cmp -s /etc/machine-id /etc/twebproxy-disposable-lab || exit 91
host=${1:?fixture hostname}
[[ $host == upgrade-lab.invalid || $host == clean-lab.invalid ]] || exit 92
unit="twebproxy-mtproxy@$host--default.service"
systemctl is-active --quiet "$unit" "twebproxy@$host.service"
systemctl show "$unit" -p ActiveState -p NRestarts -p IPAddressDeny -p IPAddressAllow -p IPIngressBytes
pid=$(systemctl show "$unit" -p MainPID --value)
[[ $pid =~ ^[1-9][0-9]*$ ]]
if runuser -u nobody -- test -r "/proc/$pid/cmdline"; then
  echo UNPRIVILEGED_BACKEND_CMDLINE_READABLE=FAIL; exit 1
fi
echo UNPRIVILEGED_SECRET_PROTECTION=PASS
ss -H -ltn
/usr/local/sbin/twebproxy audit "$host" --json
echo REAL_BACKEND_ISOLATION_AUDIT_RC=0

# Remove the required deny policy only while the backend is proven stopped.
# ExecStartPre must refuse the restart before MTProxy can run.
override="/run/systemd/system/$unit.d/99-prerc-v026-test.conf"
[[ ! -e $override ]]
restore() {
  rm -f -- "$override"
  rmdir "${override%/*}" 2>/dev/null || true
  systemctl daemon-reload
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  systemctl start "$unit"
}
trap restore EXIT
systemctl stop "$unit"
[[ $(systemctl show "$unit" -p MainPID --value) == 0 ]]
mkdir -p "${override%/*}"
printf '[Service]\nIPAddressDeny=\n' > "$override"
systemctl daemon-reload
rc=0; systemctl start "$unit" || rc=$?
[[ $rc != 0 && $(systemctl show "$unit" -p MainPID --value) == 0 ]]
printf 'MISSING_IP_POLICY_START_REFUSED_RC=%s\n' "$rc"
echo MISSING_IP_POLICY_NO_BACKEND_PROCESS=PASS
restore
trap - EXIT
systemctl is-active --quiet "$unit"

old_pid=$(systemctl show "$unit" -p MainPID --value)
restarts=$(systemctl show "$unit" -p NRestarts --value)
systemctl kill --kill-whom=main --signal=KILL "$unit"
for ((i=0;i<45;i++)); do
  current=$(systemctl show "$unit" -p MainPID --value)
  if [[ $current != 0 && $current != "$old_pid" ]] && systemctl is-active --quiet "$unit"; then break; fi
  sleep 1
done
[[ $current != 0 && $current != "$old_pid" ]]
after_restarts=$(systemctl show "$unit" -p NRestarts --value)
(( after_restarts > restarts ))
printf 'BACKEND_AUTO_RECOVERY=PASS NRestarts=%s->%s\n' "$restarts" "$after_restarts"

profile="/etc/twebproxy/instances/$host/profiles.d/default.env"
secret_before=$(grep '^SECRET=' "$profile" | sha256sum)
modes=(https https-lanes websocket websocket-lanes)
for i in 1 2 3 4; do
  printf '%s\n' "$i" | /usr/local/sbin/twebproxy profile-carrier "$host" default
  grep -qx "CARRIER_MODE=${modes[$((i-1))]}" "$profile"
  systemctl is-active --quiet "twebproxy@$host.service" "$unit"
  printf 'CARRIER_CONFIG_READY=%s PASS (application NOT_EXECUTED)\n' "${modes[$((i-1))]}"
done
printf '1\n' | /usr/local/sbin/twebproxy profile-carrier "$host" default
[[ $(grep '^SECRET=' "$profile" | sha256sum) == "$secret_before" ]]
echo CARRIER_SECRET_PRESERVED=PASS
systemctl is-active --quiet ssh
echo INSTALLED_INVARIANTS_SSH_PRESERVED=PASS
