#!/bin/bash
set -euo pipefail
root="${BF_TEST_ROOT:?}"
printf '%s\n' "$*" >> "$root/systemctl.calls"
if [[ -e "$root/fail-systemctl" ]]; then
  action="$(cat "$root/fail-systemctl")"
  [[ -n "$action" && "$action" != "$1" ]] || exit 1
fi
case "$1" in
  is-active) [[ -f "$root/active" ]] || exit 3;;
  start|reload)
    # v0.2.23 contract: the owned guard session (ExecStart "firewall-guard hold",
    # verified by "firewall-guard wait"/"reload") is real-host behaviour
    # (tests/prerc); this model requires those lines and runs the backend helper
    # lines (ExecStartPost / ExecReload) exactly as written.
    helper="${BF_TEST_HELPER:?}"; guard="$(dirname "$helper")/firewall-guard"
    if [[ "$1" == start ]]; then
      [[ "$(sed -n 's/^ExecStart=//p' "${BF_TEST_UNIT:?}")" == "$guard hold" ]]
      grep -qxF "ExecStartPost=$guard wait" "$BF_TEST_UNIT"
      key=ExecStartPost
    else
      grep -qxF "ExecReload=$guard reload \$MAINPID" "$BF_TEST_UNIT"
      key=ExecReload
    fi
    [[ "$(sed -n "s/^$key=//p" "$BF_TEST_UNIT" | grep -cxF "$helper")" == 1 ]]
    touch "$root/guard"
    "$helper"
    touch "$root/active";;
  restart)
    # Model the legacy ExecStop gap explicitly.
    nft delete table inet twebproxy_backend
    touch "$root/guard"
    "${BF_TEST_HELPER:?}"; touch "$root/active";;
  daemon-reload|enable) exit 0;;
  *) exit 1;;
esac
