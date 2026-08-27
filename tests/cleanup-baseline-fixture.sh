#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER="$PROJECT_ROOT/twebproxy-manager.sh"

fail() { printf 'cleanup-baseline-fixture: FAIL: %s\n' "$*" >&2; exit 1; }

bash -n "$MANAGER" || fail 'manager syntax validation failed'
[[ ! -e "$PROJECT_ROOT/twebproxy-recovery.sh" ]] \
  || fail 'rejected standalone recovery remains in the active project root'

for removed in snapshot-recovery-fixture.sh stage3-review-suite.sh \
  systemd-enablement-model-fixture.sh systemd-real-enablement-fixture.sh; do
  [[ ! -e "$PROJECT_ROOT/tests/$removed" ]] \
    || fail "rejected Stage 3 test remains active: $removed"
done

for token in TWEBPROXY_RECOVERY_ROOT TWEBPROXY_RECOVERY_STATE_DIR \
  SYSTEMD_RECONCILED restore-transaction twebproxy.snapshot \
  twebproxy.application lkg-set RECOVERY_BIN install_recovery_entrypoint \
  collect_recovery_state recovery-status snapshot-create snapshot-verify \
  snapshot-retention rollback_cmd; do
  ! grep -Fq "$token" "$MANAGER" \
    || fail "active manager still contains rejected Stage 3 token: $token"
done

# Stage 4 replaces only the formerly disabled update/recovery placeholders.
# It must retain the existing manager/relay updater descriptions without
# reintroducing any rejected Stage 3 recovery vocabulary.
# shellcheck disable=SC1090
source "$MANAGER"
trap - ERR
disable_colors
UI_LANGUAGE=en
update_view="$(COLUMNS=80 tui_render_update_recovery)"
grep -q 'Existing SHA256SUMS-verified workflow' <<< "$update_view" \
  || fail 'manager update presentation regressed'
grep -q '^Local update backups' <<< "$update_view" \
  || fail 'Stage 4 local update backup row is missing'
grep -q '^Offline rollback helper' <<< "$update_view" \
  || fail 'Stage 4 offline rollback helper row is missing'
! grep -Eq 'LKG snapshots|Independent recovery|snapshot ID|Explicit LKG' <<< "$update_view" \
  || fail 'rejected Stage 3 vocabulary returned to the active TUI'

for function_name in recovery_source_path install_recovery_entrypoint \
  recovery_available tcore_append_recovery_checks collect_recovery_state \
  recovery_status_cmd recovery_exec_cmd snapshot_create_cmd snapshot_list_cmd \
  snapshot_verify_cmd snapshot_lkg_set_cmd snapshot_retention_cmd rollback_cmd; do
  ! declare -F "$function_name" >/dev/null \
    || fail "rejected Stage 3 function remains active: $function_name"
done

expected_old_updater=42c300bab71f9f51809b4d0185e2e7b482c09873d46674e6b07edad2c44a2723
actual_updater="$(declare -f manager_check_update_cmd manager_update_cmd update_cmd | sha256sum | awk '{print $1}')"
[[ "$actual_updater" != "$expected_old_updater" ]] \
  || fail 'Stage 4 manager updater was not replaced'
declare -F stage4_create_backup stage4_manager_health stage4_rollback_exact >/dev/null \
  || fail 'Stage 4 updater functions are missing'

# Stage X-DPI keeps strict Stage 4-compatible machine semver while retaining a
# separate beta display label. Assert both identities without widening Stage 4.
actual="$(sha256sum "$PROJECT_ROOT/VERSION" | awk '{print $1}')"
[[ "$actual" == 283571d2642fc7b3befd294f45d53b896a1d54d34c86235b13151192b380606a ]] \
  || fail 'Stage X-DPI machine VERSION changed unexpectedly'
[[ "$MANAGER_VERSION" == 0.2.8 ]] \
  || fail 'Stage X-DPI embedded machine semver changed unexpectedly'
[[ "$MANAGER_RELEASE_VERSION" == 0.2.8-dpi-beta ]] \
  || fail 'Stage X-DPI display release label changed unexpectedly'

printf 'cleanup-baseline-fixture: PASS\n'
