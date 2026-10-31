#!/usr/bin/env bash
# Stage F scope against the exact v0.2.19 (Stage E, a3a2bf4) tree. Only the
# manager self-updater may change: eleven functions of the former Stage 4
# protected set, install_manager_copy (update lock, atomic copy), the CLI
# dispatch and help line of manager-update, and the localization adapter
# (updater messages). The other 17 Stage 4 functions and every other function
# are byte-identical. New top-level variables are the trust policy and the lock
# wait; MANAGER_DEFAULT_BRANCH (the development-branch source) is gone.
# README and ROADMAP carry the owner's newer text from GitHub main.
# Usage: f-scope-invariants.sh <v0.2.19 tree> [<candidate tree>]
set -Eeuo pipefail
BASE="${1:?v0.2.19 tree}"; PROJECT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
TMP="$(mktemp -d /tmp/twebproxy-f-scope.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
STAGE4_MODIFIED=(stage4_render_restore_helper stage4_install_restore_helper stage4_prepare_backup_root
  stage4_acquire_update_lock stage4_install_candidate_target load_manager_update_cache fetch_manager_update_info
  manager_check_update_impl set_global_manager_version manager_update_cmd fetch_manager_update_hint_info)
MODIFIED=("${STAGE4_MODIFIED[@]}" install_manager_copy main usage ui_localize_legacy)
ADDED=(stage4_restore_helper_valid stage4_backup_parent_ready stage4_release_update_lock stage4_manager_copies_match
  stage4_update_prepare stage4_update_end stage4_update_abort stage4_update_refuse
  manager_release_tag_from_json manager_latest_release_tag manager_release_download
  manager_release_signature_ok manager_release_manifest_fields manager_candidate_identity_ok)
REMOVED=()
CHANGED_FILES=(twebproxy-manager.sh VERSION CHANGELOG.md SHA256SUMS README.md docs/ROADMAP.md
  docs/SECURITY.md docs/ARCHITECTURE.md
  tests/stage4-update-backup-fixture.sh tests/stage-x-dpi-installed-asset-fixture.sh
  tests/localization-static-audit.sh tests/localization-flow-fixture.sh)
ADDED_FILES=(docs/UPDATES.md tests/stagef/README.md tests/stagef/updater-harness.sh
  tests/stagef/updater-fixture.sh tests/stagef/run-stage-f-suite.sh tests/stagef/f-scope-invariants.sh
  tests/stagef/updater-function-hashes.sh)
NEW_VARS=(MANAGER_UPDATE_TRUSTED_KEYS MANAGER_RELEASE_MANIFEST MANAGER_RELEASE_FORMAT
  MANAGER_ARTIFACT_MAX_BYTES UPDATE_LOCK_WAIT_SECONDS)
REMOVED_VARS=(MANAGER_DEFAULT_BRANCH)
# Documented protected-set hashes (legacy extractor, tests/fieldgate/stage4-function-set-hash.sh).
STAGE4_LEGACY_BEFORE=fd0e123c516324c23f0a42084f666104db5c35c58e1518a05abee1704b04abcb
STAGE4_LEGACY_AFTER=c94a32e5b0c3dee6f05cc399121c4d70162381b34ed7273d4124ed269665001b
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
    continue
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

# Localization adapter (source text): removed lines may only be translations of
# the removed updater messages (same-source checksum, development-branch check,
# old first-copy and preflight texts).
l10n() { awk '/^ui_localize_legacy\(\) \{/{i=1} i{print} i&&/^\}$/{exit}' "$1/twebproxy-manager.sh"; }
cat > "$TMP/l10n-removable" <<'LIST'
    'Не удалось проверить обновление manager на '*)
    'Не удалось получить информацию об обновлении с '*)
    В\ *\ нет\ SHA256SUMS.*)
    'SHA256SUMS не содержит корректный hash для twebproxy-manager.sh')
    'SHA-256 manager candidate не совпал с SHA256SUMS')
    'Скачанный manager не проходит bash -n')
    'Не удалось подготовить/установить первую manager-копию; проверенный backup сохранён:'*)
    'Текущие manager-копии не образуют точное безопасное состояние; обновление остановлено до создания backup.')
LIST
diff <(l10n "$BASE") <(l10n "$PROJECT") | sed -n 's/^< //p' > "$TMP/l10n-removed" || true
if grep -vF -f "$TMP/l10n-removable" "$TMP/l10n-removed" | grep -q .; then
  echo 'FAIL ui_localize_legacy lost unrelated lines:'; grep -vF -f "$TMP/l10n-removable" "$TMP/l10n-removed"; exit 1
fi
echo "PASS ui_localize_legacy: $(grep -c . "$TMP/l10n-removed") obsolete updater lines removed, $(diff <(l10n "$BASE") <(l10n "$PROJECT") | grep -c '^>') added"

# Each Stage 4 function outside the modified list is byte-identical in its full
# text (heredoc-aware extraction, not the legacy extractor).
paste <(bash "$PROJECT/tests/stagef/updater-function-hashes.sh" "$BASE/twebproxy-manager.sh") \
      <(bash "$PROJECT/tests/stagef/updater-function-hashes.sh" "$PROJECT/twebproxy-manager.sh") > "$TMP/hashes"
same4=0
while read -r old name new name2; do
  [[ "$name" == "$name2" ]] || { echo "FAIL hash listing mismatch"; exit 1; }
  case "$name" in stage4-protected-function-set-full) continue;; esac
  if [[ "$old" == "$new" ]]; then
    in_list "$name" "${STAGE4_MODIFIED[@]}" && { echo "FAIL listed as modified but identical: $name"; exit 1; }
    same4=$((same4+1))
  else
    in_list "$name" "${STAGE4_MODIFIED[@]}" "${ADDED[@]}" install_manager_copy || { echo "FAIL Stage 4 function changed: $name"; exit 1; }
  fi
done < "$TMP/hashes"
echo "PASS Stage 4 set: $same4 functions byte-identical, ${#STAGE4_MODIFIED[@]} authorized modifications"

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
grep -vE "^declare [-a-zA-Z]+ ($(IFS='|'; echo "${REMOVED_VARS[*]}"))=" "$TMP/baseline.vars" > "$TMP/baseline.vars.kept"
diff -u "$TMP/baseline.vars.kept" "$TMP/candidate.vars.old"
echo "PASS top-level variables unchanged except release identity, ${#NEW_VARS[@]} trust/lock variables and the removed branch source"

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
  in_list "$f" "${ADDED_FILES[@]}" || [[ "$f" == evidence/stageF/* ]] ||
    { echo "FAIL unexpected added file: $f"; exit 1; }
done < "$TMP/cand.files"
echo "PASS files: $same byte-identical (assets, other docs, other tests and evidence included)"

before="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$BASE/twebproxy-manager.sh")"
after="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$PROJECT/twebproxy-manager.sh")"
[[ "${before%% *}" == "$STAGE4_LEGACY_BEFORE" ]] || { echo "FAIL baseline protected hash: $before"; exit 1; }
[[ "${after%% *}" == "$STAGE4_LEGACY_AFTER" ]] || { echo "FAIL candidate protected hash (update the documented value): $after"; exit 1; }
echo "PASS Stage 4 legacy protected-set hash: ${before%% *} -> ${after%% *} (documented)"
printf 'PASS f-scope unchanged=%s modified=%s added=%s\n' "$unchanged" "$modified" "$added"
