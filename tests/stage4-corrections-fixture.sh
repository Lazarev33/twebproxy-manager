#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER="$ROOT/twebproxy-manager.sh"
WORK="$(mktemp -d /tmp/twebproxy-stage4-corrections.XXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT

fail() { printf 'stage4-corrections-fixture: FAIL [%s]: %s\n' "${CURRENT_CASE:-setup}" "$*" >&2; exit 1; }
pass() { printf 'Stage4-%s: PASS\n' "$CURRENT_CASE"; }
assert() { "$@" || fail "assertion failed: $*"; }

# shellcheck disable=SC1090
source "$MANAGER"
trap - ERR
disable_colors

make_fake_manager() {
  local path="$1"
  install -d -o root -g root -m 0700 "$(dirname -- "$path")"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
MANAGER_VERSION="0.2.8"
if [[ "${1:-}" == "--help" ]]; then
  printf 'TWebProxy Manager v%s\n' "$MANAGER_VERSION"
  exit 0
fi
if [[ "${1:-}" == "--json" && "${2:-}" == "overview" ]]; then
  printf '{"schema_version":"twebproxy.output.v1","command":"overview","overall":"ERROR","data":{"manager_version":"%s"}}\n' "$MANAGER_VERSION"
  exit 0
fi
exit 2
EOF
  chmod 0755 "$path"
  chown root:root "$path"
  bash -n "$path"
}

setup_case() {
  local name="$1" install_helper="${2:-yes}"
  CASE_DIR="$WORK/$name"
  install -d -o root -g root -m 0700 \
    "$CASE_DIR" "$CASE_DIR/usr" "$CASE_DIR/opt" "$CASE_DIR/libexec" \
    "$CASE_DIR/etc" "$CASE_DIR/var/lib" "$CASE_DIR/run/lock"
  BASE_DIR="$CASE_DIR/etc"
  GLOBAL_ENV="$BASE_DIR/global.env"
  PROJECT_DIR="$CASE_DIR/opt"
  PROJECT_MANAGER_COPY="$PROJECT_DIR/twebproxy-manager.sh"
  MANAGER_BIN="$CASE_DIR/usr/twebproxy"
  LIBEXEC_DIR="$CASE_DIR/libexec"
  UPDATE_RESTORE_HELPER="$LIBEXEC_DIR/restore-update-backup"
  UPDATE_BACKUP_PARENT="$CASE_DIR/var/lib/twebproxy"
  UPDATE_BACKUP_ROOT="$UPDATE_BACKUP_PARENT/update-backups"
  UPDATE_LOCK_FILE="$CASE_DIR/run/lock/twebproxy-manager-update.lock"
  UPDATE_CACHE_FILE="$PROJECT_DIR/update-check.env"
  UPDATE_BACKUP_RETENTION=4
  STAGE4_UPDATE_LOCK_FD=""
  make_fake_manager "$MANAGER_BIN"
  install -o root -g root -m 0755 "$MANAGER_BIN" "$PROJECT_MANAGER_COPY"
  if [[ "$install_helper" == yes ]]; then
    stage4_install_restore_helper yes || fail 'helper bootstrap failed'
  fi
}

verified_count() {
  bash -c 'source "$1"; s4_collect_valid_ids | wc -l' _ "$UPDATE_RESTORE_HELPER"
}

CURRENT_CASE=U-dangling-helper-symlink-fail-closed
setup_case U no
dangling_target="/nonexistent/twebproxy-stage4-helper-target"
ln -s "$dangling_target" "$UPDATE_RESTORE_HELPER"
before_inode="$(stat -c '%i' "$UPDATE_RESTORE_HELPER")"
before_target="$(readlink "$UPDATE_RESTORE_HELPER")"
manager_hash="$(sha256sum "$MANAGER_BIN" | awk '{print $1}')"
project_hash="$(sha256sum "$PROJECT_MANAGER_COPY" | awk '{print $1}')"

set +e
stage4_install_restore_helper yes
bootstrap_rc=$?
set -e
assert test "$bootstrap_rc" -ne 0
assert test -L "$UPDATE_RESTORE_HELPER"
assert test "$(stat -c '%i' "$UPDATE_RESTORE_HELPER")" = "$before_inode"
assert test "$(readlink "$UPDATE_RESTORE_HELPER")" = "$before_target"

fetch_manager_update_info() { : > "$CASE_DIR/fetch-called"; return 1; }
set +e
( manager_update_cmd --force ) > "$CASE_DIR/update.out" 2>&1
update_rc=$?
set -e
assert test "$update_rc" -ne 0
assert test ! -e "$CASE_DIR/fetch-called"
assert test ! -e "$UPDATE_BACKUP_ROOT"
assert test -L "$UPDATE_RESTORE_HELPER"
assert test "$(stat -c '%i' "$UPDATE_RESTORE_HELPER")" = "$before_inode"
assert test "$(readlink "$UPDATE_RESTORE_HELPER")" = "$dangling_target"
assert test "$(sha256sum "$MANAGER_BIN" | awk '{print $1}')" = "$manager_hash"
assert test "$(sha256sum "$PROJECT_MANAGER_COPY" | awk '{print $1}')" = "$project_hash"
pass

CURRENT_CASE=V-protected-current-backup-retention
setup_case V
FAKE_ISO=2026-01-01T00:00:00Z
FAKE_ID=20260101T000000Z
date() {
  if [[ "$*" == '-u +%Y-%m-%dT%H:%M:%SZ' ]]; then printf '%s' "$FAKE_ISO"
  elif [[ "$*" == '-u +%Y%m%dT%H%M%SZ' ]]; then printf '%s' "$FAKE_ID"
  else command date "$@"; fi
}
current_id="$(stage4_create_backup 0.2.8)"
assert stage4_verify_backup "$UPDATE_BACKUP_ROOT/$current_id" "$current_id" published
other_ids=()
for day in 02 03 04 05; do
  FAKE_ISO="2026-01-${day}T00:00:00Z"
  FAKE_ID="202601${day}T000000Z"
  other_ids+=("$(stage4_create_backup 0.2.8)")
done
unset -f date
for id in "${other_ids[@]}"; do
  assert stage4_verify_backup "$UPDATE_BACKUP_ROOT/$id" "$id" published
  [[ "$id" > "$current_id" ]] || fail "other ID does not sort newer: $id"
done
install -d -o root -g root -m 0700 "$UPDATE_BACKUP_ROOT/.incomplete.keep"
install -d -o root -g root -m 0700 "$UPDATE_BACKUP_ROOT/not-a-valid-backup"

assert stage4_prune_backups "$current_id"
assert stage4_verify_backup "$UPDATE_BACKUP_ROOT/$current_id" "$current_id" published
assert test "$(verified_count)" -eq 4
assert test ! -e "$UPDATE_BACKUP_ROOT/${other_ids[0]}"
for id in "${other_ids[@]:1}"; do
  assert stage4_verify_backup "$UPDATE_BACKUP_ROOT/$id" "$id" published
done
assert test -d "$UPDATE_BACKUP_ROOT/.incomplete.keep"
assert test -d "$UPDATE_BACKUP_ROOT/not-a-valid-backup"

# No protection argument retains the normal four newest verified backups.
setup_case V-no-protect
FAKE_ISO=2026-02-01T00:00:00Z
FAKE_ID=20260201T000000Z
date() {
  if [[ "$*" == '-u +%Y-%m-%dT%H:%M:%SZ' ]]; then printf '%s' "$FAKE_ISO"
  elif [[ "$*" == '-u +%Y%m%dT%H%M%SZ' ]]; then printf '%s' "$FAKE_ID"
  else command date "$@"; fi
}
all_ids=()
for day in 01 02 03 04 05; do
  FAKE_ISO="2026-02-${day}T00:00:00Z"
  FAKE_ID="202602${day}T000000Z"
  all_ids+=("$(stage4_create_backup 0.2.8)")
done
unset -f date
assert stage4_prune_backups ""
assert test "$(verified_count)" -eq 4
assert test ! -e "$UPDATE_BACKUP_ROOT/${all_ids[0]}"
for id in "${all_ids[@]:1}"; do
  assert stage4_verify_backup "$UPDATE_BACKUP_ROOT/$id" "$id" published
done
pass

printf 'stage4-corrections-fixture: PASS (U-V all executed)\n'
