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
    key=ExecStart; [[ "$1" != reload ]] || key=ExecReload
    executable="$(sed -n "s/^$key=//p" "${BF_TEST_UNIT:?}")"
    [[ "$executable" == "${BF_TEST_HELPER:?}" ]]
    "$executable"
    touch "$root/active";;
  restart)
    # Model the legacy ExecStop gap explicitly.
    nft delete table inet twebproxy_backend
    "${BF_TEST_HELPER:?}"; touch "$root/active";;
  daemon-reload|enable) exit 0;;
  *) exit 1;;
esac
