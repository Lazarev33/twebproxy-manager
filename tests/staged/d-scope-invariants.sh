#!/usr/bin/env bash
# Stage D scope against the exact v0.2.17 (Stage C2, e841c4e) tree: only the
# Caddy/Nginx frontend, certificate (Let's Encrypt / custom) and instance delete
# (frontend removal) paths may change; ui_localize_legacy may only gain lines;
# new top-level variables are limited to the frontend locations, the
# interruption flag and the frontend lock; write_nginx_tls_conf is replaced by render_nginx_tls_conf;
# every other file except release metadata and the ROADMAP status is
# byte-identical (README, assets, other docs, C1/C2 code and tests included).
# Usage: d-scope-invariants.sh <v0.2.17 tree> [<candidate tree>]
set -Eeuo pipefail
BASE="${1:?v0.2.17 tree}"; PROJECT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
TMP="$(mktemp -d /tmp/twebproxy-d-scope.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
MODIFIED=(configure_caddy_host remove_caddy_block nginx_common_install nginx_domain_conflict
  install_nginx_certbot_deploy_hook configure_nginx_le configure_nginx_custom remove_reverse_proxy_for_instance
  cert_renew_cmd delete_instance_cmd ui_localize_legacy)
ADDED=(frontend_lock_acquire frontend_lock_release frontend_dirs frontend_file_replace frontend_signals_defer frontend_signals_end caddy_block_range render_caddy_block
  caddy_publish caddy_remove_host nginx_managed_state_ok nginx_link_enable nginx_managed_save
  nginx_managed_restore nginx_test nginx_managed_apply nginx_managed_remove nginx_apply_or_die
  tls_pair_matches le_cert_usable render_nginx_acme_conf render_nginx_tls_conf)
REMOVED=(write_nginx_tls_conf)
CHANGED_FILES=(twebproxy-manager.sh VERSION CHANGELOG.md SHA256SUMS docs/ROADMAP.md)
ADDED_FILES=(tests/staged/README.md tests/staged/frontend-harness.sh tests/staged/frontend-tls-fixture.sh
  tests/staged/run-stage-d-suite.sh tests/staged/d-scope-invariants.sh tests/staged/rebind-baseline.sh)
NEW_VARS=(CADDY_DIR CADDYFILE NGINX_DIR LE_DIR ACME_WEBROOT FRONTEND_INTERRUPTED FRONTEND_LOCK_FD FRONTEND_LOCK_DEPTH)
in_list() { local x="$1"; shift; local y; for y; do [[ "$x" == "$y" ]] && return 0; done; return 1; }

for side in baseline candidate; do
  tree="$BASE"; [[ "$side" != candidate ]] || tree="$PROJECT"
  TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 bash -c '
    source "$1"; trap - ERR
    while read -r fn; do
      hash="$(declare -f "$fn" | sha256sum)"
      printf "%s %s\n" "$fn" "${hash%% *}"
    done < <(compgen -A function | sort)
    declare -f ui_localize_legacy > "$2.l10n"
  ' _ "$tree/twebproxy-manager.sh" "$TMP/$side" > "$TMP/$side"
done
unchanged=0; modified=0; added=0
while read -r fn old; do
  new="$(awk -v f="$fn" '$1==f{print $2}' "$TMP/candidate")"
  if [[ -z "$new" ]]; then
    in_list "$fn" "${REMOVED[@]}" || { echo "FAIL removed function: $fn"; exit 1; }
    echo "allowed removed: $fn"; continue
  fi
  if [[ "$old" == "$new" ]]; then unchanged=$((unchanged+1)); continue; fi
  in_list "$fn" "${MODIFIED[@]}" || { echo "FAIL forbidden modification: $fn"; exit 1; }
  echo "allowed modified: $fn"; modified=$((modified+1))
done < "$TMP/baseline"
while read -r fn hash; do
  awk -v f="$fn" '$1==f{found=1} END{exit !found}' "$TMP/baseline" && continue
  in_list "$fn" "${ADDED[@]}" || { echo "FAIL unexpected added function: $fn"; exit 1; }
  added=$((added+1))
done < "$TMP/candidate"
echo "PASS functions: unchanged=$unchanged modified=$modified added=$added"

# Localization adapter: additions only (new message translations).
if diff "$TMP/baseline.l10n" "$TMP/candidate.l10n" | grep -E '^[<]' >/dev/null; then
  echo 'FAIL ui_localize_legacy lost or changed existing lines'; exit 1
fi
echo "PASS ui_localize_legacy: only $(diff "$TMP/baseline.l10n" "$TMP/candidate.l10n" | grep -c '^>') added lines"

for side in baseline candidate; do
  tree="$BASE"; [[ "$side" != candidate ]] || tree="$PROJECT"
  TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 bash -c '
    before=""; before="$(compgen -v)"
    source "$1"; trap - ERR
    while read -r name; do
      case "$name" in MANAGER_VERSION|MANAGER_RELEASE_VERSION|name) continue;; esac
      if grep -Fxq -- "$name" <<< "$before"; then continue; fi
      declare -p "$name"
    done < <(compgen -v | sort)
  ' _ "$tree/twebproxy-manager.sh" > "$TMP/$side.vars"
done
grep -vE "^declare [-a-zA-Z]+ ($(IFS='|'; echo "${NEW_VARS[*]}"))=" "$TMP/candidate.vars" > "$TMP/candidate.vars.old"
diff -u "$TMP/baseline.vars" "$TMP/candidate.vars.old"
echo "PASS top-level variables unchanged except release identity and ${#NEW_VARS[@]} frontend location/interruption/lock variables"

files() { (cd "$1" && find . -path ./.git -prune -o -type f -printf '%P\n' | LC_ALL=C sort); }
files "$BASE" > "$TMP/base.files"; files "$PROJECT" > "$TMP/cand.files"
same=0
while read -r f; do
  [[ -f "$PROJECT/$f" ]] || { echo "FAIL removed file: $f"; exit 1; }
  if cmp -s "$BASE/$f" "$PROJECT/$f"; then same=$((same+1)); continue; fi
  in_list "$f" "${CHANGED_FILES[@]}" || { echo "FAIL forbidden file change: $f"; exit 1; }
  echo "allowed changed file: $f"
done < "$TMP/base.files"
while read -r f; do
  grep -Fxq -- "$f" "$TMP/base.files" && continue
  in_list "$f" "${ADDED_FILES[@]}" || [[ "$f" == evidence/stageD/* ]] ||
    { echo "FAIL unexpected added file: $f"; exit 1; }
done < "$TMP/cand.files"
echo "PASS files: $same byte-identical (README, assets, docs, other tests and evidence included)"
actual="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$PROJECT/twebproxy-manager.sh")"
[[ "${actual%% *}" == fd0e123c516324c23f0a42084f666104db5c35c58e1518a05abee1704b04abcb ]]
echo "$actual"
printf 'PASS d-scope unchanged=%s modified=%s added=%s\n' "$unchanged" "$modified" "$added"
