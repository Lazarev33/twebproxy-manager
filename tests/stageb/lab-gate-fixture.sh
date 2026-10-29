#!/usr/bin/env bash
# R5 regression: real privileged tests (kernel nft, systemd, namespaces, mounts,
# genuine ENOSPC) must never run unless a disposable lab host was explicitly
# prepared. A default run must report NOT_EXECUTED (77), never PASS, and must
# not invoke a single privileged command - also on a production TWebProxy host.
#
# Safe by construction: the gated scripts run with sentinel nft/unshare/mount/
# systemctl/... first in PATH and TWEBPROXY_LAB_MODE removed; any sentinel call
# is a failure. Authorized decisions are exercised only on synthetic roots.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-lab-gate.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
pass=0; fail=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

GATED=(
  tests/stageb/real-nft-validation.sh
  tests/stageb/real-systemd-validation.sh
  tests/stagea/sa1-real-nft-validation.sh
  tests/stagea/sa3-state-publication.sh
  tests/fieldgate/tg1-real-nft-six-mode-gate.sh
  tests/fieldgate/tg3-installed-manager-lifecycle.sh
)
PRIVILEGED='\bunshare\b|\bmount\b|\bumount\b|command -v nft|/run/systemd/system'

# ---------- 1. gate decision on synthetic roots ----------
source "$ROOT/tests/lib/lab-gate.sh"
lab_root() { # $1=name -> prepared lab root with a valid marker
  local r="$TMP/root-$1"
  install -d -m 0755 "$r/etc"
  printf '0123456789abcdef0123456789abcdef\n' > "$r/etc/machine-id"
  printf '0123456789abcdef0123456789abcdef\n' > "$r/etc/twebproxy-disposable-lab"
  printf '%s' "$r"
}
allowed() { TWEBPROXY_LAB_MODE="$1" lab_gate_check "$2" "$3" >/dev/null; }
refused() { ! allowed "$@"; }
good="$(lab_root good)"
check gate_allows_prepared_lab allowed disposable-vm "$good" 0
check gate_refuses_without_opt_in refused "" "$good" 0
check gate_refuses_wrong_opt_in_value refused 1 "$good" 0
check gate_refuses_non_root refused disposable-vm "$good" 1000
r="$(lab_root nomarker)"; rm "$r/etc/twebproxy-disposable-lab"
check gate_refuses_missing_marker refused disposable-vm "$r" 0
r="$(lab_root symlink)"; mv "$r/etc/twebproxy-disposable-lab" "$r/etc/real-marker"
ln -s real-marker "$r/etc/twebproxy-disposable-lab"
check gate_refuses_symlink_marker refused disposable-vm "$r" 0
r="$(lab_root foreign)"; printf 'ffffffffffffffffffffffffffffffff\n' > "$r/etc/twebproxy-disposable-lab"
check gate_refuses_marker_from_other_host refused disposable-vm "$r" 0
r="$(lab_root noid)"; rm "$r/etc/machine-id"
check gate_refuses_without_machine_id refused disposable-vm "$r" 0
if [[ $EUID -eq 0 ]]; then
  r="$(lab_root owner)"; chown 65534 "$r/etc/twebproxy-disposable-lab"
  check gate_refuses_non_root_marker refused disposable-vm "$r" 0
fi
for fp in "${LAB_GATE_FINGERPRINTS[@]}"; do
  r="$(lab_root "fp${fp//\//_}")"; install -d "$r${fp%/*}"; : > "$r$fp"
  check "gate_refuses_installed_fingerprint${fp//\//_}" refused disposable-vm "$r" 0
done
r="$(lab_root unit)"; install -d "$r/etc/systemd/system"; : > "$r/etc/systemd/system/twebproxy-firewall.service"
check gate_refuses_installed_unit refused disposable-vm "$r" 0
r="$(lab_root dangling)"; install -d "$r/etc"; ln -s /nonexistent "$r/etc/twebproxy"
check gate_refuses_dangling_fingerprint_symlink refused disposable-vm "$r" 0
out="$(TWEBPROXY_LAB_MODE= bash -c 'source "$1"; lab_gate_or_exit demo; echo REACHED' _ "$ROOT/tests/lib/lab-gate.sh")"; rc=$?
check gate_or_exit_returns_77 test "$rc" -eq 77
check gate_or_exit_reports_not_executed grep -q '^NOT_EXECUTED_ENVIRONMENT_LIMITATION demo:' <<<"$out"
check gate_or_exit_stops_script bash -c '! grep -q REACHED <<<"$1"' _ "$out"

# ---------- 2. every real-privilege script is gated before its first privileged line ----------
# grep -c reads all input: `grep -q` would SIGPIPE the producer under pipefail
# and silently drop large files from the scan.
uses_privilege() { grep -vE '^[[:space:]]*#' "$ROOT/$1" | grep -cE "$PRIVILEGED" >/dev/null; }
mapfile -t found < <(cd "$ROOT" && find tests -name '*.sh' | sort | while read -r f; do
  [[ "$f" == tests/stageb/lab-gate-fixture.sh || "$f" == tests/lib/lab-gate.sh ]] && continue
  uses_privilege "$f" && printf '%s\n' "$f"; done)
expected="$(printf '%s\n' "${GATED[@]}" | sort)"
if [[ "$(printf '%s\n' "${found[@]}")" == "$expected" ]]; then ok no_ungated_privileged_script_in_tree
else
  bad no_ungated_privileged_script_in_tree
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "${found[@]}") | sed 's/^/  expected<>found: /' >&2
fi
declare -A STATICALLY_GATED=()
for f in "${GATED[@]}"; do
  gate_line="$(grep -nE '^[^#]*lab_gate_(or_exit|allows)\b' "$ROOT/$f" | head -n1 | cut -d: -f1)"
  priv_line="$(grep -nE "$PRIVILEGED" "$ROOT/$f" | grep -vE '^[0-9]+:\s*#' | head -n1 | cut -d: -f1)"
  if [[ -n "$gate_line" && -n "$priv_line" && "$gate_line" -lt "$priv_line" ]]; then
    ok "gate_precedes_privilege:${f##*/}"; STATICALLY_GATED[$f]=1
  else
    bad "gate_precedes_privilege:${f##*/} (gate line '${gate_line:-none}', first privileged line '${priv_line:-none}')"
  fi
done

# ---------- 3. default execution: NOT_EXECUTED, no privileged command at all ----------
SENTINEL="$TMP/sentinel"; mkdir -p "$SENTINEL"
for c in nft unshare nsenter mount umount systemctl systemd-run ip sysctl modprobe iptables; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 97\n' "$c" "$TMP" > "$SENTINEL/$c"
done
chmod 0755 "$SENTINEL"/*
# An ungated script is never executed here: an older tg3 with TG3_INNER=1, for
# example, would install over the host's real /usr/local/sbin/twebproxy.
for f in "${GATED[@]}"; do
  name="${f##*/}"; : > "$TMP/calls"
  if [[ -z "${STATICALLY_GATED[$f]:-}" ]]; then bad "default_run_skipped_ungated_script:$name"; continue; fi
  env -u TWEBPROXY_LAB_MODE -u TG3_INNER PATH="$SENTINEL:$PATH" \
    timeout 600 bash "$ROOT/$f" "$MGR" > "$TMP/$name.out" 2>&1; rc=$?
  check "default_run_not_executed_rc77:$name" test "$rc" -eq 77
  check "default_run_reports_not_executed:$name" grep -q '^NOT_EXECUTED' "$TMP/$name.out"
  check "default_run_no_privileged_command:$name" test ! -s "$TMP/calls"
  [[ ! -s "$TMP/calls" ]] || sed 's/^/  sentinel: /' "$TMP/calls" >&2
  if [[ "$rc" -ne 77 || -s "$TMP/calls" ]]; then sed 's/^/  | /' "$TMP/$name.out" | tail -n 15 >&2; fi
done
# The legacy inner-phase markers are not a bypass of the gate.
if [[ -n "${STATICALLY_GATED[tests/fieldgate/tg3-installed-manager-lifecycle.sh]:-}" ]]; then
  : > "$TMP/calls"
  env -u TWEBPROXY_LAB_MODE TG3_INNER=1 PATH="$SENTINEL:$PATH" \
    timeout 120 bash "$ROOT/tests/fieldgate/tg3-installed-manager-lifecycle.sh" "$MGR" > "$TMP/tg3-inner.out" 2>&1; rc=$?
  check tg3_inner_marker_is_not_a_bypass test "$rc" -eq 77 -a ! -s "$TMP/calls"
else
  bad tg3_inner_marker_is_not_a_bypass_not_run_ungated
fi
if [[ -n "${STATICALLY_GATED[tests/stageb/real-nft-validation.sh]:-}" ]]; then
  : > "$TMP/calls"
  env -u TWEBPROXY_LAB_MODE PATH="$SENTINEL:$PATH" \
    timeout 120 bash "$ROOT/tests/stageb/real-nft-validation.sh" "$MGR" --inside > "$TMP/inside.out" 2>&1; rc=$?
  check real_nft_inside_argument_is_not_a_bypass test "$rc" -eq 77 -a ! -s "$TMP/calls"
else
  bad real_nft_inside_argument_is_not_a_bypass_not_run_ungated
fi

# ---------- 4. runners keep the 0/1/77 protocol (77 is never PASS) ----------
for r in tests/stagea/run-stage-a-suite.sh tests/stageb/run-stage-b-suite.sh tests/fieldgate/run-fieldgate-suite.sh; do
  check "runner_uses_result_protocol:${r##*/}" grep -q 'stage_a_run_case' "$ROOT/$r"
done

printf 'lab-gate: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
