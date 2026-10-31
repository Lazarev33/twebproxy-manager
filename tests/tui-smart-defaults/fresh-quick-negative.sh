#!/bin/bash
# Destructive fixture ONLY inside a newly created disposable guest.
set -Eeuo pipefail
[[ $(hostname) == tui-smart-clean && $(cat /proc/1/comm) == systemd ]] || exit 90
[[ ! -e /etc/twebproxy && ! -e /usr/local/bin/tproxy-server ]] || exit 91
src=${1:-/root/ux-source}
export TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 PYTHONDONTWRITEBYTECODE=1 NO_COLOR=1
rc=0
printf 'smart-ui.invalid\n' | bash "$src/twebproxy-manager.sh" tui-internal quick-add || rc=$?
[[ $rc == 1 && ! -e /etc/twebproxy && ! -e /usr/local/bin/tproxy-server ]]
printf 'FRESH_DNS_REFUSAL_RC=%s\nFRESH_DNS_NO_MUTATION=PASS\n' "$rc"
! ss -H -ltn '( sport = :443 )' | grep -q .
python3 -m http.server 443 --bind 127.0.0.1 >/root/ux-conflict-private.log 2>&1 &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true' EXIT
for ((i=0;i<30;i++)); do
  ss -H -ltn '( sport = :443 )' | grep -q . && break
  sleep 0.1
done
ss -H -ltn '( sport = :443 )' | grep -q .
rc=0
printf 'smart-ui.invalid\n' | bash "$src/twebproxy-manager.sh" tui-internal quick-add || rc=$?
[[ $rc == 1 && ! -e /etc/twebproxy && ! -e /usr/local/bin/tproxy-server ]]
kill -0 "$fixture_pid"
printf 'FRESH_LISTENER_REFUSAL_RC=%s\nFRESH_UNRELATED_LISTENER_PRESERVED=PASS\n' "$rc"
systemctl is-active --quiet ssh
echo FRESH_SSH_PRESERVED=PASS
