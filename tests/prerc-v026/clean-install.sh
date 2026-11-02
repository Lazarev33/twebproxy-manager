#!/bin/bash
# Fresh disposable Ubuntu guest only. No public DNS/ACME acceptance is claimed.
set -Eeuo pipefail
[[ $(hostname) == prerc-v026-clean && $(cat /proc/1/comm) == systemd ]] || exit 90
[[ ! -e /etc/twebproxy && ! -e /usr/local/bin/tproxy-server ]] || exit 91
export TWEBPROXY_UI_LANGUAGE=ru TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 NO_COLOR=1
export GOMAXPROCS=1 GOFLAGS=-p=1
src=${1:-/root/candidate26}
date -u --iso-8601=seconds
uname -r
awk '/CapEff/{print}' /proc/self/status
systemctl list-units --no-legend >/dev/null
nft list tables
rc=0
printf 'clean-lab.invalid\n' | bash "$src/twebproxy-manager.sh" tui-internal quick-add || rc=$?
[[ $rc == 1 && ! -e /etc/twebproxy && ! -e /usr/local/bin/tproxy-server ]]
echo QUICK_UNRESOLVED_DNS_REFUSAL_NO_INSTALL=PASS
printf 'clean-lab.invalid\ny\n1\n4\n\ny\n1\ny\n1\ny\n' |
  timeout 1200 bash "$src/twebproxy-manager.sh" tui-internal advanced-add
echo CLEAN_ADVANCED_INSTALL_RC=0
systemctl is-active --quiet twebproxy@clean-lab.invalid.service twebproxy-mtproxy@clean-lab.invalid--default.service
systemctl is-enabled twebproxy@clean-lab.invalid.service twebproxy-mtproxy@clean-lab.invalid--default.service
echo SERVICES_ACTIVE_ENABLED=PASS
curl --fail --silent --max-time 5 -H 'Host: clean-lab.invalid' http://127.0.0.1:18080/ | grep -q 'Культурные маршруты'
echo BUNDLED_WEBSITE_VIA_REAL_RELAY=PASS
/usr/local/sbin/twebproxy audit clean-lab.invalid --json
echo INSTALLED_AUDIT_RC=0
printf '1\ny\n' | /usr/local/sbin/twebproxy tui-internal profile-add clean-lab.invalid
echo INSTALLED_STANDARD_PROFILE_ADD_RC=0
/usr/local/sbin/twebproxy profile-list clean-lab.invalid --json
systemctl is-active --quiet ssh
echo FRESH_SSH_PRESERVED=PASS
