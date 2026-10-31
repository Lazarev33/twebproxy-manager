#!/usr/bin/env bash
# Stage H scope against the exact v0.2.21 (Stage G, 0a14a29) tree. Allowed
# changes: the guided setup (collect_instance_settings, collect_profile_settings,
# add_instance_cmd), client help (show_instance_cmd + new helpers), menus
# (menu, menu_settings, menu_network_compatibility, new menu_connect and
# first_run_prerequisites), Anti-DPI explanations (dpi_list_methods_cmd), status
# hints (tui_render_status, new tui_check_hint), help (usage) and the RU/EN
# catalog (ui_i18n_init). The updater (Stage 4/F/G set), the offline helper,
# DPI/firewall/relay/frontend/TLS/state code and every top-level variable stay
# byte-identical. Test changes: the C1 harness answers the new setup prompt and
# keeps its catalog global; the FixUI route test follows the new menu order.
# README and ROADMAP carry the owner's newer text from GitHub main.
# Usage: h-scope-invariants.sh <v0.2.21 tree> [<candidate tree>]
set -Eeuo pipefail
BASE="${1:?v0.2.21 tree}"; PROJECT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
TMP="$(mktemp -d /tmp/twebproxy-h-scope.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
MODIFIED=(add_instance_cmd collect_instance_settings collect_profile_settings dpi_list_methods_cmd menu
  menu_network_compatibility menu_settings show_instance_cmd tui_render_status ui_i18n_init usage)
ADDED=(client_help_render first_run_prerequisites menu_connect setup_next_steps tui_check_hint)
CHANGED_FILES=(twebproxy-manager.sh VERSION CHANGELOG.md SHA256SUMS README.md docs/ROADMAP.md docs/UPDATES.md
  tests/stagec1/state-harness.sh tests/stage-x-fixui-fixture.sh)
ADDED_FILES=(docs/SETUP.md tests/stageh/README.md tests/stageh/ux-harness.sh tests/stageh/ux-fixture.sh
  tests/stageh/heredoc-guard.sh tests/stageh/run-stage-h-suite.sh tests/stageh/h-scope-invariants.sh)
# The updater is untouched in Stage H: the Stage G hashes hold before and after.
LEGACY_BEFORE=2cb42277ad8f010cace933b9adc8760ff1099606f92cf5ee441ac8e669de1ce0
LEGACY_AFTER=2cb42277ad8f010cace933b9adc8760ff1099606f92cf5ee441ac8e669de1ce0
FULL_BEFORE=b1933776707d4b909eb85ba4da28aaf5007cb81b212112c75ddfaf287be69f0d
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
  in_list "$f" "${ADDED_FILES[@]}" || [[ "$f" == evidence/stageH/* ]] ||
    { echo "FAIL unexpected added file: $f"; exit 1; }
done < "$TMP/cand.files"
echo "PASS files: $same byte-identical (assets, other docs, all earlier tests and evidence included)"

legacy_before="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$BASE/twebproxy-manager.sh")"
legacy_after="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$PROJECT/twebproxy-manager.sh")"
full_before="$(bash "$PROJECT/tests/stagef/updater-function-hashes.sh" "$BASE/twebproxy-manager.sh" | tail -1)"
full_after="$(bash "$PROJECT/tests/stagef/updater-function-hashes.sh" "$PROJECT/twebproxy-manager.sh" | tail -1)"
[[ "${legacy_before%% *}" == "$LEGACY_BEFORE" && "${full_before%% *}" == "$FULL_BEFORE" ]] || { echo "FAIL baseline hashes: $legacy_before / $full_before"; exit 1; }
[[ "${legacy_after%% *}" == "$LEGACY_AFTER" && "${full_after%% *}" == "$FULL_AFTER" ]] || { echo "FAIL candidate hashes (update the documented values): $legacy_after / $full_after"; exit 1; }
echo "PASS Stage 4/F/G updater set unchanged: legacy ${LEGACY_AFTER:0:12}, full ${FULL_AFTER:0:12}"
printf 'PASS h-scope unchanged=%s modified=%s added=%s\n' "$unchanged" "$modified" "$added"
