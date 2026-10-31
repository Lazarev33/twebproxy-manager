#!/usr/bin/env bash
# v0.2.24 focused security correction: scope against the exact v0.2.23 tree
# (302ae80). Allowed changes: the backend socket filter and start gate
# (P1-A), the procfs fail-closed ordering, effective-mount check and deliberate
# opt-out (P1-B), their audit checks, catalog strings and the call sites that
# order hardening before backend starts. Every other function and top-level
# variable stays byte-identical; the Stage 4 protected sets (update / rollback
# / offline restore) stay byte-identical.
# Usage: prerc2-scope-invariants.sh <v0.2.23 tree> [<candidate tree>]
set -Eeuo pipefail
BASE="${1:?v0.2.23 tree}"; PROJECT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
TMP="$(mktemp -d /tmp/twebproxy-prerc2-scope.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
MODIFIED=(add_instance_cmd collect_audit core_install_cmd core_uninstall_cmd proc_hardening_cmd proc_hardening_disable
  proc_hide_active proc_hidepid_value rebuild_firewall repair_instance_cmd start_profile_backend ui_i18n_init ui_localize_legacy
  write_runner_helpers write_systemd_templates)
ADDED=(backend_socket_filter_check backend_start_check_fail backend_start_check_main dc_addresses_outside_allowlist
  ip4_in_dc_cidrs ip4_to_int proc_fail_closed proc_secret_safe proc_top_mount_options proc_unprivileged_can_read
  write_backend_start_check_helper)
NEW_VARS=(TELEGRAM_DC_CIDRS)
CHANGED_FILES=(twebproxy-manager.sh VERSION CHANGELOG.md SHA256SUMS README.md docs/SECURITY.md
  tests/read-only-core-fixture.sh tests/fixtures/read-only-core/audit-healthy.tsv
  tests/stageb/lab-gate-fixture.sh tests/stageb/libexec-permissions-fixture.sh)
ADDED_FILES=(tests/prerc2/README.md tests/prerc2/probe_peer.py tests/prerc2/fw_owner_loss_probe.py
  tests/prerc2/no_table_windows.py tests/prerc2/proc_ns_scenario.py tests/prerc2/proc_fail_closed_probe.sh
  tests/prerc2/prerc2-scope-invariants.sh tests/prerc2/run-prerc2-real-suite.sh tests/prerc2/start-gate-fixture.sh)
STAGE4_LEGACY=bf060d063c53bd220210036c227df0cb251d5ba749c860df411b6de5fbb3c223
STAGE4_FULL=830f6cd889f2c821c2fc69fe6b623c2595be0180517bfb7d2197079687c6b859
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
(( modified == ${#MODIFIED[@]} && added == ${#ADDED[@]} )) || { echo "FAIL expected ${#MODIFIED[@]} modified / ${#ADDED[@]} added (got $modified / $added)"; exit 1; }
echo "PASS functions: unchanged=$unchanged modified=$modified added=$added"

for side in baseline candidate; do
  tree="$BASE"; [[ "$side" != candidate ]] || tree="$PROJECT"
  TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 bash -c '
    before=""; before="$(compgen -v)"
    source "$1"; trap - ERR
    while read -r name; do
      case "$name" in MANAGER_VERSION|MANAGER_RELEASE_VERSION|name|TELEGRAM_DC_CIDRS) continue;; esac
      if grep -Fxq -- "$name" <<< "$before"; then continue; fi
      declare -p "$name"
    done < <(compgen -v | sort)
  ' _ "$tree/twebproxy-manager.sh" > "$TMP/$side.vars"
done
diff -u "$TMP/baseline.vars" "$TMP/candidate.vars"
echo "PASS top-level variables unchanged except the release identity and: ${NEW_VARS[*]}"

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
  in_list "$f" "${ADDED_FILES[@]}" || [[ "$f" == evidence/prerc2/* ]] ||
    { echo "FAIL unexpected added file: $f"; exit 1; }
done < "$TMP/cand.files"
echo "PASS files: $same byte-identical"

legacy="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$PROJECT/twebproxy-manager.sh")"
full="$(bash "$PROJECT/tests/stagef/updater-function-hashes.sh" "$PROJECT/twebproxy-manager.sh" | tail -1)"
[[ "${legacy%% *}" == "$STAGE4_LEGACY" && "${full%% *}" == "$STAGE4_FULL" ]] ||
  { echo "FAIL Stage 4 protected sets changed: $legacy / $full"; exit 1; }
echo "PASS Stage 4 protected sets (update/rollback/offline restore) byte-identical to v0.2.23"
printf 'PASS prerc2-scope unchanged=%s modified=%s added=%s\n' "$unchanged" "$modified" "$added"
