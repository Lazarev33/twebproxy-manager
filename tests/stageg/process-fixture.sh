#!/usr/bin/env bash
# Stage G regressions for the two P1 defects found on real Linux in Stage F and
# the offline-restore metadata drift:
#   G1  a health probe whose descendant keeps stdout open must not extend the
#       update (or hold its lock) beyond the probe bound; leftover probe
#       processes are gone afterwards;
#   G2  children of the updater (curl, helper probes) must not inherit the update
#       lock: after a parent-only SIGKILL the lock is free at once;
#   G3  an offline restore puts MANAGER_VERSION in global.env back in line.
#
# Runs the real updater, offline helper, flock, kernel pipes, signals and /proc
# in tests/stagef/updater-harness.sh sandboxes (root needed for sandboxed
# chown/flock). Candidates and GitHub are models there (fake managers, curl
# model): this is MODEL evidence for control flow, with real process/lock
# observations. tests/stageg/real-process-oracle.py repeats G1/G2 with the real
# manager and real curl/TLS.
#
# Usage: process-fixture.sh [path/to/twebproxy-manager.sh] [case-filter-regex]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
FILTER="${2:-.}"
# shellcheck source=../stagef/updater-harness.sh
source "$ROOT/tests/stagef/updater-harness.sh"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'process-fixture: needs root (sandboxed chown/flock)'; exit 77; }
f_init "$MGR" || { echo 'process-fixture: setup failed'; exit 1; }
trap 'g_kill_case_processes 2>/dev/null; f_case_cleanup 2>/dev/null; f_fini' EXIT
export TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 TWEBPROXY_UPDATE_LOCK_WAIT=2
NEW=0.2.90

pass=0; fail=0
check() { # check ID description command...
  local id="$1" what="$2"; shift 2
  if "$@"; then printf 'PASS %s: %s\n' "$id" "$what"; pass=$((pass + 1))
  else printf 'FAIL %s: %s\n' "$id" "$what"; fail=$((fail + 1)); fi
}
begin() { CASE_ID="$1"; [[ "$CASE_ID" =~ $FILTER ]] || return 1; export F_PIN_KEY=A; f_case "$1"; }
out_has() { grep -Eq -- "$1" "$F_OUT"; }
alive() { # $1=pid file: the process exists and is not a zombie
  local st
  [[ -f "$1" ]] && st="$(awk '{print $3}' "/proc/$(<"$1")/stat" 2>/dev/null)" && [[ -n "$st" && "$st" != Z ]]
}
dead_within() { # $1=pid file $2=seconds: the process is gone (or reaped) within the time
  local i; for ((i = 0; i < $2 * 10; i++)); do alive "$1" || return 0; sleep 0.1; done; return 1
}

# PIDs of every process that has the case's update lock file open (independent
# /proc observation, not the manager's view).
lock_holders() {
  local lock fd pid
  lock="$(readlink -f "$F_CASE/run/lock/twebproxy-manager-update.lock")"
  for fd in /proc/[0-9]*/fd/*; do
    [[ "$(readlink "$fd" 2>/dev/null)" == "$lock" ]] || continue
    pid="${fd#/proc/}"; printf '%s\n' "${pid%%/*}"
  done | sort -un
}

# Every process started for this case carries F_CASE in its environment.
g_kill_case_processes() {
  local e p
  [[ -n "${F_CASE:-}" ]] || return 0
  for e in /proc/[0-9]*/environ; do
    p="${e#/proc/}"; p="${p%%/*}"
    [[ "$p" != "$$" && "$p" != "$BASHPID" ]] || continue
    { tr '\0' '\n' < "$e"; } 2>/dev/null | grep -qxF "F_CASE=$F_CASE" && kill -KILL "$p" 2>/dev/null
  done
  return 0
}
case_end() { g_kill_case_processes; f_case_cleanup; }

# A candidate (or installed manager) whose probe leaves a descendant holding stdout.
stdout_child() { # $1=--help|--json  $2=seconds the descendant lives  [$3=pid file]
  printf 'if [[ "${1:-}" == %s ]]; then sleep %s & echo "$!" > %q; fi' "$1" "$2" "${3:-$F_CASE/child.pid}"
}

# ================== G1: health probes with stdout-holding descendants =======

if begin g1-help-descendant-holds-stdout; then
  f_publish "$NEW" "extra=$(stdout_child --help 40)"
  start=$SECONDS; F_TIMEOUT=90 f_update; took=$((SECONDS - start))
  check "$CASE_ID.bounded" "the update ends within the probe bound, not with the descendant (${took}s)" test "$took" -lt 20
  check "$CASE_ID.success" 'a healthy candidate is still installed (UPDATE_SUCCESS)' out_has '^UPDATE_SUCCESS backup_id=update-'
  check "$CASE_ID.installed" 'both copies are the candidate' f_copies_are "$F_CANDIDATE_HASH"
  check "$CASE_ID.no-orphan" 'the probe descendant does not outlive the probe' dead_within "$F_CASE/child.pid" 3
  check "$CASE_ID.lock" 'lock free afterwards' f_lock_free
  case_end
fi

if begin g1-overview-descendant-holds-stdout; then
  f_publish "$NEW" "extra=$(stdout_child --json 40)"
  start=$SECONDS; F_TIMEOUT=90 f_update; took=$((SECONDS - start))
  check "$CASE_ID.bounded" "the update ends within the probe bound (${took}s)" test "$took" -lt 20
  check "$CASE_ID.success" 'UPDATE_SUCCESS' out_has '^UPDATE_SUCCESS backup_id=update-'
  check "$CASE_ID.no-orphan" 'the probe descendant does not outlive the probe' dead_within "$F_CASE/child.pid" 3
  check "$CASE_ID.lock" 'lock free afterwards' f_lock_free
  case_end
fi

if begin g1-preflight-descendant-holds-stdout; then
  # The INSTALLED manager's probe misbehaves: the preflight before any change.
  f_fake_manager "$F_CASE/usr/twebproxy" "$F_LOCAL_VERSION" good "$F_LOCAL_VERSION-beta" "$(stdout_child --help 40)"
  install -o root -g root -m 0755 "$F_CASE/usr/twebproxy" "$F_CASE/opt/twebproxy-manager.sh"
  F_OLD_HASH="$(f_sha "$F_CASE/usr/twebproxy")"
  f_publish "$NEW"
  start=$SECONDS; F_TIMEOUT=90 f_update; took=$((SECONDS - start))
  check "$CASE_ID.bounded" "the preflight probe is bounded too (${took}s)" test "$took" -lt 20
  check "$CASE_ID.success" 'the update proceeds (UPDATE_SUCCESS)' out_has '^UPDATE_SUCCESS'
  check "$CASE_ID.no-orphan" 'no probe descendant left' dead_within "$F_CASE/child.pid" 3
  case_end
fi

if begin g1-hanging-probe-with-descendant-rolls-back; then
  f_publish "$NEW" "extra=if [[ \"\${1:-}\" == --help ]]; then sleep 90 & echo \"\$!\" > $(printf %q "$F_CASE/child.pid"); trap '' TERM; sleep 60; fi"
  start=$SECONDS; F_TIMEOUT=120 f_update; took=$((SECONDS - start))
  check "$CASE_ID.bounded" "a probe that ignores SIGTERM is killed within its bound (${took}s)" test "$took" -lt 45
  check "$CASE_ID.rolled-back" 'failed health -> rollback, no false success' out_has '^UPDATE_FAILED_ROLLBACK_SUCCESS'
  check "$CASE_ID.no-success" 'no UPDATE_SUCCESS' eval "! grep -q '^UPDATE_SUCCESS' '$F_OUT'"
  check "$CASE_ID.restored" 'both copies are the previous manager' f_copies_are "$F_OLD_HASH"
  check "$CASE_ID.no-orphan" 'no probe descendant left' dead_within "$F_CASE/child.pid" 3
  check "$CASE_ID.lock" 'lock free afterwards' f_lock_free
  case_end
fi

if begin g1-escaped-descendant-does-not-block; then
  # A descendant that leaves the probe's process group cannot be killed by group,
  # but it must not hold the update either.
  f_publish "$NEW" "extra=if [[ \"\${1:-}\" == --help ]]; then setsid sleep 40 & echo \"\$!\" > $(printf %q "$F_CASE/child.pid"); fi"
  start=$SECONDS; F_TIMEOUT=90 f_update; took=$((SECONDS - start))
  check "$CASE_ID.bounded" "the update is not held by an escaped descendant (${took}s)" test "$took" -lt 20
  check "$CASE_ID.success" 'UPDATE_SUCCESS' out_has '^UPDATE_SUCCESS'
  check "$CASE_ID.lock" 'lock free while the escaped descendant still runs' f_lock_free
  case_end
fi

# ================== G2: the update lock stays with the updater ==============

if begin g2-blocked-download-parent-sigkill; then
  f_publish "$NEW"
  f_fault "https://raw.githubusercontent.com/$F_SLUG/$F_COMMIT/twebproxy-manager.sh" hang
  ( F_TIMEOUT=120 f_update ) & bg=$!
  for ((i = 0; i < 200; i++)); do grep -q '/twebproxy-manager\.sh$' "$F_REMOTE/requests" && break; sleep 0.05; done
  sleep 0.5
  mgr="$(<"$F_CASE/pid")"
  holders="$(lock_holders | tr '\n' ' ')"
  check "$CASE_ID.blocked" 'the download is in progress (precondition)' grep -q '/twebproxy-manager\.sh$' "$F_REMOTE/requests"
  check "$CASE_ID.only-owner" "only the updater holds the lock during the download (holders: ${holders% })" test "${holders% }" = "$mgr"
  F_OUT="$F_CASE/second.out"
  TWEBPROXY_UPDATE_LOCK_WAIT=1 f_run manager_update_cmd > "$F_OUT" 2>&1; rc2=$?
  check "$CASE_ID.concurrent-refused" "a concurrent update is still refused while the owner lives (rc=$rc2)" \
    eval "test $rc2 -ne 0 && ! grep -q '^UPDATE_SUCCESS' '$F_OUT'"
  kill -KILL "$mgr" 2>/dev/null
  sleep 0.3
  check "$CASE_ID.free-after-kill" 'the lock is free right after a parent-only SIGKILL' f_lock_free
  check "$CASE_ID.unchanged" 'installed copies unchanged' f_copies_are "$F_OLD_HASH"
  g_kill_case_processes; wait "$bg" 2>/dev/null
  rm -f "$F_REMOTE/fault/raw.githubusercontent.com/$F_SLUG/$F_COMMIT/twebproxy-manager.sh"
  f_update
  check "$CASE_ID.next-update" 'the next update recovers the stale staging and succeeds' out_has '^UPDATE_SUCCESS'
  check "$CASE_ID.no-leftovers" 'no staging or temp leftovers' test -z "$(f_leftovers)"
  case_end
fi

if begin g2-release-check-parent-sigkill; then
  f_publish "$NEW"
  f_fault "https://api.github.com/repos/$F_SLUG/releases/latest" hang
  ( F_TIMEOUT=120 f_update ) & bg=$!
  for ((i = 0; i < 200; i++)); do grep -q 'releases/latest$' "$F_REMOTE/requests" && break; sleep 0.05; done
  sleep 0.5
  mgr="$(<"$F_CASE/pid")"
  holders="$(lock_holders | tr '\n' ' ')"
  check "$CASE_ID.only-owner" "only the updater holds the lock during the release query (holders: ${holders% })" test "${holders% }" = "$mgr"
  kill -KILL "$mgr" 2>/dev/null; sleep 0.3
  check "$CASE_ID.free-after-kill" 'the lock is free right after a parent-only SIGKILL' f_lock_free
  g_kill_case_processes; wait "$bg" 2>/dev/null
  case_end
fi

if begin g2-health-probe-lock-holders; then
  f_publish "$NEW" "extra=if [[ \"\${1:-}\" == --help ]]; then : > $(printf %q "$F_CASE/probing"); sleep 3; fi"
  ( F_TIMEOUT=120 f_update ) & bg=$!
  for ((i = 0; i < 400; i++)); do [[ -e "$F_CASE/probing" ]] && break; sleep 0.05; done
  sleep 0.3
  mgr="$(<"$F_CASE/pid")"
  holders="$(lock_holders | tr '\n' ' ')"
  check "$CASE_ID.probing" 'the candidate health probe is running (precondition)' test -e "$F_CASE/probing"
  check "$CASE_ID.only-owner" "only the updater holds the lock during the health gate (holders: ${holders% })" test "${holders% }" = "$mgr"
  wait "$bg"
  F_OUT="$F_CASE/out.1"
  check "$CASE_ID.success" 'the update completes normally' out_has '^UPDATE_SUCCESS'
  case_end
fi

if begin g2-rollback-helper-keeps-lock; then
  # The one child that needs the lock: the rollback helper restores under it.
  f_publish "$NEW" behavior=bad-overview
  cat > "$F_CASE/bin/install" <<'SH'
#!/bin/bash
# barrier: the rollback's first staged copy waits until $F_CASE/release exists
dest="${*: -1}"
if [[ "${TWEBPROXY_STAGE4_LOCK_HELD:-}" == 1 && "$(basename -- "$dest")" == .twebproxy-stage4.* && ! -e "$F_CASE/parked" ]]; then
  : > "$F_CASE/parked"; echo "$PPID" > "$F_CASE/helper.pid"
  while [[ ! -e "$F_CASE/release" ]]; do sleep 0.05; done
fi
exec /usr/bin/install "$@"
SH
  chmod 0755 "$F_CASE/bin/install"
  ( F_TIMEOUT=120 f_update ) & bg=$!
  for ((i = 0; i < 600; i++)); do [[ -e "$F_CASE/parked" ]] && break; sleep 0.05; done
  mgr="$(<"$F_CASE/pid")"; helper="$(<"$F_CASE/helper.pid")"
  holders=" $(lock_holders | tr '\n' ' ')"
  check "$CASE_ID.parked" 'the rollback is in progress (precondition)' test -e "$F_CASE/parked"
  check "$CASE_ID.helper-holds" "the rollback helper holds the lock with the updater (holders:${holders% })" eval "[[ '$holders' == *' $mgr '* && '$holders' == *' $helper '* ]]"
  kill -KILL "$mgr" 2>/dev/null; sleep 0.3
  check "$CASE_ID.still-locked" 'with the updater killed, the lock stays with the running restore' eval '! f_lock_free'
  : > "$F_CASE/release"
  for ((i = 0; i < 300; i++)); do f_lock_free && break; sleep 0.1; done
  check "$CASE_ID.restored" 'the restore completes: both copies are the previous manager' f_copies_are "$F_OLD_HASH"
  check "$CASE_ID.free" 'and then the lock is free' f_lock_free
  g_kill_case_processes; wait "$bg" 2>/dev/null
  case_end
fi

# ================== G3: metadata after an offline restore ===================

if begin g3-offline-restore-metadata; then
  f_publish "$NEW"
  f_update
  check "$CASE_ID.updated" 'update succeeded, global.env says the new version (precondition)' \
    eval "grep -q '^UPDATE_SUCCESS' '$F_OUT' && grep -qx 'MANAGER_VERSION=$NEW' '$F_CASE/etc/global.env'"
  grep -v '^MANAGER_VERSION=' "$F_CASE/etc/global.env" > "$F_CASE/other-keys.before"
  : > "$F_REMOTE/offline"
  "$F_CASE/libexec/restore-update-backup" restore-latest > "$F_CASE/restore.out" 2>&1; rc=$?
  check "$CASE_ID.restore" "offline restore-latest succeeds (rc=$rc)" grep -q '^RESTORE_SUCCESS' "$F_CASE/restore.out"
  check "$CASE_ID.copies" 'both copies are the previous manager' f_copies_are "$F_OLD_HASH"
  check "$CASE_ID.metadata" 'global.env MANAGER_VERSION follows the restored manager' grep -qx "MANAGER_VERSION=$F_LOCAL_VERSION" "$F_CASE/etc/global.env"
  check "$CASE_ID.other-keys" 'all other global.env lines are unchanged' \
    eval "diff -q <(grep -v '^MANAGER_VERSION=' '$F_CASE/etc/global.env') '$F_CASE/other-keys.before' >/dev/null"
  check "$CASE_ID.mode" 'global.env stays root 0600' test "$(stat -c '%u:%g:%a' "$F_CASE/etc/global.env")" = 0:0:600
  case_end
fi

if begin g3-metadata-symlink-not-followed; then
  f_publish "$NEW"
  f_update
  printf 'MANAGER_VERSION=9.9.9\n' > "$F_CASE/elsewhere.env"; chmod 0600 "$F_CASE/elsewhere.env"
  mv "$F_CASE/etc/global.env" "$F_CASE/etc/global.env.real"; ln -s "$F_CASE/elsewhere.env" "$F_CASE/etc/global.env"
  "$F_CASE/libexec/restore-update-backup" restore-latest > "$F_CASE/restore.out" 2>&1; rc=$?
  # v0.2.23 (P1-G-01): executables restored, metadata not -> partial, never success.
  check "$CASE_ID.restore" 'the executables are still restored' f_copies_are "$F_OLD_HASH"
  check "$CASE_ID.partial" "reported as RESTORE_PARTIAL with status 3 (rc=$rc)" \
    eval "grep -q '^RESTORE_PARTIAL .* metadata=stale' '$F_CASE/restore.out' && ! grep -q '^RESTORE_SUCCESS' '$F_CASE/restore.out' && test $rc -eq 3"
  check "$CASE_ID.not-followed" 'a symlinked global.env is not written through' grep -qx 'MANAGER_VERSION=9.9.9' "$F_CASE/elsewhere.env"
  check "$CASE_ID.link-kept" 'and the link itself is left alone' test -L "$F_CASE/etc/global.env"
  case_end
fi

printf '\nprocess-fixture: %s pass, %s fail\n' "$pass" "$fail"
(( fail == 0 ))
