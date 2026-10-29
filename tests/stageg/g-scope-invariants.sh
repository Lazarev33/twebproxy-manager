#!/usr/bin/env bash
# Stage G scope against the exact v0.2.20 (Stage F, 24e2fb8) tree. Allowed
# changes: the health probe and lock-descriptor handling of the updater and its
# offline helper (G-P1-A/B) plus its global.env metadata sync, the Nginx Let's
# Encrypt webroot preparation (configure_nginx_le, cert_renew_cmd, new
# acme_webroot_prepare) and hostname validation in five mutating commands.
# Everything else is byte-identical (function text via declare -f, every other
# file, every top-level variable). README and ROADMAP carry the owner's newer
# text from GitHub main.
# Usage: g-scope-invariants.sh <v0.2.20 tree> [<candidate tree>]
set -Eeuo pipefail
BASE="${1:?v0.2.20 tree}"; PROJECT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
TMP="$(mktemp -d /tmp/twebproxy-g-scope.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
UPDATER_MODIFIED=(stage4_render_restore_helper stage4_restore_helper_valid stage4_verify_backup stage4_prune_backups
  stage4_current_manager_preflight stage4_manager_health manager_latest_release_tag manager_release_download
  manager_update_cmd fetch_manager_update_info fetch_manager_update_hint_info)
MODIFIED=("${UPDATER_MODIFIED[@]}" configure_nginx_le cert_renew_cmd
  dpi_set_cmd dpi_disable_host_locked restart_cmd field_report_cmd)
ADDED=(acme_webroot_prepare)
CHANGED_FILES=(twebproxy-manager.sh VERSION CHANGELOG.md SHA256SUMS README.md docs/ROADMAP.md docs/UPDATES.md docs/SECURITY.md)
ADDED_FILES=(tests/stageg/README.md tests/stageg/process-fixture.sh tests/stageg/real-process-oracle.py
  tests/stageg/real-process-oracle.sh tests/stageg/acme-webroot-fixture.sh tests/stageg/input-validation-fixture.sh
  tests/stageg/run-stage-g-suite.sh
  tests/stageg/g-scope-invariants.sh)
# Documented protected-set hashes (legacy extractor and heredoc-aware full bodies).
LEGACY_BEFORE=c94a32e5b0c3dee6f05cc399121c4d70162381b34ed7273d4124ed269665001b
LEGACY_AFTER=2cb42277ad8f010cace933b9adc8760ff1099606f92cf5ee441ac8e669de1ce0
FULL_BEFORE=29479800bfd4afec9edc48d9154e61f198d7f275ebf9acfdab6f1a0ed3b5933f
FULL_AFTER=b1933776707d4b909eb85ba4da28aaf5007cb81b212112c75ddfaf287be69f0d
in_list() { local x="$1"; shift; local y; for y; do [[ "$x" == "$y" ]] && return 0; done; return 1; }

for side in baseline candidate; do
  tree="$BASE"; [[ "$side" != candidate ]] || tree="$PROJECT"
  TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 bash -c '
    source "$1"; trap - ERR
    while read -r fn; do
      hash="$(declare -f "$fn" | sha256sum)"
      printf "%s %s\n" "$fn" "${hash%% *}"
    done < <(compgen -A function | sort)
  ' _ "$tree/twebproxy-manager.sh" > "$TMP/$side"
done
unchanged=0; modified=0; added=0
while read -r fn old; do
  new="$(awk -v f="$fn" '$1==f{print $2}' "$TMP/candidate")"
  [[ -n "$new" ]] || { echo "FAIL removed function: $fn"; exit 1; }
  if [[ "$old" == "$new" ]]; then unchanged=$((unchanged+1)); continue; fi
  in_list "$fn" "${MODIFIED[@]}" || { echo "FAIL forbidden modification: $fn"; exit 1; }
  echo "allowed modified: $fn"; modified=$((modified+1))
done < "$TMP/baseline"
while read -r fn hash; do
  awk -v f="$fn" '$1==f{found=1} END{exit !found}' "$TMP/baseline" && continue
  in_list "$fn" "${ADDED[@]}" || { echo "FAIL unexpected added function: $fn"; exit 1; }
  added=$((added+1))
done < "$TMP/candidate"
(( modified == ${#MODIFIED[@]} && added == ${#ADDED[@]} )) || { echo "FAIL expected ${#MODIFIED[@]} modified / ${#ADDED[@]} added"; exit 1; }
echo "PASS functions: unchanged=$unchanged modified=$modified added=$added"

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
diff -u "$TMP/baseline.vars" "$TMP/candidate.vars"
echo "PASS top-level variables unchanged except the release identity"

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
  in_list "$f" "${ADDED_FILES[@]}" || [[ "$f" == evidence/stageG/* ]] ||
    { echo "FAIL unexpected added file: $f"; exit 1; }
done < "$TMP/cand.files"
echo "PASS files: $same byte-identical (assets, other docs, all earlier tests and evidence included)"

legacy_before="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$BASE/twebproxy-manager.sh")"
legacy_after="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$PROJECT/twebproxy-manager.sh")"
full_before="$(bash "$PROJECT/tests/stagef/updater-function-hashes.sh" "$BASE/twebproxy-manager.sh" | tail -1)"
full_after="$(bash "$PROJECT/tests/stagef/updater-function-hashes.sh" "$PROJECT/twebproxy-manager.sh" | tail -1)"
[[ "${legacy_before%% *}" == "$LEGACY_BEFORE" && "${full_before%% *}" == "$FULL_BEFORE" ]] || { echo "FAIL baseline hashes: $legacy_before / $full_before"; exit 1; }
[[ "${legacy_after%% *}" == "$LEGACY_AFTER" && "${full_after%% *}" == "$FULL_AFTER" ]] || { echo "FAIL candidate hashes (update the documented values): $legacy_after / $full_after"; exit 1; }
echo "PASS Stage 4 protected set: legacy ${LEGACY_BEFORE:0:12} -> ${LEGACY_AFTER:0:12}, full ${FULL_BEFORE:0:12} -> ${FULL_AFTER:0:12} (documented)"
printf 'PASS g-scope unchanged=%s modified=%s added=%s\n' "$unchanged" "$modified" "$added"
