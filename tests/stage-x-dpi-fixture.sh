#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR_UNDER_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MANAGER="$PROJECT_DIR_UNDER_TEST/twebproxy-manager.sh"
TMP="$(mktemp -d /tmp/twebproxy-stage-x-dpi.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export TWEBPROXY_NO_LOG=1
export TWEBPROXY_UI_LANGUAGE=en
export TWEBPROXY_LANGUAGE_FILE="$TMP/ui-language"
export TWEBPROXY_DPI_DIR="$TMP/etc/twebproxy/dpi"
export TWEBPROXY_DPI_NFQWS_BIN="$TMP/libexec/twebproxy-nfqws"
export TWEBPROXY_DPI_NFQWS_SUM_FILE="$TMP/libexec/twebproxy-nfqws.sha256"
export TWEBPROXY_DPI_NFQWS_SOURCE="$PROJECT_DIR_UNDER_TEST/assets/nfqws-linux-x86_64"
export TWEBPROXY_DPI_DOC_DIR="$TMP/doc"
export TWEBPROXY_NFT_BIN="$TMP/bin/nft"

mkdir -p "$TMP/bin" "$TMP/systemd" "$TMP/instances" "$TMP/libexec"
cat > "$TMP/bin/nft" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
live="${MOCK_NFT_LIVE:?}"
log="${MOCK_NFT_LOG:?}"
printf '%q ' "$@" >> "$log"; printf '\n' >> "$log"
if [[ "${1:-}" == -c && "${2:-}" == -f ]]; then
  [[ "${MOCK_NFT_CHECK_FAIL:-0}" != 1 ]] && grep -q '^table ip twebproxy_dpi {' "$3"
elif [[ "${1:-}" == -f ]]; then
  [[ "${MOCK_NFT_APPLY_FAIL:-0}" != 1 ]] || exit 1
  cp "$2" "$live"
elif [[ "${1:-}" == list && "${2:-}" == table && "${3:-}" == ip && "${4:-}" == twebproxy_dpi ]]; then
  [[ -s "$live" ]] || exit 1
  cat "$live"
elif [[ "${1:-}" == delete && "${2:-}" == table && "${3:-}" == ip && "${4:-}" == twebproxy_dpi ]]; then
  rm -f "$live"
else
  exit 2
fi
EOF
chmod 0755 "$TMP/bin/nft"
export MOCK_NFT_LIVE="$TMP/live.nft" MOCK_NFT_LOG="$TMP/nft.log"

# shellcheck source=/dev/null
source "$MANAGER"
trap - ERR
BASE_DIR="$TMP/etc/twebproxy"
INSTANCES_DIR="$TMP/instances"
LIBEXEC_DIR="$TMP/libexec"
SYSTEMD_DIR="$TMP/systemd"
DPI_DIR="$TWEBPROXY_DPI_DIR"
DPI_STATE_DIR="$DPI_DIR/scopes"
DPI_NFT_FILE="$DPI_DIR/firewall.nft"
DPI_NFT_BIN="$TWEBPROXY_NFT_BIN"
DPI_NFQWS_BIN="$TWEBPROXY_DPI_NFQWS_BIN"
DPI_NFQWS_SUM_FILE="$TWEBPROXY_DPI_NFQWS_SUM_FILE"
DPI_DOC_DIR="$TMP/doc"
DPI_FIREWALL_UNIT=twebproxy-dpi-firewall.service
DPI_NFQWS_UNIT=twebproxy-dpi-nfqws.service
UI_LANGUAGE=en

SYSTEMCTL_ACTIVE_DIR="$TMP/systemctl-active"
SYSTEMCTL_LOG="$TMP/systemctl.log"
mkdir -p "$SYSTEMCTL_ACTIVE_DIR"
# Field fix 3: the previous inline stub treated `disable` as "clear the active
# marker for every unit named", so a multi-unit `systemctl disable --now A B`
# with a missing unit file still looked like it stopped both units - which is
# exactly the defect that reached the field. Both DPI fixtures now share the
# faithful model in tests/lib/systemctl-model.sh.
# shellcheck source=/dev/null
source "$PROJECT_DIR_UNDER_TEST/tests/lib/systemctl-model.sh"
id() {
  [[ "${1:-}" == twebproxy-dpi ]] && return 0
  command id "$@"
}
useradd() { return 0; }
# Field-gate TWP-003: DPI activation now requires the scope IPv4 to be
# configured locally. These fixtures exercise transaction mechanics on a
# synthetic address, so the host-address probe is stubbed the same way
# systemctl/useradd already are. The real gate is covered by
# tests/fieldgate/tg5-dpi-scope-local-address-gate.sh.
dpi_local_ipv4_addresses() { printf '%s\n' 198.51.100.10 198.51.100.20 203.0.113.20; }

userdel() { return 0; }
getent() {
  local db="$1" host="$2"
  case "$db:$host" in
    ahostsv4:alpha.example|ahostsv4:alias.example)
      printf '198.51.100.10 STREAM %s\n198.51.100.10 DGRAM %s\n' "$host" "$host";;
    ahostsv4:beta.example) printf '203.0.113.20 STREAM %s\n' "$host";;
    ahostsv4:multi.example) printf '198.51.100.20 STREAM %s\n198.51.100.21 STREAM %s\n' "$host" "$host";;
    ahostsv6:alpha.example) printf '2001:db8::10 STREAM %s\n' "$host";;
    *) return 2;;
  esac
}

pass=0
assert() {
  local name="$1"; shift
  if "$@"; then printf 'PASS %s\n' "$name"; pass=$((pass+1))
  else printf 'FAIL %s\n' "$name" >&2; return 1; fi
}
contains() { grep -Fq -- "$2" "$1"; }
not_exists() { [[ ! -e "$1" && ! -L "$1" ]]; }

for host in alpha.example alias.example beta.example multi.example; do
  mkdir -p "$INSTANCES_DIR/$host"
  printf 'HOSTNAME=%s\nTLS_MODE=manual\nRELAY_PORT=18080\nADMIN_PORT=18081\n' "$host" > "$INSTANCES_DIR/$host/instance.env"
  chmod 0600 "$INSTANCES_DIR/$host/instance.env"
done
mkdir -p "$INSTANCES_DIR/alpha.example/profiles.d"
printf 'PROFILE_NAME=default\nCARRIER_MODE=websocket-lanes\n' > "$INSTANCES_DIR/alpha.example/profiles.d/default.env"
chmod 0600 "$INSTANCES_DIR/alpha.example/profiles.d/default.env"
carrier_hash="$(sha256sum "$INSTANCES_DIR/alpha.example/profiles.d/default.env" | awk '{print $1}')"
frontend_hash="$(sha256sum "$INSTANCES_DIR/alpha.example/instance.env" | awk '{print $1}')"

assert stock_starts_without_state not_exists "$DPI_DIR"
assert stock_starts_without_binary not_exists "$DPI_NFQWS_BIN"
assert one_ipv4_resolution test "$(dpi_resolve_ipv4 alpha.example)" = 198.51.100.10
if dpi_ipv4_valid 10.0.0.1; then echo 'FAIL private_ipv4_rejected' >&2; exit 1; else echo 'PASS private_ipv4_rejected'; pass=$((pass+1)); fi
if dpi_ipv4_valid 198.051.100.10; then echo 'FAIL ambiguous_ipv4_rejected' >&2; exit 1; else echo 'PASS ambiguous_ipv4_rejected'; pass=$((pass+1)); fi
if dpi_resolve_ipv4 multi.example >/dev/null 2>&1; then echo 'FAIL multiple_ipv4_fail_closed' >&2; exit 1; else echo 'PASS multiple_ipv4_fail_closed'; pass=$((pass+1)); fi
assert shared_ipv4_inventory test "$(dpi_hosts_for_ipv4 198.51.100.10 | paste -sd, -)" = alias.example,alpha.example
assert ipv6_detected dpi_host_has_ipv6 alpha.example

rules_dir="$TMP/rules-state"; mkdir -p "$rules_dir"; chmod 0700 "$rules_dir"
for mode in window1152 mss88 nfqws window1152_nfqws mss88_nfqws; do
  rm -f "$rules_dir"/*.env
  dpi_write_scope_state "$rules_dir" 198.51.100.10 "$mode" alpha.example
  out="$TMP/$mode.nft"; dpi_render_rules "$rules_dir" "$out"
  assert "${mode}_exact_scope" contains "$out" 'ip saddr 198.51.100.10 tcp sport 443'
  case "$mode" in
    window1152|window1152_nfqws) assert "${mode}_window_rule" contains "$out" 'tcp window set 1152';;
    mss88|mss88_nfqws) assert "${mode}_mss_rule" contains "$out" 'tcp option maxseg size set 88';;
  esac
  case "$mode" in
    nfqws|*_nfqws)
      assert "${mode}_early_reply_bound" contains "$out" 'ct reply packets 1-6'
      assert "${mode}_queue_bypass" contains "$out" 'queue num 217 bypass';;
    *) if grep -q 'queue num' "$out"; then echo "FAIL ${mode}_no_queue" >&2; exit 1; else echo "PASS ${mode}_no_queue"; pass=$((pass+1)); fi;;
  esac
done
window_line="$(grep -n 'window set' "$TMP/window1152_nfqws.nft" | cut -d: -f1)"
queue_line="$(grep -n 'queue num' "$TMP/window1152_nfqws.nft" | cut -d: -f1)"
assert combined_window_precedes_queue test "$window_line" -lt "$queue_line"

ln -s /nonexistent "$rules_dir/203.0.113.20.env"
if dpi_render_rules "$rules_dir" "$TMP/unsafe.nft" 2>/dev/null; then echo 'FAIL dangling_state_symlink_rejected' >&2; exit 1; else echo 'PASS dangling_state_symlink_rejected'; pass=$((pass+1)); fi
rm -f "$rules_dir/203.0.113.20.env"

dpi_transaction_set 198.51.100.10 window1152 alpha.example
assert window_state_persisted contains "$DPI_STATE_DIR/198.51.100.10.env" 'MODE=window1152'
assert window_live_rule contains "$MOCK_NFT_LIVE" 'tcp window set 1152'
assert window_has_no_nfqws_binary not_exists "$DPI_NFQWS_BIN"
row="$(dpi_mode_for_host alias.example)"
assert shared_host_reports_address_truth test "$row" = $'198.51.100.10\twindow1152'
before_state="$(sha256sum "$DPI_STATE_DIR/198.51.100.10.env" | awk '{print $1}')"
if (dpi_set_cmd alias.example mss88 >/dev/null 2>&1); then echo 'FAIL shared_scope_requires_confirmation' >&2; exit 1; else echo 'PASS shared_scope_requires_confirmation'; pass=$((pass+1)); fi
assert rejected_shared_scope_unchanged test "$(sha256sum "$DPI_STATE_DIR/198.51.100.10.env" | awk '{print $1}')" = "$before_state"

dpi_transaction_set 198.51.100.10 mss88 alias.example
assert same_ipv4_has_one_mode test "$(find "$DPI_STATE_DIR" -maxdepth 1 -type f -name '*.env' | wc -l)" -eq 1
assert same_ipv4_mode_switches_exactly contains "$DPI_STATE_DIR/198.51.100.10.env" 'MODE=mss88'
dpi_transaction_set 198.51.100.10 window1152 alpha.example

before_state="$(sha256sum "$DPI_STATE_DIR/198.51.100.10.env" | awk '{print $1}')"
before_live="$(sha256sum "$MOCK_NFT_LIVE" | awk '{print $1}')"
export TWEBPROXY_DPI_TEST_FAIL_POINT=after_firewall
if dpi_transaction_set 198.51.100.10 mss88 alpha.example; then echo 'FAIL transaction_failure_reported' >&2; exit 1; else echo 'PASS transaction_failure_reported'; pass=$((pass+1)); fi
unset TWEBPROXY_DPI_TEST_FAIL_POINT
assert rollback_state_exact test "$(sha256sum "$DPI_STATE_DIR/198.51.100.10.env" | awk '{print $1}')" = "$before_state"
assert rollback_live_exact test "$(sha256sum "$MOCK_NFT_LIVE" | awk '{print $1}')" = "$before_live"

export MOCK_NFT_CHECK_FAIL=1
if dpi_transaction_set 198.51.100.10 mss88 alpha.example; then echo 'FAIL invalid_nft_preflight_rejected' >&2; exit 1; else echo 'PASS invalid_nft_preflight_rejected'; pass=$((pass+1)); fi
unset MOCK_NFT_CHECK_FAIL
assert invalid_nft_preflight_no_state_mutation test "$(sha256sum "$DPI_STATE_DIR/198.51.100.10.env" | awk '{print $1}')" = "$before_state"

chmod 0644 "$DPI_NFT_BIN"
if dpi_transaction_set 198.51.100.10 mss88 alpha.example; then echo 'FAIL missing_nft_binary_rejected' >&2; exit 1; else echo 'PASS missing_nft_binary_rejected'; pass=$((pass+1)); fi
chmod 0755 "$DPI_NFT_BIN"
assert missing_nft_no_state_mutation test "$(sha256sum "$DPI_STATE_DIR/198.51.100.10.env" | awk '{print $1}')" = "$before_state"

saved_source="$TWEBPROXY_DPI_NFQWS_SOURCE"
export TWEBPROXY_DPI_NFQWS_SOURCE="$TMP/missing-nfqws"
if dpi_transaction_set 198.51.100.10 nfqws alpha.example; then echo 'FAIL missing_nfqws_rejected' >&2; exit 1; else echo 'PASS missing_nfqws_rejected'; pass=$((pass+1)); fi
export TWEBPROXY_DPI_NFQWS_SOURCE="$saved_source"
assert missing_nfqws_rolls_back_state test "$(sha256sum "$DPI_STATE_DIR/198.51.100.10.env" | awk '{print $1}')" = "$before_state"

export MOCK_NFT_APPLY_FAIL=1
if dpi_transaction_set 198.51.100.10 mss88 alpha.example; then echo 'FAIL failed_apply_reported' >&2; exit 1; else echo 'PASS failed_apply_reported'; pass=$((pass+1)); fi
unset MOCK_NFT_APPLY_FAIL
assert failed_rollback_falls_back_stock not_exists "$DPI_STATE_DIR/198.51.100.10.env"
assert failed_rollback_removes_queue_table not_exists "$MOCK_NFT_LIVE"
dpi_transaction_set 198.51.100.10 window1152 alpha.example

dpi_transaction_set 198.51.100.10 nfqws alpha.example
assert nfqws_state_persisted contains "$DPI_STATE_DIR/198.51.100.10.env" 'MODE=nfqws'
assert nfqws_binary_exact test "$(sha256sum "$DPI_NFQWS_BIN" | awk '{print $1}')" = "$DPI_NFQWS_SHA256"
assert nfqws_checksum_manifest sha256sum -c --status "$DPI_NFQWS_SUM_FILE"
assert nfqws_service_active systemctl is-active --quiet "$DPI_NFQWS_UNIT"
assert nfqws_unit_pinned contains "$SYSTEMD_DIR/$DPI_NFQWS_UNIT" '--dpi-desync=fake,multisplit'
assert nfqws_unit_capability_bound contains "$SYSTEMD_DIR/$DPI_NFQWS_UNIT" 'CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW'
assert nfqueue_process_death_is_bypass contains "$MOCK_NFT_LIVE" 'queue num 217 bypass'
rm -f "$SYSTEMCTL_ACTIVE_DIR/$DPI_NFQWS_UNIT"
collect_status alpha.example
last=$(( ${#TCORE_IDS[@]} - 1 ))
assert crashed_nfqws_status_is_error test "${TCORE_STATUSES[$last]}" = ERROR
dpi_repair_all
assert crashed_nfqws_repaired systemctl is-active --quiet "$DPI_NFQWS_UNIT"
rm -f "$MOCK_NFT_LIVE"
dpi_repair_all
assert missing_live_table_repaired contains "$MOCK_NFT_LIVE" 'queue num 217 bypass'
rm -f "$DPI_NFQWS_BIN"
dpi_repair_all
assert missing_binary_reinstalled test "$(sha256sum "$DPI_NFQWS_BIN" | awk '{print $1}')" = "$DPI_NFQWS_SHA256"

printf X >> "$DPI_NFQWS_BIN"
if dpi_install_nfqws >/dev/null 2>&1; then echo 'FAIL corrupt_installed_binary_fail_closed' >&2; exit 1; else echo 'PASS corrupt_installed_binary_fail_closed'; pass=$((pass+1)); fi
if dpi_repair_all >/dev/null 2>&1; then echo 'FAIL corrupt_binary_repair_reports_fallback' >&2; exit 1; else echo 'PASS corrupt_binary_repair_reports_fallback'; pass=$((pass+1)); fi
assert corrupt_binary_fallback_removes_state not_exists "$DPI_STATE_DIR/198.51.100.10.env"
assert corrupt_binary_fallback_removes_live_table not_exists "$MOCK_NFT_LIVE"
if systemctl is-active --quiet "$DPI_NFQWS_UNIT"; then echo 'FAIL corrupt_binary_fallback_stops_service' >&2; exit 1; else echo 'PASS corrupt_binary_fallback_stops_service'; pass=$((pass+1)); fi
assert corrupt_binary_fallback_removes_binary not_exists "$DPI_NFQWS_BIN"
assert corrupt_binary_fallback_removes_checksum not_exists "$DPI_NFQWS_SUM_FILE"
assert corrupt_binary_fallback_removes_license not_exists "$DPI_DOC_DIR/nfqws-LICENSE.txt"
dpi_transaction_set 198.51.100.10 nfqws alpha.example
assert corrupt_binary_reenable_reacquires_verified_binary test \
  "$(sha256sum "$DPI_NFQWS_BIN" | awk '{print $1}')" = "$DPI_NFQWS_SHA256"
assert corrupt_binary_reenable_recreates_valid_checksum sha256sum -c --status "$DPI_NFQWS_SUM_FILE"
assert corrupt_binary_reenable_starts_service systemctl is-active --quiet "$DPI_NFQWS_UNIT"

printf 'unrelated-nfqws-target\n' > "$TMP/unrelated-nfqws-target"
unrelated_target_hash="$(sha256sum "$TMP/unrelated-nfqws-target" | awk '{print $1}')"
rm -f -- "$DPI_NFQWS_BIN"
ln -s "$TMP/unrelated-nfqws-target" "$DPI_NFQWS_BIN"
dpi_cleanup_nfqws_runtime
assert runtime_symlink_unlinked_without_following not_exists "$DPI_NFQWS_BIN"
assert runtime_symlink_target_unchanged test \
  "$(sha256sum "$TMP/unrelated-nfqws-target" | awk '{print $1}')" = "$unrelated_target_hash"
assert runtime_symlink_cleanup_removes_checksum not_exists "$DPI_NFQWS_SUM_FILE"
dpi_repair_all
assert runtime_symlink_cleanup_repair_reacquires_verified_binary test \
  "$(sha256sum "$DPI_NFQWS_BIN" | awk '{print $1}')" = "$DPI_NFQWS_SHA256"

dpi_transaction_disable_ip 198.51.100.10
assert disable_removes_state not_exists "$DPI_STATE_DIR/198.51.100.10.env"
assert disable_removes_live_table not_exists "$MOCK_NFT_LIVE"
assert disable_removes_exact_binary not_exists "$DPI_NFQWS_BIN"
assert disable_removes_units not_exists "$SYSTEMD_DIR/$DPI_FIREWALL_UNIT"
assert disable_removes_nfqws_license not_exists "$DPI_DOC_DIR/nfqws-LICENSE.txt"
assert carrier_state_unchanged test "$(sha256sum "$INSTANCES_DIR/alpha.example/profiles.d/default.env" | awk '{print $1}')" = "$carrier_hash"
assert frontend_state_unchanged test "$(sha256sum "$INSTANCES_DIR/alpha.example/instance.env" | awk '{print $1}')" = "$frontend_hash"

for mode in window1152 mss88 nfqws window1152_nfqws mss88_nfqws; do
  dpi_transaction_set 198.51.100.10 "$mode" alpha.example
  dpi_transaction_set 198.51.100.10 "$mode" alpha.example
  row="$(dpi_mode_for_host alpha.example)"
  assert "${mode}_set_status_persist" test "$row" = "198.51.100.10"$'\t'"$mode"
  dpi_reconcile_runtime
  assert "${mode}_reload_persists" contains "$DPI_STATE_DIR/198.51.100.10.env" "MODE=$mode"
  dpi_transaction_disable_ip 198.51.100.10
  dpi_transaction_disable_ip 198.51.100.10
  assert "${mode}_repeated_disable_stock" not_exists "$DPI_STATE_DIR/198.51.100.10.env"
done

dpi_transaction_set 203.0.113.20 mss88 beta.example
rm -rf "$INSTANCES_DIR/beta.example"
dpi_prune_orphan_state
assert orphan_scope_removed not_exists "$DPI_STATE_DIR/203.0.113.20.env"
dpi_reconcile_runtime
assert orphan_cleanup_returns_stock not_exists "$MOCK_NFT_LIVE"

printf 'unrelated-firewall-state\n' > "$TMP/unrelated-firewall.marker"
mkdir -p "$TMP/unrelated-system/usr/local/bin"
printf 'unrelated-system-nfqws\n' > "$TMP/unrelated-system/usr/local/bin/nfqws"
unrelated_system_nfqws_hash="$(sha256sum "$TMP/unrelated-system/usr/local/bin/nfqws" | awk '{print $1}')"
dpi_transaction_set 198.51.100.10 nfqws alpha.example
printf X >> "$DPI_NFQWS_BIN"
dpi_full_uninstall
assert full_uninstall_removes_dpi_state not_exists "$DPI_DIR"
assert full_uninstall_removes_dpi_table not_exists "$MOCK_NFT_LIVE"
assert corrupt_binary_full_uninstall_removes_binary not_exists "$DPI_NFQWS_BIN"
assert corrupt_binary_full_uninstall_removes_checksum not_exists "$DPI_NFQWS_SUM_FILE"
assert corrupt_binary_full_uninstall_removes_license not_exists "$DPI_DOC_DIR/nfqws-LICENSE.txt"
assert full_uninstall_preserves_unrelated_firewall test -f "$TMP/unrelated-firewall.marker"
assert full_uninstall_preserves_unrelated_system_nfqws test \
  "$(sha256sum "$TMP/unrelated-system/usr/local/bin/nfqws" | awk '{print $1}')" = "$unrelated_system_nfqws_hash"

for locale in C POSIX C.UTF-8; do
  UI_LANGUAGE=en
  en_view="$(LC_ALL="$locale" dpi_list_methods_cmd)"
  if ui_contains_cyrillic "$en_view"; then echo "FAIL dpi_english_no_cyrillic_$locale" >&2; exit 1; else echo "PASS dpi_english_no_cyrillic_$locale"; pass=$((pass+1)); fi
  grep -Fq 'No traffic modification; production default.' <<< "$en_view"
  grep -Fq 'pinned commit 87e058624c72863db53bdaf7fb6f16576dddb6ab' <<< "$en_view"
  UI_LANGUAGE=ru
  ru_view="$(LC_ALL="$locale" dpi_list_methods_cmd)"
  ui_contains_cyrillic "$ru_view"
  if LC_ALL=C grep -Eqi '\b(live|legacy|lifecycle|Audit|renewal|Offline|helper|receive window|traffic|scope|shared)\b' <<< "$ru_view"; then
    echo "FAIL dpi_russian_mixed_prose_$locale" >&2; exit 1
  else echo "PASS dpi_russian_mixed_prose_$locale"; pass=$((pass+1)); fi
  grep -Fq 'Без изменения трафика; производственный режим по умолчанию.' <<< "$ru_view"
done
UI_LANGUAGE=en

printf 'PASS total=%s mandatory_skips=0\n' "$pass"
