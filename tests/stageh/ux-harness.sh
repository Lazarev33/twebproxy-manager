#!/usr/bin/env bash
# Stage H UX sandbox: tests/stagee/ops-harness.sh (real prompts on stdin, models
# for systemd, nft, ip, dig, curl, Caddy/Nginx/certbot) plus:
#   - the real show_instance_cmd, show_profile_cmd and carrier_choose (the C1
#     layer stubs them);
#   - no forced language: H_LANG=en|ru sets it, empty leaves the manager's own
#     choice (language file, first-run selection).
H_HARNESS="${BASH_SOURCE[0]}"
# shellcheck source=/dev/null
source "$(dirname "$H_HARNESS")/../stagee/ops-harness.sh"

h_harness() {
  export H_HARNESS
  e_harness
  unset TWEBPROXY_UI_LANGUAGE
  eval "$(TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 bash -c 'source "$1" >/dev/null 2>&1; trap - ERR
    declare -f show_instance_cmd show_profile_cmd carrier_choose' _ "$MGR")"
  [[ -z "${H_LANG:-}" ]] || UI_LANGUAGE="$H_LANG"
}
