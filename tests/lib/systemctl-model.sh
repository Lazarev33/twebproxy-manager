#!/usr/bin/env bash
# Shared systemctl model for TWebProxy unit-lifecycle tests.
#
# This container has no systemd as PID 1, so the DPI runtime tests cannot drive
# a real service manager. The previous per-fixture stub was permissive enough to
# hide a real defect: it treated `disable` as "remove the active marker for every
# name given", so a multi-unit `systemctl disable --now A B` with a missing unit
# file still appeared to stop both units.
#
# This model reproduces the systemd behaviours the DPI teardown path depends on:
#   * unit-file presence is authoritative and lives in $SYSTEMD_DIR
#   * `enable`/`disable` validate every named unit first and fail the WHOLE call
#     when any unit file is absent, changing nothing
#   * `stop` works on a unit whose file has already been removed (an orphaned
#     unit stays loaded in memory), which is how a ghost is cleared
#   * removing a unit file while the unit is active leaves it active until it is
#     stopped - the field-observed "Loaded: not-found / Active: active (exited)"
#   * `is-enabled` returns 4 for a unit with no unit file
#
# It is a model, not systemd: see the environment-limitations note in the pass
# report. Ordering assertions in the tests are model-independent.
#
# Requires: $TMP (or $SYSTEMCTL_STATE_DIR) and $SYSTEMD_DIR.

SYSTEMCTL_STATE_DIR="${SYSTEMCTL_STATE_DIR:-${TMP:?systemctl-model: TMP or SYSTEMCTL_STATE_DIR must be set}/systemctl-model}"
SYSTEMCTL_ACTIVE_DIR="${SYSTEMCTL_ACTIVE_DIR:-$SYSTEMCTL_STATE_DIR/active}"
SYSTEMCTL_ENABLED_DIR="${SYSTEMCTL_ENABLED_DIR:-$SYSTEMCTL_STATE_DIR/enabled}"
SYSTEMCTL_LOG="${SYSTEMCTL_LOG:-$SYSTEMCTL_STATE_DIR/calls.log}"
# Per-unit trace including whether the unit file still existed at call time.
# This is what makes the "stop before the unit file is removed" ordering
# assertion independent of the model's own bookkeeping.
SYSTEMCTL_TRACE="${SYSTEMCTL_TRACE:-$SYSTEMCTL_STATE_DIR/trace.log}"
mkdir -p "$SYSTEMCTL_ACTIVE_DIR" "$SYSTEMCTL_ENABLED_DIR"
: > "$SYSTEMCTL_LOG"
: > "$SYSTEMCTL_TRACE"

# Test helpers: seed and inspect modelled unit state.
systemctl_model_unit_file() { printf '%s\n' "${SYSTEMD_DIR:?}/$1"; }
systemctl_model_seed_unit() {   # unit [active] [enabled]
  local unit="$1" active="${2:-1}" enabled="${3:-1}"
  mkdir -p "${SYSTEMD_DIR:?}"
  [[ -e "$SYSTEMD_DIR/$unit" ]] || printf '[Unit]\nDescription=model %s\n' "$unit" > "$SYSTEMD_DIR/$unit"
  (( active ))  && : > "$SYSTEMCTL_ACTIVE_DIR/$unit"  || rm -f "$SYSTEMCTL_ACTIVE_DIR/$unit"
  (( enabled )) && : > "$SYSTEMCTL_ENABLED_DIR/$unit" || rm -f "$SYSTEMCTL_ENABLED_DIR/$unit"
  return 0
}
systemctl_model_is_active()  { [[ -f "$SYSTEMCTL_ACTIVE_DIR/$1" ]]; }
systemctl_model_is_enabled() { [[ -f "$SYSTEMCTL_ENABLED_DIR/$1" && -f "${SYSTEMD_DIR:?}/$1" ]]; }

systemctl() {
  local verb="" now=0 a rc=0 unit
  local -a units=()
  printf '%q ' "$@" >> "$SYSTEMCTL_LOG"; printf '\n' >> "$SYSTEMCTL_LOG"
  for a in "$@"; do
    case "$a" in
      --now) now=1;;
      -*) ;;
      *) if [[ -z "$verb" ]]; then verb="$a"; else units+=("$a"); fi;;
    esac
  done
  for unit in "${units[@]}"; do
    if [[ -f "${SYSTEMD_DIR:-}/$unit" ]]; then a=yes; else a=no; fi
    printf '%s|%s|unitfile=%s|units=%s\n' "$verb" "$unit" "$a" "${#units[@]}" >> "$SYSTEMCTL_TRACE"
  done
  case "$verb" in
    daemon-reload|reset-failed|show|cat|status|list-units|list-unit-files)
      return 0;;
    enable|disable)
      # systemd resolves every named unit file up front and aborts the whole
      # operation when one is missing. This is exactly the case the DPI teardown
      # used to hide behind `|| true`.
      for unit in "${units[@]}"; do
        [[ -f "${SYSTEMD_DIR:?}/$unit" ]] || return 1
      done
      for unit in "${units[@]}"; do
        if [[ "$verb" == enable ]]; then
          : > "$SYSTEMCTL_ENABLED_DIR/$unit"
          (( now )) && : > "$SYSTEMCTL_ACTIVE_DIR/$unit"
        else
          rm -f "$SYSTEMCTL_ENABLED_DIR/$unit"
          (( now )) && rm -f "$SYSTEMCTL_ACTIVE_DIR/$unit"
        fi
      done
      return 0;;
    stop)
      # A unit whose file was deleted while it was running stays loaded, so stop
      # still deactivates it. This is the only way to clear a ghost.
      for unit in "${units[@]}"; do rm -f "$SYSTEMCTL_ACTIVE_DIR/$unit"; done
      return 0;;
    start|restart|reload)
      for unit in "${units[@]}"; do
        [[ -f "${SYSTEMD_DIR:?}/$unit" ]] || return 1
      done
      for unit in "${units[@]}"; do : > "$SYSTEMCTL_ACTIVE_DIR/$unit"; done
      return 0;;
    is-active)
      for unit in "${units[@]}"; do
        [[ -f "$SYSTEMCTL_ACTIVE_DIR/$unit" ]] || rc=3
      done
      return "$rc";;
    is-enabled)
      for unit in "${units[@]}"; do
        if [[ ! -f "${SYSTEMD_DIR:?}/$unit" ]]; then rc=4
        elif [[ ! -f "$SYSTEMCTL_ENABLED_DIR/$unit" ]]; then (( rc == 0 )) && rc=1
        fi
      done
      return "$rc";;
    *) return 0;;
  esac
}
