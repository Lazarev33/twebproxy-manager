#!/usr/bin/env bash
set -Eeuo pipefail
BASE="${1:?baseline tree}"; PROJECT="${2:?candidate tree}"
TMP="$(mktemp -d /tmp/twebproxy-scope-check.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
for side in baseline candidate; do
  tree="$BASE"; [[ "$side" != candidate ]] || tree="$PROJECT"
  TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 bash --noprofile --norc -c '
    source "$1"
    trap - ERR
    while read -r fn; do
      hash="$(declare -f "$fn" | sha256sum)"
      printf "%s %s\n" "$fn" "${hash%% *}"
    done < <(compgen -A function | sort)
  ' _ "$tree/twebproxy-manager.sh" > "$TMP/$side"
done
changed=0; checked=0
while read -r fn old; do
  new="$(awk -v f="$fn" '$1==f{print $2}' "$TMP/candidate")"
  [[ -n "$new" ]] || { printf 'FAIL missing function %s\n' "$fn"; exit 1; }
  if [[ "$old" == "$new" ]]; then checked=$((checked+1)); continue; fi
  case "$fn" in
    dpi_apply_rules_file|dpi_cleanup_nfqws_runtime|dpi_cleanup_stock_runtime|dpi_verify_runtime|dpi_state_dir_complete|dpi_publish_state_dir|dpi_with_mutation_lock|dpi_transaction_set_locked|dpi_transaction_disable_ip_locked|dpi_disable_cmd|dpi_runtime_artifacts_present|dpi_stock_postcondition_ok|menu_network_compatibility|ui_i18n_init) ;;
    *) printf 'FAIL out-of-scope function changed: %s\n' "$fn"; exit 1;;
  esac
  printf 'allowed modified function: %s\n' "$fn"
  changed=$((changed+1))
done < "$TMP/baseline"
for f in README.md assets/nfqws-linux-x86_64 assets/nfqws-LICENSE.txt assets/NFQWS-PROVENANCE.txt; do
  cmp "$BASE/$f" "$PROJECT/$f"
done
actual="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$PROJECT/twebproxy-manager.sh")"
[[ "${actual%% *}" == fd0e123c516324c23f0a42084f666104db5c35c58e1518a05abee1704b04abcb ]]
printf '%s\n' "$actual"
printf 'PASS scope: unchanged_functions=%s allowed_modified_functions=%s\n' "$checked" "$changed"
