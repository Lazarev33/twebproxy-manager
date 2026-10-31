#!/usr/bin/env bash
# Stage F regressions: manager self-update provenance (F1), locking and cleanup
# (F2), backup -> candidate -> install -> health -> success/rollback (F3).
#
# Every case drives the real manager-update / helper / install_manager_copy code
# of the manager under test inside tests/stagef/updater-harness.sh: a sandbox in
# a temporary directory, a modeled GitHub and ephemeral test signing keys. It
# needs root (real chown/flock), never touches system paths and never uses the
# network. Exit: 0 all PASS, 1 any FAIL.
#
# Usage: updater-fixture.sh [path/to/twebproxy-manager.sh] [case-filter-regex]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
FILTER="${2:-.}"
# shellcheck source=updater-harness.sh
source "$ROOT/tests/stagef/updater-harness.sh"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'updater-fixture: needs root (sandboxed chown/flock)'; exit 77; }
f_init "$MGR" || { echo 'updater-fixture: setup failed'; exit 1; }
trap 'f_case_cleanup 2>/dev/null; f_fini' EXIT
# No failure snapshot: it probes host services (blocked by the sentinels anyway).
export TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 TWEBPROXY_UPDATE_LOCK_WAIT=2
NEW=0.2.90

pass=0; fail=0
check() { # check ID description command...
  local id="$1" what="$2"; shift 2
  if "$@"; then printf 'PASS %s: %s\n' "$id" "$what"; pass=$((pass + 1))
  else printf 'FAIL %s: %s\n' "$id" "$what"; fail=$((fail + 1)); fi
}
want() { [[ "$CASE_ID" =~ $FILTER ]]; }
begin() { CASE_ID="$1"; want || return 1; export F_PIN_KEY="${2:-A}"; f_case "$1"; }
# Negative checks are never vacuous: the output file must exist and be non-empty.
no_success() { [[ -s "$F_OUT" ]] && ! grep -q '^UPDATE_SUCCESS' "$F_OUT"; }
absent_in() { [[ -s "$2" ]] && ! grep -q -- "$1" "$2"; }
unchanged() { f_copies_are "$F_OLD_HASH"; }
installed_new() { f_copies_are "$F_CANDIDATE_HASH"; }
no_backup() { [[ "$(f_backup_count)" == 0 ]]; }
no_leftovers() { [[ -z "$(f_leftovers)" ]]; }
artifact_not_fetched() { [[ -s "$F_REMOTE/requests" ]] && ! grep -q '/twebproxy-manager\.sh$' "$F_REMOTE/requests"; }
out_has() { grep -Eq -- "$1" "$F_OUT"; }
refused_untouched() { # common outcome of a refused update: nothing installed, nothing backed up
  check "$CASE_ID.rc" 'manager-update fails' test "$F_RC" -ne 0
  check "$CASE_ID.no-success" 'no UPDATE_SUCCESS' no_success
  check "$CASE_ID.unchanged" 'installed copies unchanged' unchanged
  check "$CASE_ID.no-backup" 'no backup or mutation started' no_backup
  check "$CASE_ID.no-leftovers" 'no candidate or staging leftovers' no_leftovers
}

# ============================== F1 provenance ===============================

if begin f1-branch-not-a-source; then
  f_publish_branch main "$NEW"          # newer VERSION on main, no release at all
  f_update
  refused_untouched
  check "$CASE_ID.branch-artifact" 'the development-branch manager is never downloaded' \
    eval '! f_requested "/main/twebproxy-manager.sh"'
  f_case_cleanup
fi

if begin f1-branch-forced-downgrade; then
  f_publish_branch main 0.2.9           # the real public main today: older VERSION
  f_update --force
  refused_untouched
  f_case_cleanup
fi

if begin f1-same-source-checksum-is-not-authentication none; then
  f_publish "$NEW" sign=none            # release + SHA256SUMS from the same source only
  f_update
  refused_untouched
  check "$CASE_ID.not-downloaded" 'artifact not downloaded without a trust anchor' artifact_not_fetched
  check "$CASE_ID.reason" 'refusal names the missing trust anchor' out_has '^UPDATE_REFUSED reason=no-trust-anchor'
  f_case_cleanup
fi

if begin f1-refusal-in-english none; then
  f_publish "$NEW" sign=none
  F_LANG=en f_update
  refused_untouched
  check "$CASE_ID.english" 'the refusal is fully translated' \
    perl -CSD -ne 'BEGIN { $c = 0 } $c = 1 if /\p{Cyrillic}/; END { exit $c }' "$F_OUT"
  check "$CASE_ID.explains" 'and explains the missing trust anchor' out_has 'pins no release-signing key'
  f_case_cleanup
fi

if begin f1-no-pinned-key-signed-release none; then
  f_publish "$NEW"                      # signed, but this build pins no key
  f_update
  refused_untouched
  f_case_cleanup
fi

if begin f1-signed-release-installs; then
  f_publish "$NEW"
  f_update
  check "$CASE_ID.rc" 'signed release installs' test "$F_RC" -eq 0
  check "$CASE_ID.success" 'UPDATE_SUCCESS reported' out_has '^UPDATE_SUCCESS backup_id=update-'
  check "$CASE_ID.installed" 'both copies are the signed artifact' installed_new
  check "$CASE_ID.immutable-ref" 'artifact fetched by the signed commit, not a mutable ref' \
    f_requested "/$F_COMMIT/twebproxy-manager.sh"
  check "$CASE_ID.asset-redirect" 'signed metadata followed the GitHub asset redirect' \
    f_requested 'redirect-> https://release-assets.githubusercontent.com/'
  check "$CASE_ID.trust-label" 'output names the trust basis' out_has 'trust=signed-release'
  f_case_cleanup
fi

if begin f1-wrong-signing-key; then
  f_publish "$NEW" sign=B
  f_update
  refused_untouched
  check "$CASE_ID.reason" 'signature refusal' out_has '^UPDATE_REFUSED reason=signature'
  f_case_cleanup
fi

if begin f1-manifest-tampered; then
  f_publish "$NEW" tamper=1
  f_update
  refused_untouched
  f_case_cleanup
fi

if begin f1-artifact-tampered; then
  evil="$F_CASE/evil.sh"; f_fake_manager "$evil" "$NEW" good "$NEW-beta" '# attacker payload'
  f_publish "$NEW" artifact="$evil"     # SHA256SUMS on the same ref matches the evil file
  f_update
  refused_untouched
  check "$CASE_ID.reason" 'digest refusal' out_has '^UPDATE_REFUSED reason=digest'
  f_case_cleanup
fi

for variant in \
  'extra-key|.unsigned_note = "x"' \
  'other-repository|.repository = "someone/else"' \
  'development-channel|.channel = "development"' \
  'tag-mismatch|.tag = "v0.2.91" | .version = "0.2.91"' \
  'version-mismatch|.version = "0.2.91"' \
  'size-mismatch|.artifact.size = 1' \
  'label-mismatch|.release_version = "0.2.91-beta"' \
  'not-an-object|[.]'; do
  name="${variant%%|*}"; filter="${variant#*|}"
  if begin "f1-manifest-$name"; then
    f_publish "$NEW" "manifest=$filter"
    f_update
    refused_untouched
    f_case_cleanup
  fi
done

for variant in 'prerelease|prerelease=true' 'draft|draft=true' 'foreign-html|html_repo=someone/else' \
               'rc-tag|tag=v0.2.90-rc1'; do
  name="${variant%%|*}"; opt="${variant#*|}"
  if begin "f1-release-$name"; then
    f_publish "$NEW" "$opt"
    f_update
    refused_untouched
    f_case_cleanup
  fi
done

if begin f1-release-not-json; then
  printf '<html>rate limited</html>\n' > "$F_CASE/api.txt"
  f_publish "$NEW" api="$F_CASE/api.txt"
  f_update
  refused_untouched
  f_case_cleanup
fi

for variant in 'embedded-version|embedded=0.2.91' 'release-label|label=0.2.91-beta' \
               'duplicate-version|extra=MANAGER_VERSION="0.2.91"'; do
  name="${variant%%|*}"; opt="${variant#*|}"
  if begin "f1-identity-$name"; then
    f_publish "$NEW" "$opt"
    f_update
    refused_untouched
    f_case_cleanup
  fi
done

if begin f1-redirect-metadata-foreign-host; then
  f_publish "$NEW" asset_host=assets.example.net
  f_update
  refused_untouched
  f_case_cleanup
fi

if begin f1-redirect-artifact-foreign-host; then
  f_publish "$NEW" raw_redirect=https://mirror.example.net/pkg
  f_update
  refused_untouched
  check "$CASE_ID.reason" 'redirect refusal before backup' out_has '^UPDATE_REFUSED reason=download'
  f_case_cleanup
fi

if begin f1-operator-digest none; then
  f_publish "$NEW" sign=none
  f_update --sha256 "$F_CANDIDATE_HASH"
  check "$CASE_ID.rc" 'operator-pinned SHA-256 installs' test "$F_RC" -eq 0
  check "$CASE_ID.installed" 'both copies are the pinned artifact' installed_new
  check "$CASE_ID.trust-label" 'output names the operator-pinned trust' out_has 'trust=operator-sha256'
  f_case_cleanup
fi

if begin f1-operator-digest-mismatch none; then
  f_publish "$NEW" sign=none
  f_update --sha256 "$(printf 'other' | sha256sum | awk '{print $1}')"
  refused_untouched
  f_case_cleanup
fi

if begin f1-operator-digest-invalid none; then
  f_publish "$NEW" sign=none
  f_update --sha256 not-a-digest
  refused_untouched
  f_update --sha256=
  check "$CASE_ID.empty" 'an empty --sha256= is a usage error, not "no digest"' out_has '^UPDATE_REFUSED reason=usage'
  check "$CASE_ID.empty-unchanged" 'installed copies unchanged' unchanged
  f_case_cleanup
fi

if begin f1-pinned-key-requires-signature; then
  f_publish "$NEW" sign=none            # this build pins a key: the digest alone is not enough
  f_update --sha256 "$F_CANDIDATE_HASH"
  refused_untouched
  f_case_cleanup
fi

if begin f1-interrupted-download; then
  f_publish "$NEW"
  f_fault "https://raw.githubusercontent.com/$F_SLUG/$F_COMMIT/twebproxy-manager.sh" partial
  f_fault "https://raw.githubusercontent.com/$F_SLUG/v$NEW/twebproxy-manager.sh" partial
  f_update
  refused_untouched
  f_case_cleanup
fi

if begin f1-truncated-download; then
  f_publish "$NEW"
  f_fault "https://raw.githubusercontent.com/$F_SLUG/$F_COMMIT/twebproxy-manager.sh" truncate
  f_fault "https://raw.githubusercontent.com/$F_SLUG/v$NEW/twebproxy-manager.sh" truncate
  f_update
  refused_untouched
  f_case_cleanup
fi

if begin f1-corrupted-candidate; then
  f_publish "$NEW" behavior=bad-syntax  # authentic bytes that are not a valid script
  f_update
  refused_untouched
  f_case_cleanup
fi

if begin f1-check-update-ignores-branch; then
  f_publish_branch main "$NEW"
  F_OUT="$F_CASE/check.out"; f_run manager_check_update_cmd > "$F_OUT" 2>&1; F_RC=$?
  check "$CASE_ID.no-claim" 'check-update does not offer a development-branch version' absent_in "$NEW" "$F_OUT"
  f_case_cleanup
fi

if begin f1-hint-ignores-branch; then
  f_publish_branch main "$NEW"
  F_OUT="$F_CASE/hint.out"; f_run manager_update_hint > "$F_OUT" 2>&1
  check "$CASE_ID.ran" 'the hint ran (non-vacuous)' test -f "$F_OUT"
  check "$CASE_ID.no-hint" 'automatic hint does not advertise a branch version' eval "! grep -q '$NEW' '$F_OUT'"
  f_case_cleanup
fi

if begin f1-hint-stable-release; then
  f_publish "$NEW"
  F_OUT="$F_CASE/hint.out"; f_run manager_update_hint > "$F_OUT" 2>&1
  check "$CASE_ID.hint" 'automatic hint reports the newer stable release' grep -q "$NEW" "$F_OUT"
  f_case_cleanup
fi

if begin f1-cache-is-data; then
  printf 'REMOTE_MANAGER_VERSION=%s\nREMOTE_MANAGER_REF=v%s\nREMOTE_MANAGER_SOURCE=release\ntouch %q\n' \
    "$NEW" "$NEW" "$F_CASE/cache-executed" > "$F_CASE/opt/update-check.env"
  f_run manager_update_hint > "$F_CASE/hint.out" 2>&1
  check "$CASE_ID.not-executed" 'update cache is parsed, never executed' test ! -e "$F_CASE/cache-executed"
  f_case_cleanup
fi

if begin f1-cache-branch-entry-ignored; then
  printf 'REMOTE_MANAGER_VERSION=%s\nREMOTE_MANAGER_REF=main\nREMOTE_MANAGER_SOURCE=branch\n' "$NEW" > "$F_CASE/opt/update-check.env"
  F_OUT="$F_CASE/hint.out"; f_run manager_update_hint > "$F_OUT" 2>&1
  check "$CASE_ID.ran" 'the hint ran (non-vacuous)' test -f "$F_OUT"
  check "$CASE_ID.no-hint" 'a cached development-branch entry is not trusted' eval "! grep -q '$NEW' '$F_OUT'"
  f_case_cleanup
fi

# ============================== F2 locking ==================================

if begin f2-concurrent-update-refused; then
  f_publish "$NEW"
  f_hold_lock 30
  start=$SECONDS; f_update
  refused_untouched
  check "$CASE_ID.bounded" 'refusal comes after a bounded wait' test "$((SECONDS - start))" -lt 20
  f_case_cleanup
fi

if begin f2-bounded-wait-for-finishing-holder; then
  f_publish "$NEW"
  f_hold_lock 1
  TWEBPROXY_UPDATE_LOCK_WAIT=15 f_update
  check "$CASE_ID.waited" 'an update waits for a briefly held lock' test "$F_RC" -eq 0
  check "$CASE_ID.installed" 'and then installs' installed_new
  f_case_cleanup
fi

if begin f2-lock-released-on-return; then
  # One long-lived process (the TUI): an up-to-date answer, a rolled-back update
  # and a successful update, each followed by a lock probe from another process.
  F_OUT="$F_CASE/tui.out"
  f_eval '
    probe() { ( exec 9>&-; flock -n "$UPDATE_LOCK_FILE" true ) && echo "LOCK_FREE_AFTER_$1" || echo "LOCK_HELD_AFTER_$1"; }
    f_publish "$F_LOCAL_VERSION"; manager_update_cmd || true; probe CURRENT
    f_publish 0.2.90 behavior=bad-overview; manager_update_cmd || true; probe ROLLBACK
    f_publish 0.2.91; manager_update_cmd || true; probe SUCCESS
  ' > "$F_OUT" 2>&1
  check "$CASE_ID.after-current" 'a long-lived process (TUI) releases the lock after an up-to-date answer' grep -q LOCK_FREE_AFTER_CURRENT "$F_OUT"
  check "$CASE_ID.after-rollback" 'after a rolled-back update' grep -q LOCK_FREE_AFTER_ROLLBACK "$F_OUT"
  check "$CASE_ID.after-success" 'and after a successful update' grep -q LOCK_FREE_AFTER_SUCCESS "$F_OUT"
  f_case_cleanup
fi

if begin f2-lock-not-inherited-by-candidate; then
  f_publish "$NEW" behavior=linger      # leaves a background process, fails health
  f_update
  check "$CASE_ID.rolled-back" 'health failure rolled back' out_has '^UPDATE_FAILED_ROLLBACK_SUCCESS'
  check "$CASE_ID.lock-free" 'a process left by the candidate does not keep the update lock' f_lock_free
  f_publish 0.2.91
  f_update
  check "$CASE_ID.next-update" 'the next legitimate update is not blocked' test "$F_RC" -eq 0
  f_case_cleanup
fi

if begin f2-bounded-health-probe; then
  f_publish "$NEW" behavior=hang-help   # ignores SIGTERM in the health probe
  start=$SECONDS; F_TIMEOUT=70 f_update
  check "$CASE_ID.finished" 'manager-update finishes despite a probe that ignores SIGTERM' test "$F_RC" -ne 124
  check "$CASE_ID.rolled-back" 'and rolls back' out_has '^UPDATE_FAILED_ROLLBACK_SUCCESS'
  check "$CASE_ID.unchanged" 'previous manager restored' unchanged
  check "$CASE_ID.bounded" "within the bounded probe time ($((SECONDS - start)) s)" test "$((SECONDS - start))" -lt 60
  f_case_cleanup
fi

if begin f2-ctrl-c-during-download; then
  f_publish "$NEW"
  f_fault "https://raw.githubusercontent.com/$F_SLUG/$F_COMMIT/twebproxy-manager.sh" hang
  f_fault "https://raw.githubusercontent.com/$F_SLUG/v$NEW/twebproxy-manager.sh" hang
  start=$SECONDS
  ( f_update; exit "$F_RC" ) & bg=$!
  for ((i = 0; i < 200; i++)); do grep -q '/twebproxy-manager\.sh$' "$F_REMOTE/requests" && break; sleep 0.05; done
  sleep 0.3
  pgid="$(awk '{print $5}' "/proc/$(<"$F_CASE/pid")/stat")"
  kill -INT -- "-$pgid" 2>/dev/null       # Ctrl-C reaches the whole foreground group
  wait "$bg"; rc=$?
  F_OUT="$F_CASE/out.1"
  check "$CASE_ID.interrupted" "Ctrl-C ends the update promptly (rc=$rc)" eval "(( rc != 0 && rc != 124 && SECONDS - start < 30 ))"
  check "$CASE_ID.unchanged" 'installed copies unchanged' unchanged
  check "$CASE_ID.no-backup" 'no backup started' no_backup
  check "$CASE_ID.no-leftovers" 'candidate and staging removed' no_leftovers
  check "$CASE_ID.lock" 'lock released' f_lock_free
  f_case_cleanup
fi

if begin f2-overlapping-copy-waits-for-update; then
  f_hold_lock 30                        # an update or rollback is in progress
  F_OUT="$F_CASE/copy.out"
  TWEBPROXY_UPDATE_LOCK_WAIT=1 f_eval 'install_manager_copy; echo "COPY_RC=$?"' > "$F_OUT" 2>&1
  check "$CASE_ID.untouched" 'add/repair/update tails do not rewrite the copies during an update' unchanged
  check "$CASE_ID.caller-continues" 'the calling command still completes' grep -q '^COPY_RC=0' "$F_OUT"
  f_release_holder
  f_eval 'install_manager_copy' > "$F_OUT" 2>&1
  check "$CASE_ID.synced" 'without a concurrent update both copies are synchronised' f_copies_are "$(f_sha "$F_MGR")"
  check "$CASE_ID.no-temp" 'no temporary copies left' no_leftovers
  f_case_cleanup
fi

if begin f2-stale-lock-file; then
  f_publish "$NEW"
  : > "$F_CASE/run/lock/twebproxy-manager-update.lock"; chmod 0600 "$F_CASE/run/lock/twebproxy-manager-update.lock"
  f_update
  check "$CASE_ID.ok" 'a lock file left by an earlier run does not block' test "$F_RC" -eq 0
  check "$CASE_ID.kept" 'the lock file itself is never deleted' test -f "$F_CASE/run/lock/twebproxy-manager-update.lock"
  f_case_cleanup
fi

# ============================== F3 install / rollback =======================

if begin f3-success-verified; then
  f_publish "$NEW"
  printf 'REMOTE_MANAGER_VERSION=%s\n' 0.0.1 > "$F_CASE/opt/update-check.env"
  f_update
  check "$CASE_ID.rc" 'update succeeds' test "$F_RC" -eq 0
  check "$CASE_ID.token" 'UPDATE_SUCCESS with the backup id' out_has '^UPDATE_SUCCESS backup_id=update-'
  check "$CASE_ID.installed" 'both copies verified new' installed_new
  id="$(sed -nE 's/^UPDATE_SUCCESS backup_id=(update-[^ ]*)$/\1/p' "$F_OUT")"
  check "$CASE_ID.backup" 'the pre-update backup verifies offline' \
    bash -c 'source "$1"; s4_verify_backup_dir "$2/$3" "$3" published' _ "$F_CASE/libexec/restore-update-backup" \
      "$F_CASE/var/lib/twebproxy/update-backups" "$id"
  check "$CASE_ID.metadata" 'global.env records the new version, other keys kept' \
    eval "grep -qx 'MANAGER_VERSION=$NEW' '$F_CASE/etc/global.env' && grep -qx 'TPROXY_UPSTREAM_COMMIT=0123abcd' '$F_CASE/etc/global.env'"
  check "$CASE_ID.cache" 'update cache removed' test ! -e "$F_CASE/opt/update-check.env"
  check "$CASE_ID.no-leftovers" 'no candidate, staging or temp leftovers' no_leftovers
  check "$CASE_ID.lock" 'lock released' f_lock_free
  f_case_cleanup
fi

if begin f3-backup-failure; then
  f_publish "$NEW"
  : > "$F_CASE/fail-install-backup"
  f_update
  check "$CASE_ID.rc" 'update fails' test "$F_RC" -ne 0
  check "$CASE_ID.no-success" 'no UPDATE_SUCCESS' no_success
  check "$CASE_ID.unchanged" 'installed copies unchanged' unchanged
  check "$CASE_ID.no-leftovers" 'no candidate or staging leftovers' no_leftovers
  f_case_cleanup
fi

if begin f3-shared-parent-with-acme-webroot; then
  # /var/lib/twebproxy also holds the ACME webroot: install -d creates it 0755.
  f_publish "$NEW"
  install -d -m 0755 "$F_CASE/var/lib/twebproxy/acme"
  f_update
  check "$CASE_ID.rc" 'update works beside the ACME webroot (parent 0755)' test "$F_RC" -eq 0
  check "$CASE_ID.installed" 'both copies verified new' installed_new
  check "$CASE_ID.parent-kept" 'the shared parent keeps its traversable mode' \
    test "$(stat -c %a "$F_CASE/var/lib/twebproxy" 2>/dev/null)" = 755
  check "$CASE_ID.root-private" 'the backup root is private (0700)' \
    test "$(stat -c %a "$F_CASE/var/lib/twebproxy/update-backups" 2>/dev/null)" = 700
  f_case_cleanup
fi

if begin f3-new-parent-stays-traversable; then
  f_publish "$NEW"
  f_update
  check "$CASE_ID.rc" 'update succeeds' test "$F_RC" -eq 0
  check "$CASE_ID.parent" 'a parent created by the updater can still be traversed for the ACME webroot' \
    test "$(stat -c %a "$F_CASE/var/lib/twebproxy" 2>/dev/null)" = 755
  f_case_cleanup
fi

if begin f3-writable-parent-refused; then
  f_publish "$NEW"
  install -d -m 0777 "$F_CASE/var/lib/twebproxy"; chmod 0777 "$F_CASE/var/lib/twebproxy"
  f_update
  refused_untouched
  f_case_cleanup
fi

if begin f3-first-copy-install-failure; then
  f_publish "$NEW"
  printf '%s\n' "$F_CASE/usr/twebproxy" > "$F_CASE/fail-mv-to"
  f_update
  check "$CASE_ID.rc" 'update fails' test "$F_RC" -ne 0
  check "$CASE_ID.no-success" 'no UPDATE_SUCCESS' no_success
  check "$CASE_ID.unchanged" 'installed copies unchanged' unchanged
  check "$CASE_ID.no-leftovers" 'no candidate, staging or temp leftovers' no_leftovers
  check "$CASE_ID.lock" 'lock released' f_lock_free
  f_case_cleanup
fi

if begin f3-partial-install-rollback; then
  f_publish "$NEW"
  printf '%s\n' "$F_CASE/opt/twebproxy-manager.sh" > "$F_CASE/fail-mv-to"
  f_update
  check "$CASE_ID.token" 'partial install rolled back' out_has '^UPDATE_FAILED_ROLLBACK_SUCCESS backup_id=update-'
  check "$CASE_ID.no-success" 'no UPDATE_SUCCESS' no_success
  check "$CASE_ID.restored" 'previous manager restored in both copies' unchanged
  check "$CASE_ID.no-leftovers" 'no candidate, staging or temp leftovers' no_leftovers
  f_case_cleanup
fi

if begin f3-health-failure-rollback; then
  f_publish "$NEW" behavior=bad-overview
  f_update
  check "$CASE_ID.token" 'health failure rolled back' out_has '^UPDATE_FAILED_ROLLBACK_SUCCESS backup_id=update-'
  check "$CASE_ID.no-success" 'no UPDATE_SUCCESS' no_success
  check "$CASE_ID.restored" 'previous manager restored' unchanged
  f_case_cleanup
fi

if begin f3-rollback-failure-and-offline-recovery; then
  f_eval 'stage4_create_backup 0.0.1 >/dev/null'   # an older verified backup
  older="$(basename "$(find "$F_CASE/var/lib/twebproxy/update-backups" -mindepth 1 -maxdepth 1 -name 'update-*' | head -n1)")"
  # Keep a pristine copy of the older backup: the candidate corrupts every backup.
  cp -a "$F_CASE/var/lib/twebproxy/update-backups/$older" "$F_CASE/older-backup"
  f_publish "$NEW" behavior=corrupt-backup
  f_update
  check "$CASE_ID.token" 'rollback failure reported' out_has '^UPDATE_FAILED_ROLLBACK_FAILED backup_id=update-'
  check "$CASE_ID.no-success" 'neither success nor rollback success claimed' \
    eval "test -s '$F_OUT' && ! grep -Eq '^(UPDATE_SUCCESS|UPDATE_FAILED_ROLLBACK_SUCCESS)' '$F_OUT'"
  check "$CASE_ID.guidance" 'the operator is told how to recover offline' out_has 'restore-update-backup (restore|restore-latest)'
  check "$CASE_ID.lock" 'lock released' f_lock_free
  rm -rf "$F_CASE/var/lib/twebproxy/update-backups/$older"
  cp -a "$F_CASE/older-backup" "$F_CASE/var/lib/twebproxy/update-backups/$older"
  : > "$F_REMOTE/offline"; : > "$F_REMOTE/requests"
  "$F_CASE/libexec/restore-update-backup" restore "$older" > "$F_CASE/restore.out" 2>&1
  check "$CASE_ID.offline-restore" 'offline helper restores a verified backup' grep -q '^RESTORE_SUCCESS' "$F_CASE/restore.out"
  check "$CASE_ID.offline-restored" 'both copies are the backed-up manager' unchanged
  check "$CASE_ID.offline-no-network" 'restore made no network request' test ! -s "$F_REMOTE/requests"
  f_case_cleanup
fi

if begin f3-signals-deferred-during-install; then
  f_publish "$NEW"
  printf '%s\n' "$F_CASE/opt" > "$F_CASE/park-install-dir"
  f_update & bg=$!
  for ((i = 0; i < 200; i++)); do [[ -e "$F_CASE/parked" ]] && break; sleep 0.05; done
  pid="$(<"$F_CASE/pid")"
  kill -TERM "$pid" 2>/dev/null; kill -INT "$pid" 2>/dev/null; kill -HUP "$pid" 2>/dev/null
  sleep 0.3; : > "$F_CASE/release"; wait "$bg"
  F_OUT="$F_CASE/out.1"
  check "$CASE_ID.parked" 'the interruption hit the window between the two copies' test -e "$F_CASE/parked"
  check "$CASE_ID.consistent" 'interrupted update ends in a verified state (both new)' installed_new
  check "$CASE_ID.success" 'and reports it' out_has '^UPDATE_SUCCESS'
  f_case_cleanup
fi

if begin f3-killed-update-recovery; then
  f_publish "$NEW"
  printf '%s\n' "$F_CASE/opt" > "$F_CASE/park-install-dir"
  f_update & bg=$!
  for ((i = 0; i < 200; i++)); do [[ -e "$F_CASE/parked" ]] && break; sleep 0.05; done
  kill -KILL "$(<"$F_CASE/pid")" 2>/dev/null; wait "$bg" 2>/dev/null
  : > "$F_CASE/release"; sleep 0.5
  check "$CASE_ID.mixed" 'SIGKILL left mixed copies (precondition)' eval '! unchanged && ! installed_new'
  check "$CASE_ID.lock-free" 'a killed update does not keep the lock' f_lock_free
  f_update
  check "$CASE_ID.refused" 'the next update refuses the mixed state' test "$F_RC" -ne 0
  check "$CASE_ID.guidance" 'and names the offline recovery command' out_has 'restore-update-backup restore-latest'
  "$F_CASE/libexec/restore-update-backup" restore-latest > "$F_CASE/restore.out" 2>&1
  check "$CASE_ID.restored" 'restore-latest returns to the verified pre-update manager' unchanged
  f_update
  check "$CASE_ID.next-update" 'the next update succeeds' test "$F_RC" -eq 0
  check "$CASE_ID.no-leftovers" 'stale staging and temp files cleaned' no_leftovers
  f_case_cleanup
fi

if begin f3-metadata-write-failure; then
  f_publish "$NEW"
  cp "$F_CASE/etc/global.env" "$F_CASE/global.env.before"
  F_OUT="$F_CASE/meta.out"
  f_eval 'eval "f_real_sgmv() $(declare -f set_global_manager_version | tail -n +2)"
          set_global_manager_version() { ( ulimit -f 0; trap "" XFSZ; f_real_sgmv "$@" ); }
          manager_update_cmd' > "$F_OUT" 2>&1
  check "$CASE_ID.kept" 'a failed metadata write leaves global.env intact' cmp -s "$F_CASE/global.env.before" "$F_CASE/etc/global.env"
  check "$CASE_ID.warned" 'and is reported' out_has 'global\.env'
  check "$CASE_ID.installed" 'the verified manager install stands' installed_new
  f_case_cleanup
fi

if begin f3-helper-refreshed; then
  f_publish "$NEW"
  printf '# rendered by an older manager\n' >> "$F_CASE/libexec/restore-update-backup"
  f_update
  check "$CASE_ID.rc" 'update succeeds with an older valid helper' test "$F_RC" -eq 0
  f_eval 'stage4_render_restore_helper' > "$F_CASE/rendered" 2>/dev/null
  check "$CASE_ID.refreshed" 'the helper is refreshed to the running manager rendering' \
    cmp -s "$F_CASE/rendered" "$F_CASE/libexec/restore-update-backup"
  f_case_cleanup
fi

if begin f3-unsafe-helper-untouched; then
  f_publish "$NEW"
  chmod 0700 "$F_CASE/libexec/restore-update-backup"
  before="$(f_sha "$F_CASE/libexec/restore-update-backup")"
  f_update
  refused_untouched
  check "$CASE_ID.helper" 'an unsafe helper is not replaced' test "$(f_sha "$F_CASE/libexec/restore-update-backup")" = "$before"
  f_case_cleanup
fi

printf '\nupdater-fixture: %s pass, %s fail\n' "$pass" "$fail"
(( fail == 0 ))
