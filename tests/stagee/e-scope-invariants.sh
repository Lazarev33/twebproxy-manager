#!/usr/bin/env bash
# Stage E scope against the exact v0.2.18 (Stage D, d3bf510) tree: only the
# prompts and menus (EOF/number handling), the read-only collectors and
# renderers (bounded probes, truthful states), diagnose, the snapshot/log/report
# path and the redaction filter may change; ui_localize_legacy may only gain
# lines; new top-level variables are the probe bound and the log-bundle cleanup
# state; README and ROADMAP carry the owner's newer text from GitHub main;
# every other file except release metadata is byte-identical (assets, other
# docs, all C1-D code and tests included).
# Usage: e-scope-invariants.sh <v0.2.18 tree> [<candidate tree>]
set -Eeuo pipefail
BASE="${1:?v0.2.18 tree}"; PROJECT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
TMP="$(mktemp -d /tmp/twebproxy-e-scope.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
MODIFIED=(ask yesno choose menu_choose ui_select_language on_error select_instance select_profile
  ask_internal_port carrier_choose collect_profile_settings menu_profiles menu_certificates
  menu_status_statistics menu_diagnostics menu_network_compatibility menu_settings
  redact_sensitive_stream collect_overview collect_status collect_audit render_audit_human
  firewall_has_backend_port tui_render_dashboard diagnose_cmd journal_current_unit
  collect_history_snapshot collect_runtime_snapshot field_collect_journal_window field_collect_nft
  copy_recent_files logs_pack_cmd ui_localize_legacy ui_naturalize_ru_legacy)
ADDED=(ui_input_closed ui_number_in_range diag_run diag_show diag_unit_state logs_copy_file
  logs_pack_cleanup logs_pack_on_signal)
REMOVED=()
CHANGED_FILES=(twebproxy-manager.sh VERSION CHANGELOG.md SHA256SUMS README.md docs/ROADMAP.md)
ADDED_FILES=(tests/stagee/README.md tests/stagee/ops-harness.sh tests/stagee/operations-fixture.sh
  tests/stagee/run-stage-e-suite.sh tests/stagee/e-scope-invariants.sh)
NEW_VARS=(DIAG_TIMEOUT LOGS_STAGING LOGS_PARTIAL)
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
echo "PASS top-level variables unchanged except release identity and ${#NEW_VARS[@]} probe-bound/log-cleanup variables"

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
  in_list "$f" "${ADDED_FILES[@]}" || [[ "$f" == evidence/stageE/* ]] ||
    { echo "FAIL unexpected added file: $f"; exit 1; }
done < "$TMP/cand.files"
echo "PASS files: $same byte-identical (README, assets, docs, other tests and evidence included)"
actual="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$PROJECT/twebproxy-manager.sh")"
[[ "${actual%% *}" == fd0e123c516324c23f0a42084f666104db5c35c58e1518a05abee1704b04abcb ]]
echo "$actual"
printf 'PASS e-scope unchanged=%s modified=%s added=%s\n' "$unchanged" "$modified" "$added"
