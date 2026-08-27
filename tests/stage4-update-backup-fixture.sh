#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER="$ROOT/twebproxy-manager.sh"
WORK="$(mktemp -d /tmp/twebproxy-stage4-tests.XXXXXX)"
trap '[[ "${KEEP_STAGE4_TEST_TMP:-0}" == 1 ]] || rm -rf -- "$WORK"' EXIT

fail() { printf 'stage4-update-backup-fixture: FAIL [%s]: %s\n' "${CURRENT_CASE:-setup}" "$*" >&2; exit 1; }
pass() { printf 'Stage4-%s: PASS\n' "$CURRENT_CASE"; }
assert() { "$@" || fail "assertion failed: $*"; }

# shellcheck disable=SC1090
source "$MANAGER"
trap - ERR
disable_colors

eval "$(declare -f stage4_install_candidate_target | sed '1s/stage4_install_candidate_target/stage4_install_candidate_target_real/')"
eval "$(declare -f stage4_rollback_exact | sed '1s/stage4_rollback_exact/stage4_rollback_exact_real/')"
eval "$(declare -f stage4_verify_backup | sed '1s/stage4_verify_backup/stage4_verify_backup_real/')"

make_fake_manager() {
  local path="$1" version="$2" behavior="${3:-good}" marker="${4:-}"
  install -d -o root -g root -m 0700 "$(dirname -- "$path")"
  cat > "$path" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
MANAGER_VERSION="$version"
[[ -z $(printf '%q' "$marker") ]] || : > $(printf '%q' "$marker")
if [[ "\${1:-}" == "--help" ]]; then
  printf 'TWebProxy Manager v%s\\n' "\$MANAGER_VERSION"
  exit 0
fi
if [[ "\${1:-}" == "--json" && "\${2:-}" == "overview" ]]; then
  if [[ $(printf '%q' "$behavior") == bad-overview ]]; then
    printf '{"schema_version":"wrong","command":"overview","data":{"manager_version":"%s"}}\\n' "\$MANAGER_VERSION"
  else
    printf '{"schema_version":"twebproxy.output.v1","command":"overview","overall":"ERROR","data":{"manager_version":"%s"}}\\n' "\$MANAGER_VERSION"
  fi
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
  make_fake_manager "$MANAGER_BIN" "$MANAGER_VERSION"
  install -o root -g root -m 0755 "$MANAGER_BIN" "$PROJECT_MANAGER_COPY"
  if [[ "$install_helper" == yes ]]; then
    stage4_install_restore_helper yes || fail 'helper bootstrap failed'
  fi
}

prepare_candidate() {
  local behavior="${1:-good}" marker="${2:-}"
  CANDIDATE="$CASE_DIR/candidate.sh"
  CHECKSUMS="$CASE_DIR/candidate.SHA256SUMS"
  make_fake_manager "$CANDIDATE" 0.2.8 "$behavior" "$marker"
  printf '%s  twebproxy-manager.sh\n' "$(sha256sum "$CANDIDATE" | awk '{print $1}')" > "$CHECKSUMS"
}

mock_update_network() {
  fetch_manager_update_info() {
    REMOTE_MANAGER_VERSION=0.2.8
    REMOTE_MANAGER_REF=v0.2.8
    REMOTE_MANAGER_SOURCE=release
  }
  curl() {
    local out="" url="" arg next=0
    for arg in "$@"; do
      if (( next )); then out="$arg"; next=0; continue; fi
      [[ "$arg" == -o ]] && { next=1; continue; }
      url="$arg"
    done
    [[ -n "$out" ]] || return 2
    if [[ "$url" == */SHA256SUMS ]]; then
      cp -- "$CHECKSUMS" "$out"
    else
      cp -- "$CANDIDATE" "$out"
    fi
  }
  set_global_manager_version() { printf '%s\n' "$1" > "$CASE_DIR/global-version-written"; }
}

run_update_capture() {
  local out_file="$1"
  set +e
  ( manager_update_cmd --force ) > "$out_file" 2>&1
  UPDATE_RC=$?
  set -e
}

CURRENT_CASE=A-valid-update
setup_case A
prepare_candidate good
mock_update_network
events="$CASE_DIR/mutation-order.events"
stage4_verify_backup() { printf 'verify:%s\n' "$3" >> "$events"; stage4_verify_backup_real "$@"; }
stage4_install_candidate_target() { printf 'install:%s\n' "$2" >> "$events"; stage4_install_candidate_target_real "$@"; }
run_update_capture "$CASE_DIR/out"
assert test "$UPDATE_RC" -eq 0
assert grep -q '^UPDATE_SUCCESS backup_id=update-' "$CASE_DIR/out"
candidate_hash="$(sha256sum "$CANDIDATE" | awk '{print $1}')"
assert test "$(sha256sum "$MANAGER_BIN" | awk '{print $1}')" = "$candidate_hash"
assert test "$(sha256sum "$PROJECT_MANAGER_COPY" | awk '{print $1}')" = "$candidate_hash"
backup_id="$(sed -nE 's/^UPDATE_SUCCESS backup_id=(update-.*)$/\1/p' "$CASE_DIR/out")"
assert stage4_verify_backup "$UPDATE_BACKUP_ROOT/$backup_id" "$backup_id" published
assert test "$(sed -n '1p' "$events")" = verify:incomplete
assert test "$(sed -n '2p' "$events")" = verify:published
assert test "$(sed -n '3p' "$events")" = "install:$MANAGER_BIN"
assert test "$(sed -n '4p' "$events")" = "install:$PROJECT_MANAGER_COPY"
unset -f stage4_verify_backup stage4_install_candidate_target
source "$MANAGER"; trap - ERR; disable_colors

setup_case A-metadata-warning
prepare_candidate good
mock_update_network
set_global_manager_version() { return 1; }
run_update_capture "$CASE_DIR/out"
assert test "$UPDATE_RC" -eq 0
assert grep -q '^UPDATE_SUCCESS backup_id=' "$CASE_DIR/out"
assert grep -q 'не удалось обновить metadata в global.env' "$CASE_DIR/out"
pass

CURRENT_CASE=B-backup-create-failure
setup_case B
marker="$CASE_DIR/candidate-executed"
prepare_candidate good "$marker"
mock_update_network
old_hash="$(sha256sum "$MANAGER_BIN" | awk '{print $1}')"
stage4_create_backup() { return 1; }
run_update_capture "$CASE_DIR/out"
assert test "$UPDATE_RC" -ne 0
assert test ! -e "$marker"
assert test "$(sha256sum "$MANAGER_BIN" | awk '{print $1}')" = "$old_hash"
unset -f stage4_create_backup
# shellcheck disable=SC1090
source "$MANAGER"; trap - ERR; disable_colors

setup_case B-unsafe-current
prepare_candidate good "$CASE_DIR/candidate-executed"
mock_update_network
printf '\n# diverged\n' >> "$PROJECT_MANAGER_COPY"
run_update_capture "$CASE_DIR/out"
assert test "$UPDATE_RC" -ne 0
assert test ! -e "$CASE_DIR/candidate-executed"
assert test ! -e "$UPDATE_BACKUP_ROOT"
pass

CURRENT_CASE=C-backup-verify-failure
setup_case C
marker="$CASE_DIR/candidate-executed"
prepare_candidate good "$marker"
mock_update_network
old_hash="$(sha256sum "$MANAGER_BIN" | awk '{print $1}')"
stage4_verify_backup() { return 1; }
run_update_capture "$CASE_DIR/out"
assert test "$UPDATE_RC" -ne 0
assert test ! -e "$marker"
assert test "$(sha256sum "$MANAGER_BIN" | awk '{print $1}')" = "$old_hash"
unset -f stage4_verify_backup
source "$MANAGER"; trap - ERR; disable_colors
pass

CURRENT_CASE=D-partial-install-rollback-success
setup_case D
prepare_candidate good
mock_update_network
old_hash="$(sha256sum "$MANAGER_BIN" | awk '{print $1}')"
counter="$CASE_DIR/rollback-count"
stage4_install_candidate_target() {
  [[ "$2" != "$PROJECT_MANAGER_COPY" ]] || return 1
  stage4_install_candidate_target_real "$@"
}
stage4_rollback_exact() { printf x >> "$counter"; stage4_rollback_exact_real "$@"; }
run_update_capture "$CASE_DIR/out"
assert test "$UPDATE_RC" -ne 0
assert grep -q '^UPDATE_FAILED_ROLLBACK_SUCCESS backup_id=' "$CASE_DIR/out"
assert test "$(wc -c < "$counter")" -eq 1
assert test "$(sha256sum "$MANAGER_BIN" | awk '{print $1}')" = "$old_hash"
assert test "$(sha256sum "$PROJECT_MANAGER_COPY" | awk '{print $1}')" = "$old_hash"
unset -f stage4_install_candidate_target stage4_rollback_exact
source "$MANAGER"; trap - ERR; disable_colors
pass

CURRENT_CASE=E-rollback-failure
setup_case E
prepare_candidate good
mock_update_network
counter="$CASE_DIR/rollback-count"
stage4_install_candidate_target() {
  [[ "$2" != "$PROJECT_MANAGER_COPY" ]] || return 1
  stage4_install_candidate_target_real "$@"
}
stage4_rollback_exact() { printf x >> "$counter"; return 1; }
run_update_capture "$CASE_DIR/out"
assert test "$UPDATE_RC" -ne 0
assert grep -q '^UPDATE_FAILED_ROLLBACK_FAILED backup_id=' "$CASE_DIR/out"
assert test "$(wc -c < "$counter")" -eq 1
failed_backup_id="$(sed -nE 's/^UPDATE_FAILED_ROLLBACK_FAILED backup_id=(update-.*)$/\1/p' "$CASE_DIR/out")"
assert test -n "$failed_backup_id"
assert test -d "$UPDATE_BACKUP_ROOT/$failed_backup_id"
assert stage4_verify_backup "$UPDATE_BACKUP_ROOT/$failed_backup_id" "$failed_backup_id" published
unset -f stage4_install_candidate_target stage4_rollback_exact
source "$MANAGER"; trap - ERR; disable_colors
pass

CURRENT_CASE=F-health-failure
setup_case F
prepare_candidate bad-overview
mock_update_network
old_hash="$(sha256sum "$MANAGER_BIN" | awk '{print $1}')"
counter="$CASE_DIR/rollback-count"
stage4_rollback_exact() { printf x >> "$counter"; stage4_rollback_exact_real "$@"; }
run_update_capture "$CASE_DIR/out"
assert test "$UPDATE_RC" -ne 0
assert grep -q '^UPDATE_FAILED_ROLLBACK_SUCCESS backup_id=' "$CASE_DIR/out"
assert test "$(wc -c < "$counter")" -eq 1
assert test "$(sha256sum "$MANAGER_BIN" | awk '{print $1}')" = "$old_hash"
unset -f stage4_rollback_exact
source "$MANAGER"; trap - ERR; disable_colors
pass

CURRENT_CASE=G-corrupt-backup
setup_case G
id="$(stage4_create_backup 0.2.8)"
old_hash="$(sha256sum "$MANAGER_BIN" | awk '{print $1}')"
printf '\n# corrupt\n' >> "$UPDATE_BACKUP_ROOT/$id/files/twebproxy-manager.sh"
set +e; "$UPDATE_RESTORE_HELPER" restore "$id" > "$CASE_DIR/out" 2>&1; rc=$?; set -e
assert test "$rc" -ne 0
assert test "$(sha256sum "$MANAGER_BIN" | awk '{print $1}')" = "$old_hash"
pass

CURRENT_CASE=H-broken-manager-offline
setup_case H
id="$(stage4_create_backup 0.2.8)"
old_hash="$(sha256sum "$MANAGER_BIN" | awk '{print $1}')"
network_wrapper="$CASE_DIR/network-wrapper"
install -d -o root -g root -m 0700 "$network_wrapper"
cat > "$network_wrapper/curl" <<EOF
#!/usr/bin/env bash
: > $(printf '%q' "$CASE_DIR/network-accessed")
exit 99
EOF
chmod 0755 "$network_wrapper/curl"
printf '#!/bin/sh\nexit 99\n' > "$MANAGER_BIN"; chmod 0755 "$MANAGER_BIN"
printf '#!/bin/sh\nexit 98\n' > "$PROJECT_MANAGER_COPY"; chmod 0755 "$PROJECT_MANAGER_COPY"
assert env PATH="$network_wrapper:$PATH" "$UPDATE_RESTORE_HELPER" restore "$id"
assert test "$(sha256sum "$MANAGER_BIN" | awk '{print $1}')" = "$old_hash"
assert test "$(sha256sum "$PROJECT_MANAGER_COPY" | awk '{print $1}')" = "$old_hash"
unlink "$MANAGER_BIN"; unlink "$PROJECT_MANAGER_COPY"
assert env PATH="$network_wrapper:$PATH" "$UPDATE_RESTORE_HELPER" restore "$id"
assert test "$(sha256sum "$MANAGER_BIN" | awk '{print $1}')" = "$old_hash"
assert test "$(sha256sum "$PROJECT_MANAGER_COPY" | awk '{print $1}')" = "$old_hash"
chmod 0600 "$MANAGER_BIN" "$PROJECT_MANAGER_COPY"
assert env PATH="$network_wrapper:$PATH" "$UPDATE_RESTORE_HELPER" restore "$id"
assert test "$(stat -c '%a' "$MANAGER_BIN")" = 755
assert test "$(stat -c '%a' "$PROJECT_MANAGER_COPY")" = 755
assert test ! -e "$CASE_DIR/network-accessed"
pass

CURRENT_CASE=I-retention
setup_case I
ids=()
for _ in 1 2 3 4 5 6; do
  ids+=("$(stage4_create_backup 0.2.8)")
  sleep 1
done
install -d -o root -g root -m 0700 "$UPDATE_BACKUP_ROOT/.incomplete.keep"
install -d -o root -g root -m 0700 "$UPDATE_BACKUP_ROOT/not-a-backup"
assert stage4_prune_backups "${ids[5]}"
valid_count="$(bash -c 'source "$1"; s4_collect_valid_ids | wc -l' _ "$UPDATE_RESTORE_HELPER")"
assert test "$valid_count" -eq 4
assert test -d "$UPDATE_BACKUP_ROOT/.incomplete.keep"
assert test -d "$UPDATE_BACKUP_ROOT/not-a-backup"
pass

CURRENT_CASE=J-hostile-identifiers
setup_case J
id="$(stage4_create_backup 0.2.8)"
old_hash="$(sha256sum "$MANAGER_BIN" | awk '{print $1}')"
for hostile in ../../etc/passwd /tmp/evil update-20260101T000000Z-ABCDEF123456 update-20260101T000000Z-1234; do
  set +e; "$UPDATE_RESTORE_HELPER" restore "$hostile" >/dev/null 2>&1; rc=$?; set -e
  assert test "$rc" -ne 0
done
assert test "$(sha256sum "$MANAGER_BIN" | awk '{print $1}')" = "$old_hash"
pass

CURRENT_CASE=K-symlinks
setup_case K-storage
install -d -o root -g root -m 0700 "$CASE_DIR/real-storage"
install -d -o root -g root -m 0700 "$UPDATE_BACKUP_PARENT"
ln -s "$CASE_DIR/real-storage" "$UPDATE_BACKUP_ROOT"
set +e; stage4_create_backup 0.2.8 >/dev/null 2>&1; rc=$?; set -e
assert test "$rc" -ne 0

setup_case K-backup-dir
id="$(stage4_create_backup 0.2.8)"
mv "$UPDATE_BACKUP_ROOT/$id" "$CASE_DIR/real-backup"
ln -s "$CASE_DIR/real-backup" "$UPDATE_BACKUP_ROOT/$id"
set +e; "$UPDATE_RESTORE_HELPER" restore "$id" >/dev/null 2>&1; rc=$?; set -e
assert test "$rc" -ne 0

setup_case K-payload
id="$(stage4_create_backup 0.2.8)"
payload="$UPDATE_BACKUP_ROOT/$id/files/twebproxy-manager.sh"
payload_copy="$CASE_DIR/payload-copy"
cp -- "$payload" "$payload_copy"
ln -sfn "$payload_copy" "$payload"
assert test ! -L "$MANAGER_BIN"
set +e; "$UPDATE_RESTORE_HELPER" restore "$id" >/dev/null 2>&1; rc=$?; set -e
assert test "$rc" -ne 0
pass

CURRENT_CASE=L-owner-mode-type
setup_case L
id1="$(stage4_create_backup 0.2.8)"
owner_wrapper="$CASE_DIR/owner-wrapper"
install -d -o root -g root -m 0700 "$owner_wrapper"
cat > "$owner_wrapper/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "${OWNER_FAKE_TARGET:-}" ]]; then
  printf '123:456:600\n'
else
  /usr/bin/stat "$@"
fi
EOF
chmod 0755 "$owner_wrapper/stat"
OWNER_FAKE_TARGET="$UPDATE_BACKUP_ROOT/$id1/files/twebproxy-manager.sh" \
  assert env PATH="$owner_wrapper:$PATH" OWNER_FAKE_TARGET="$UPDATE_BACKUP_ROOT/$id1/files/twebproxy-manager.sh" \
  bash -c 'source "$1"; ! s4_verify_backup_dir "$2" "$3" published' _ "$UPDATE_RESTORE_HELPER" "$UPDATE_BACKUP_ROOT/$id1" "$id1"
id2="$(stage4_create_backup 0.2.8)"
chmod 0644 "$UPDATE_BACKUP_ROOT/$id2/metadata.json"
assert bash -c '! source "$1" || ! s4_verify_backup_dir "$2" "$3" published' _ "$UPDATE_RESTORE_HELPER" "$UPDATE_BACKUP_ROOT/$id2" "$id2"
id3="$(stage4_create_backup 0.2.8)"
mv "$UPDATE_BACKUP_ROOT/$id3/SHA256SUMS" "$UPDATE_BACKUP_ROOT/$id3/SHA256SUMS.file"
install -d -o root -g root -m 0700 "$UPDATE_BACKUP_ROOT/$id3/SHA256SUMS"
assert bash -c '! source "$1" || ! s4_verify_backup_dir "$2" "$3" published' _ "$UPDATE_RESTORE_HELPER" "$UPDATE_BACKUP_ROOT/$id3" "$id3"
pass

CURRENT_CASE=M-lock-contention
setup_case M
id="$(stage4_create_backup 0.2.8)"
: > "$UPDATE_LOCK_FILE"; chmod 0600 "$UPDATE_LOCK_FILE"; chown root:root "$UPDATE_LOCK_FILE"
exec {held_fd}>"$UPDATE_LOCK_FILE"
flock -n "$held_fd"
set +e; "$UPDATE_RESTORE_HELPER" restore "$id" >/dev/null 2>&1; rc=$?; set -e
flock -u "$held_fd"
exec {held_fd}>&-
assert test "$rc" -ne 0
pass

CURRENT_CASE=N-helper-bootstrap
setup_case N no
assert test ! -e "$UPDATE_RESTORE_HELPER"
rmdir "$LIBEXEC_DIR"
assert test ! -e "$LIBEXEC_DIR"
assert stage4_install_restore_helper yes
assert stage4_safe_root_file "$UPDATE_RESTORE_HELPER" 755
assert bash -n "$UPDATE_RESTORE_HELPER"
assert test "$("$UPDATE_RESTORE_HELPER" list | head -n1)" = "format=$UPDATE_BACKUP_FORMAT"
pass

CURRENT_CASE=O-unsafe-helper-fail-closed
setup_case O no
unsafe="$CASE_DIR/unsafe-helper"
printf '#!/bin/sh\nexit 0\n' > "$unsafe"; chmod 0755 "$unsafe"
ln -s "$unsafe" "$UPDATE_RESTORE_HELPER"
before="$(readlink "$UPDATE_RESTORE_HELPER")"
set +e; stage4_install_restore_helper yes; rc=$?; set -e
assert test "$rc" -ne 0
assert test -L "$UPDATE_RESTORE_HELPER"
assert test "$(readlink "$UPDATE_RESTORE_HELPER")" = "$before"
prepare_candidate good "$CASE_DIR/candidate-executed"
mock_update_network
run_update_capture "$CASE_DIR/out"
assert test "$UPDATE_RC" -ne 0
assert test ! -e "$CASE_DIR/candidate-executed"
assert test ! -e "$UPDATE_BACKUP_ROOT"

setup_case O-incompatible no
cat > "$UPDATE_RESTORE_HELPER" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == list ]]; then
  printf 'format=twebproxy.update-backup.v1\nvalid=0 invalid=0\n'
fi
EOF
chmod 0755 "$UPDATE_RESTORE_HELPER"; chown root:root "$UPDATE_RESTORE_HELPER"
incompatible_hash="$(sha256sum "$UPDATE_RESTORE_HELPER" | awk '{print $1}')"
set +e; stage4_install_restore_helper yes; rc=$?; set -e
assert test "$rc" -ne 0
assert test "$(sha256sum "$UPDATE_RESTORE_HELPER" | awk '{print $1}')" = "$incompatible_hash"

setup_case O-wrong-mode no
stage4_render_restore_helper > "$UPDATE_RESTORE_HELPER"
chmod 0700 "$UPDATE_RESTORE_HELPER"; chown root:root "$UPDATE_RESTORE_HELPER"
wrong_mode_hash="$(sha256sum "$UPDATE_RESTORE_HELPER" | awk '{print $1}')"
set +e; stage4_install_restore_helper yes; rc=$?; set -e
assert test "$rc" -ne 0
assert test "$(stat -c '%a' "$UPDATE_RESTORE_HELPER")" = 700
assert test "$(sha256sum "$UPDATE_RESTORE_HELPER" | awk '{print $1}')" = "$wrong_mode_hash"
pass

CURRENT_CASE=P-interrupted-restore-rerun
setup_case P
id="$(stage4_create_backup 0.2.8)"
old_hash="$(sha256sum "$MANAGER_BIN" | awk '{print $1}')"
make_fake_manager "$CASE_DIR/new-manager" 0.2.8 good
install -o root -g root -m 0755 "$CASE_DIR/new-manager" "$MANAGER_BIN"
install -o root -g root -m 0755 "$CASE_DIR/new-manager" "$PROJECT_MANAGER_COPY"
new_hash="$(sha256sum "$MANAGER_BIN" | awk '{print $1}')"
wrapper="$CASE_DIR/wrapper"
install -d -o root -g root -m 0700 "$wrapper"
cat > "$wrapper/mv" <<'EOF'
#!/usr/bin/env bash
/usr/bin/mv "$@"
kill -KILL "$PPID"
EOF
chmod 0755 "$wrapper/mv"
set +e; PATH="$wrapper:$PATH" "$UPDATE_RESTORE_HELPER" restore "$id" >/dev/null 2>&1; rc=$?; set -e
assert test "$rc" -ne 0
assert test "$(sha256sum "$MANAGER_BIN" | awk '{print $1}')" = "$old_hash"
assert test "$(sha256sum "$PROJECT_MANAGER_COPY" | awk '{print $1}')" = "$new_hash"
assert "$UPDATE_RESTORE_HELPER" restore "$id"
assert test "$(sha256sum "$MANAGER_BIN" | awk '{print $1}')" = "$old_hash"
assert test "$(sha256sum "$PROJECT_MANAGER_COPY" | awk '{print $1}')" = "$old_hash"
pass

printf 'stage4-update-backup-fixture: PASS (A-P all executed)\n'
