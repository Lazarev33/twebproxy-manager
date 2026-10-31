#!/usr/bin/env bash
# v0.2.23 pre-RC corrections: scope against the exact v0.2.22 (Stage H,
# a2f5bdd) tree. Allowed changes: the backend firewall lifecycle (owned guard
# session, unit contract, nftables drop-in, uninstall), offline-restore outcome
# (RESTORE_PARTIAL) and rollback confirmation, global.env atomic write, DPI
# failure truthfulness and kernel-consistency status, the procfs policy, the
# bounded Caddy certificate wait, the RU/EN catalog, help and dispatch. Every
# other function and top-level variable stays byte-identical; the Stage 4
# protected set changes ONLY through stage4_render_restore_helper (s4_restore_id).
# Usage: prerc-scope-invariants.sh <v0.2.22 tree> [<candidate tree>]
set -Eeuo pipefail
BASE="${1:?v0.2.22 tree}"; PROJECT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
TMP="$(mktemp -d /tmp/twebproxy-prerc-scope.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
MODIFIED=(add_instance_cmd collect_audit core_install_cmd core_uninstall_cmd dpi_rollback_to_snapshot dpi_status_cmd
  dpi_transaction_failure_message dpi_write_firewall_runtime main manager_restore_backup_cmd menu_update_recovery
  rebuild_firewall repair_instance_cmd stage4_render_restore_helper ui_i18n_init usage write_backend_firewall_unit
  write_global_env write_runner_helpers write_systemd_templates)
ADDED=(caddy_wait_certificate dpi_runtime_consistency fw_guard_batch_create fw_guard_batch_update fw_guard_hold
  fw_guard_live fw_guard_main fw_guard_ports_elements fw_guard_present fw_guard_wait proc_fstab_line proc_fstab_write
  proc_hardening_cmd proc_hardening_disable proc_hardening_enable proc_hardening_ensure proc_hardening_state
  proc_hide_active proc_hidepid_value stage4_confirm_restore write_firewall_guard_helper write_nftables_dropin)
NEW_VARS=(FW_GUARD_TABLE FW_NFT_DROPIN PROC_GROUP PROC_POLICY_FILE PROC_FSTAB_MARK)
CHANGED_FILES=(twebproxy-manager.sh VERSION CHANGELOG.md SHA256SUMS README.md docs/ROADMAP.md docs/UPDATES.md
  docs/SETUP.md docs/SECURITY.md tests/fieldgate/tg3-installed-manager-lifecycle.sh tests/lib/lab-gate.sh
  tests/read-only-core-fixture.sh tests/stageb/firewall-unit-fixture.sh tests/stageb/lab-gate-fixture.sh
  tests/stageb/libexec-permissions-fixture.sh tests/stageb/nft-model.sh tests/stageb/real-systemd-validation.sh
  tests/stageb/systemctl-model.sh tests/stagec1/state-harness.sh tests/stageg/process-fixture.sh
  tests/stageb/README.md tests/LAB.md tests/fixtures/read-only-core/audit-healthy.tsv)
ADDED_FILES=(tests/prerc/README.md tests/prerc/fw-transition-probe.sh tests/prerc/guard-continuity-real.sh
  tests/prerc/proc-secret-real.sh tests/prerc/dpi-enospc-real.sh tests/prerc/restore-metadata-real.py
  tests/prerc/quick-setup-pty.py tests/prerc/prerc-scope-invariants.sh tests/prerc/run-prerc-real-suite.sh)
LEGACY_BEFORE=2cb42277ad8f010cace933b9adc8760ff1099606f92cf5ee441ac8e669de1ce0
LEGACY_AFTER=bf060d063c53bd220210036c227df0cb251d5ba749c860df411b6de5fbb3c223
FULL_BEFORE=b1933776707d4b909eb85ba4da28aaf5007cb81b212112c75ddfaf287be69f0d
FULL_AFTER=830f6cd889f2c821c2fc69fe6b623c2595be0180517bfb7d2197079687c6b859
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
      case "$name" in MANAGER_VERSION|MANAGER_RELEASE_VERSION|name|FW_GUARD_TABLE|FW_NFT_DROPIN|PROC_GROUP|PROC_POLICY_FILE|PROC_FSTAB_MARK) continue;; esac
      if grep -Fxq -- "$name" <<< "$before"; then continue; fi
      declare -p "$name"
    done < <(compgen -v | sort)
  ' _ "$tree/twebproxy-manager.sh" > "$TMP/$side.vars"
done
diff -u "$TMP/baseline.vars" "$TMP/candidate.vars"
echo "PASS top-level variables unchanged except the release identity and the new constants: ${NEW_VARS[*]}"

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
  in_list "$f" "${ADDED_FILES[@]}" || [[ "$f" == evidence/prerc/* ]] ||
    { echo "FAIL unexpected added file: $f"; exit 1; }
done < "$TMP/cand.files"
echo "PASS files: $same byte-identical (assets, other docs, all earlier tests and evidence included)"

legacy_before="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$BASE/twebproxy-manager.sh")"
legacy_after="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$PROJECT/twebproxy-manager.sh")"
full_before="$(bash "$PROJECT/tests/stagef/updater-function-hashes.sh" "$BASE/twebproxy-manager.sh" | tail -1)"
full_after="$(bash "$PROJECT/tests/stagef/updater-function-hashes.sh" "$PROJECT/twebproxy-manager.sh" | tail -1)"
[[ "${legacy_before%% *}" == "$LEGACY_BEFORE" && "${full_before%% *}" == "$FULL_BEFORE" ]] || { echo "FAIL baseline hashes: $legacy_before / $full_before"; exit 1; }
[[ "${legacy_after%% *}" == "$LEGACY_AFTER" && "${full_after%% *}" == "$FULL_AFTER" ]] || { echo "FAIL candidate hashes (update the documented values): $legacy_after / $full_after"; exit 1; }
echo "PASS Stage 4 protected set changed only as documented (s4_restore_id partial outcome): legacy ${LEGACY_AFTER:0:12}, full ${FULL_AFTER:0:12}"
printf 'PASS prerc-scope unchanged=%s modified=%s added=%s\n' "$unchanged" "$modified" "$added"
