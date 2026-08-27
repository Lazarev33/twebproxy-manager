#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR_UNDER_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/twebproxy-stage-x-dpi-installed.XXXXXX)"
trap 'rm -rf --one-file-system -- "$TMP"' EXIT

export TWEBPROXY_NO_LOG=1
export TWEBPROXY_UI_LANGUAGE=en
unset TWEBPROXY_DPI_NFQWS_SOURCE

pass=0
assert() {
  local name="$1"; shift
  if "$@"; then
    printf 'PASS %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL %s\n' "$name" >&2
    return 1
  fi
}
contains() { grep -Fq -- "$2" "$1"; }
not_exists() { [[ ! -e "$1" && ! -L "$1" ]]; }

# Construct a disposable release extraction, install only the manager copies in
# the same shape as production, and then remove the extraction completely.
release_dir="$TMP/extracted/TWebProxy-Manager-v0.2.8-dpi-beta"
install_root="$TMP/installed-root"
archive_tree="$TMP/archive-tree/zapret-v72.13"
good_archive="$TMP/zapret-v72.13.tar.gz"
bad_archive="$TMP/zapret-v72.13-corrupt.tar.gz"

install -d "$release_dir/assets" \
  "$archive_tree/binaries/linux-x86_64" "$archive_tree/docs" \
  "$install_root/usr/local/sbin" "$install_root/opt/twebproxy-manager"
install -m 0755 "$PROJECT_DIR_UNDER_TEST/twebproxy-manager.sh" "$release_dir/twebproxy-manager.sh"
install -m 0755 "$PROJECT_DIR_UNDER_TEST/assets/nfqws-linux-x86_64" \
  "$release_dir/assets/nfqws-linux-x86_64"
install -m 0644 "$PROJECT_DIR_UNDER_TEST/assets/nfqws-LICENSE.txt" \
  "$release_dir/assets/nfqws-LICENSE.txt"
install -m 0755 "$release_dir/assets/nfqws-linux-x86_64" \
  "$archive_tree/binaries/linux-x86_64/nfqws"
install -m 0644 "$release_dir/assets/nfqws-LICENSE.txt" "$archive_tree/docs/LICENSE.txt"
tar -C "$TMP/archive-tree" -czf "$good_archive" zapret-v72.13

# shellcheck source=/dev/null
source "$release_dir/twebproxy-manager.sh"
trap - ERR
PROJECT_DIR="$install_root/opt/twebproxy-manager"
PROJECT_MANAGER_COPY="$PROJECT_DIR/twebproxy-manager.sh"
MANAGER_BIN="$install_root/usr/local/sbin/twebproxy"
LOG_DIR="$PROJECT_DIR/logs"
LOG_MANAGER_DIR="$LOG_DIR/manager"
LOG_RUNTIME_DIR="$LOG_DIR/runtime"
LOG_BUNDLE_DIR="$LOG_DIR/bundles"
LOG_FULL_DIR="$LOG_DIR/full"
install_manager_copy

assert installed_usr_local_manager test -x "$MANAGER_BIN"
assert installed_opt_manager test -x "$PROJECT_MANAGER_COPY"
assert install_does_not_create_usr_assets not_exists "$install_root/usr/local/sbin/assets"
assert install_does_not_create_opt_assets not_exists "$PROJECT_DIR/assets"

rm -rf --one-file-system -- "$release_dir"
assert original_release_extraction_removed not_exists "$release_dir"

# Re-source from the installed /usr/local/sbin copy so BASH_SOURCE and therefore
# adjacent-asset discovery exactly model the production command path.
# shellcheck source=/dev/null
source "$MANAGER_BIN"
trap - ERR

BASE_DIR="$install_root/etc/twebproxy"
INSTANCES_DIR="$BASE_DIR/instances"
LIBEXEC_DIR="$install_root/usr/local/libexec/twebproxy"
SYSTEMD_DIR="$install_root/etc/systemd/system"
DPI_DIR="$BASE_DIR/dpi"
DPI_STATE_DIR="$DPI_DIR/scopes"
DPI_NFT_FILE="$DPI_DIR/firewall.nft"
DPI_NFT_BIN="$TMP/bin/nft"
DPI_NFQWS_BIN="$LIBEXEC_DIR/twebproxy-nfqws"
DPI_NFQWS_SUM_FILE="$LIBEXEC_DIR/twebproxy-nfqws.sha256"
DPI_DOC_DIR="$install_root/usr/share/doc/twebproxy"
DPI_FIREWALL_UNIT=twebproxy-dpi-firewall.service
DPI_NFQWS_UNIT=twebproxy-dpi-nfqws.service
LANGUAGE_FILE="$BASE_DIR/ui-language"
UI_LANGUAGE=en

install -d "$TMP/bin" "$SYSTEMD_DIR" "$INSTANCES_DIR/alpha.example" "$LIBEXEC_DIR"
cat > "$DPI_NFT_BIN" <<'NFT_MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
live="${MOCK_NFT_LIVE:?}"
if [[ "${1:-}" == -c && "${2:-}" == -f ]]; then
  grep -q '^table ip twebproxy_dpi {' "$3"
elif [[ "${1:-}" == -f ]]; then
  cp "$2" "$live"
elif [[ "${1:-}" == list && "${2:-}" == table && "${3:-}" == ip && "${4:-}" == twebproxy_dpi ]]; then
  [[ -s "$live" ]] || exit 1
  cat "$live"
elif [[ "${1:-}" == delete && "${2:-}" == table && "${3:-}" == ip && "${4:-}" == twebproxy_dpi ]]; then
  rm -f "$live"
else
  exit 2
fi
NFT_MOCK
chmod 0755 "$DPI_NFT_BIN"
export MOCK_NFT_LIVE="$TMP/live.nft"

SYSTEMCTL_ACTIVE_DIR="$TMP/systemctl-active"
SYSTEMCTL_LOG="$TMP/systemctl.log"
install -d "$SYSTEMCTL_ACTIVE_DIR"
systemctl() {
  local command="${1:-}" unit=""
  printf '%q ' "$@" >> "$SYSTEMCTL_LOG"; printf '\n' >> "$SYSTEMCTL_LOG"
  shift || true
  case "$command" in
    daemon-reload) return 0;;
    enable)
      while (($#)); do
        case "$1" in --now) ;; *) unit="$1";; esac
        shift
      done
      [[ -n "$unit" ]] && : > "$SYSTEMCTL_ACTIVE_DIR/$unit"
      ;;
    restart) unit="${1:-}"; : > "$SYSTEMCTL_ACTIVE_DIR/$unit";;
    disable)
      while (($#)); do
        case "$1" in --now) ;; *) rm -f "$SYSTEMCTL_ACTIVE_DIR/$1";; esac
        shift
      done
      ;;
    is-active)
      [[ "${1:-}" == --quiet ]] && shift
      [[ -f "$SYSTEMCTL_ACTIVE_DIR/${1:-}" ]]
      ;;
    *) return 0;;
  esac
}
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
  local db="${1:-}" host="${2:-}"
  case "$db:$host" in
    ahostsv4:alpha.example) printf '198.51.100.10 STREAM %s\n' "$host";;
    *) return 2;;
  esac
}

printf 'HOSTNAME=alpha.example\nTLS_MODE=manual\nRELAY_PORT=18080\nADMIN_PORT=18081\n' \
  > "$INSTANCES_DIR/alpha.example/instance.env"
chmod 0600 "$INSTANCES_DIR/alpha.example/instance.env"

# The mock serves bytes for the exact production URL; the manager still owns
# archive member selection and all hash/version/argument verification.
MOCK_NFQWS_ARCHIVE="$good_archive"
MOCK_CURL_LOG="$TMP/curl.log"
curl() {
  local output="" url=""
  while (($#)); do
    case "$1" in
      -o) output="${2:-}"; shift 2;;
      --connect-timeout|--max-time|--retry|--max-filesize|--proto|--proto-redir|--tlsv1.2|-H)
        [[ "$1" == --tlsv1.2 ]] && { shift; continue; }
        shift 2
        ;;
      http://*|https://*) url="$1"; shift;;
      *) shift;;
    esac
  done
  [[ -n "$output" && "$url" == "$DPI_NFQWS_RELEASE_ARCHIVE_URL" ]] || return 2
  printf '%s\n' "$url" >> "$MOCK_CURL_LOG"
  cp "$MOCK_NFQWS_ARCHIVE" "$output"
}

assert source_override_is_unset test -z "${TWEBPROXY_DPI_NFQWS_SOURCE:-}"
resolved="$(dpi_bundled_nfqws)"
assert installed_adjacent_asset_absent not_exists "$resolved"
assert stock_has_no_state not_exists "$DPI_DIR"
assert stock_has_no_runtime_binary not_exists "$DPI_NFQWS_BIN"

# Prove downloaded bytes with the wrong binary hash are rejected before their
# content can execute and before any runtime artifact is published.
bad_tree="$TMP/bad-tree/zapret-v72.13"
install -d "$bad_tree/binaries/linux-x86_64" "$bad_tree/docs"
cat > "$bad_tree/binaries/linux-x86_64/nfqws" <<EOF
#!/usr/bin/env bash
printf executed > $(printf '%q' "$TMP/unverified-executed")
EOF
chmod 0755 "$bad_tree/binaries/linux-x86_64/nfqws"
install -m 0644 "$PROJECT_DIR_UNDER_TEST/assets/nfqws-LICENSE.txt" "$bad_tree/docs/LICENSE.txt"
tar -C "$TMP/bad-tree" -czf "$bad_archive" zapret-v72.13
MOCK_NFQWS_ARCHIVE="$bad_archive"
if dpi_install_nfqws >/dev/null 2>&1; then
  printf 'FAIL unverified_download_rejected\n' >&2
  exit 1
else
  printf 'PASS unverified_download_rejected\n'
  pass=$((pass + 1))
fi
assert unverified_download_not_executed not_exists "$TMP/unverified-executed"
assert unverified_download_not_installed not_exists "$DPI_NFQWS_BIN"
MOCK_NFQWS_ARCHIVE="$good_archive"

for mode in nfqws window1152_nfqws mss88_nfqws; do
  dpi_transaction_set 198.51.100.10 "$mode" alpha.example
  assert "${mode}_state_active" contains "$DPI_STATE_DIR/198.51.100.10.env" "MODE=$mode"
  assert "${mode}_runtime_hash" test \
    "$(sha256sum "$DPI_NFQWS_BIN" | awk '{print $1}')" = "$DPI_NFQWS_SHA256"
  assert "${mode}_checksum_manifest" sha256sum -c --status "$DPI_NFQWS_SUM_FILE"
  assert "${mode}_service_started" systemctl is-active --quiet "$DPI_NFQWS_UNIT"
  assert "${mode}_systemctl_start_requested" contains "$SYSTEMCTL_LOG" \
    "enable --now $DPI_NFQWS_UNIT"
  assert "${mode}_installed_source_has_no_assets" not_exists "$install_root/usr/local/sbin/assets"
  dpi_transaction_disable_ip 198.51.100.10
  assert "${mode}_disable_returns_stock" not_exists "$DPI_STATE_DIR/198.51.100.10.env"
  assert "${mode}_disable_removes_runtime" not_exists "$DPI_NFQWS_BIN"
done

dpi_transaction_set 198.51.100.10 nfqws alpha.example
printf X >> "$DPI_NFQWS_BIN"
if dpi_repair_all >/dev/null 2>&1; then
  printf 'FAIL installed_corrupt_binary_repair_reports_fallback\n' >&2
  exit 1
else
  printf 'PASS installed_corrupt_binary_repair_reports_fallback\n'
  pass=$((pass + 1))
fi
assert installed_corrupt_fallback_returns_stock not_exists "$DPI_STATE_DIR/198.51.100.10.env"
assert installed_corrupt_fallback_removes_binary not_exists "$DPI_NFQWS_BIN"
assert installed_corrupt_fallback_removes_checksum not_exists "$DPI_NFQWS_SUM_FILE"
assert installed_corrupt_fallback_removes_license not_exists "$DPI_DOC_DIR/nfqws-LICENSE.txt"
dpi_transaction_set 198.51.100.10 nfqws alpha.example
assert installed_corrupt_reenable_reacquires_verified_binary test \
  "$(sha256sum "$DPI_NFQWS_BIN" | awk '{print $1}')" = "$DPI_NFQWS_SHA256"
assert installed_corrupt_reenable_recreates_valid_checksum sha256sum -c --status "$DPI_NFQWS_SUM_FILE"

mkdir -p "$TMP/unrelated-system/usr/local/bin"
printf 'unrelated-system-nfqws\n' > "$TMP/unrelated-system/usr/local/bin/nfqws"
unrelated_system_nfqws_hash="$(sha256sum "$TMP/unrelated-system/usr/local/bin/nfqws" | awk '{print $1}')"
printf X >> "$DPI_NFQWS_BIN"
dpi_full_uninstall
assert installed_corrupt_full_uninstall_removes_state not_exists "$DPI_DIR"
assert installed_corrupt_full_uninstall_removes_binary not_exists "$DPI_NFQWS_BIN"
assert installed_corrupt_full_uninstall_removes_checksum not_exists "$DPI_NFQWS_SUM_FILE"
assert installed_corrupt_full_uninstall_removes_license not_exists "$DPI_DOC_DIR/nfqws-LICENSE.txt"
assert installed_corrupt_full_uninstall_preserves_unrelated_nfqws test \
  "$(sha256sum "$TMP/unrelated-system/usr/local/bin/nfqws" | awk '{print $1}')" = "$unrelated_system_nfqws_hash"

assert each_nfqws_mode_and_corrupt_recovery_reacquired test "$(wc -l < "$MOCK_CURL_LOG")" -eq 6
assert each_nfqws_mode_requested_start test \
  "$(grep -Fc "enable --now $DPI_NFQWS_UNIT" "$SYSTEMCTL_LOG")" -eq 5
assert machine_VERSION_is_stage4_semver test "$(cat "$PROJECT_DIR_UNDER_TEST/VERSION")" = 0.2.8
assert machine_VERSION_parser_accepts valid_manager_version "$(cat "$PROJECT_DIR_UNDER_TEST/VERSION")"
assert display_release_label_preserved test "$MANAGER_RELEASE_VERSION" = 0.2.8-dpi-beta

printf 'PASS total=%s mandatory_skips=0\n' "$pass"
printf 'stage-x-dpi-installed-asset-fixture: PASS\n'
