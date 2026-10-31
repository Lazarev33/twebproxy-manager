#!/usr/bin/env bash
# P1-B real-host gate: an unintentionally unprotected effective /proc must not
# coexist with live, secret-bearing MTProxy backends as a result of manager
# operations; stacked proc mounts are judged by the effective (top) mount; an
# explicit operator opt-out stays possible, visible and deliberate.
#
# Usage: TWEBPROXY_PRERC_REAL=installed-test-host proc_fail_closed_probe.sh MANAGER OUTDIR
#   MANAGER  manager script to exercise (the baseline for RED, the candidate for GREEN)
# Exit 0 = every scenario GREEN, 1 = at least one RED, 77 = not executable here.
# Disposable lab host only. Scenarios S1-S3 change mounts only inside private
# mount namespaces; S4/S5 change the host /proc options briefly and restore them.
# Only booleans/counts about secrets are recorded, never a secret.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/lab-gate.sh"
installed_host_gate_or_exit prerc2-proc-fail-closed
MANAGER="${1:?manager}"; OUT="${2:?outdir}"
mapfile -t HOSTS < <(ls /etc/twebproxy/instances 2>/dev/null)
(( ${#HOSTS[@]} >= 1 )) || { echo "NOT_EXECUTED: no instances"; exit 77; }
mkdir -p "$OUT"; : > "$OUT/summary.tsv"
H1="${HOSTS[0]}"
GID="$(getent group twebproxy-procview | cut -d: -f3)"
FSTAB_SHA0="$(sha256sum /etc/fstab | cut -d' ' -f1)"
fail=0

# nobody/www-data/caddy -> count of live MTProxy processes whose -S argument
# the account can read through the effective /proc of the caller's namespace.
readers() {
  local u n=0 pid total=0
  for u in nobody www-data caddy; do
    id "$u" >/dev/null 2>&1 || continue
    for pid in $(pgrep -x mtproto-proxy); do
      total=$((total + 1))
      setpriv --reuid="$u" --regid="$(id -g "$u")" --clear-groups python3 -I -c '
import sys
try: a=open("/proc/"+sys.argv[1]+"/cmdline","rb").read().split(b"\0")
except OSError: a=[]
sys.exit(0 if any(a[i]==b"-S" and i+1<len(a) and len(a[i+1])==32 for i in range(len(a)-1)) else 1)' "$pid" && n=$((n + 1))
    done
  done
  printf '%s/%s' "$n" "$total"
}
active_backends() { systemctl list-units --all --no-legend --plain 'twebproxy-mtproxy@*.service' | grep -c ' active running ' || true; }
record() { # name verdict detail
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" | tee -a "$OUT/summary.tsv"
  [[ "$2" == GREEN ]] || fail=1
}
recover() { # restore the steady state with the candidate under test, in the host namespace
  local h rc=0
  mount -o "remount,hidepid=invisible,gid=$GID" /proc 2>/dev/null || true
  for h in "${HOSTS[@]}"; do bash "$MANAGER" repair "$h" </dev/null > "$OUT/recover-$1-$h.log" 2>&1 || rc=$?; done
  printf 'recover-%s rc=%s active=%s readers=%s\n' "$1" "$rc" "$(active_backends)" "$(readers)" | tee -a "$OUT/recover.log"
}
ns() { # name stub args...
  local name="$1"; shift
  unshare -m --propagation private python3 -I "$HERE/proc_ns_scenario.py" "$OUT/$name.json" "$MANAGER" "$@" 2>"$OUT/$name.err"
}
field() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }

echo "S0 baseline: active=$(active_backends) readers=$(readers) hidepid_host=$(findmnt -no OPTIONS /proc | tail -1)" | tee "$OUT/S0.txt"

# S1: failed procfs remount inside an unprotected effective /proc, then repair.
ns S1-repair-mount-fail mount-fail repair "$H1"
r="$(field "$OUT/S1-repair-mount-fail.json" nobody_readable_secrets)"; rc="$(field "$OUT/S1-repair-mount-fail.json" rc)"
[[ "$r" == 0 && "$rc" != 0 ]] && record S1-repair-mount-fail GREEN "rc=$rc readable=$r" || record S1-repair-mount-fail RED "rc=$rc readable=$r"
recover S1

# S2: same fault, restart path.
ns S2-restart-mount-fail mount-fail restart "$H1"
r="$(field "$OUT/S2-restart-mount-fail.json" nobody_readable_secrets)"; rc="$(field "$OUT/S2-restart-mount-fail.json" rc)"
[[ "$r" == 0 && "$rc" != 0 ]] && record S2-restart-mount-fail GREEN "rc=$rc readable=$r" || record S2-restart-mount-fail RED "rc=$rc readable=$r"
recover S2

# S3: stacked proc mounts (unprotected on top of the hidden host mount), no
# injected failure: the effective mount must be judged and hardened.
ns S3-repair-stacked none repair "$H1"
r="$(field "$OUT/S3-repair-stacked.json" nobody_readable_secrets)"; rc="$(field "$OUT/S3-repair-stacked.json" rc)"
[[ "$r" == 0 ]] && record S3-repair-stacked GREEN "rc=$rc readable=$r" || record S3-repair-stacked RED "rc=$rc readable=$r"
recover S3

# S4: host /proc unprotected WITHOUT an operator opt-out, by an out-of-band
# root remount (not a manager operation). Every systemd start must be refused
# by the start gate: a unit restart of B1, then a firewall restart that pulls
# in every backend. A backend nobody (re)started keeps running - outside the
# manager-operation scope; it is recorded separately and the audit must
# report the exposure as ERROR.
B1="$(systemctl list-units --all --no-legend --plain 'twebproxy-mtproxy@*.service' | awk 'NF{print $1; exit}')"
mount -o remount,hidepid=0 /proc
bash "$MANAGER" audit "$H1" </dev/null > "$OUT/S4-audit-exposed.log" 2>&1
audit_err="$(grep -c 'procfs показывает все процессы\|procfs shows every process' "$OUT/S4-audit-exposed.log" || true)"
untouched="$(readers)"
systemctl restart "$B1" >/dev/null 2>&1; rc1=$?
sleep 2
b1_state="$(systemctl is-active "$B1" 2>/dev/null)"; b1_pid="$(systemctl show -P MainPID "$B1")"
systemctl restart twebproxy-firewall.service >/dev/null 2>&1; rc2=$?
sleep 6; r2="$(readers)"; a2="$(active_backends)"
journalctl -u "$B1" -n 20 --no-pager 2>/dev/null | grep -o 'backend-start-check: .*' | tail -2 > "$OUT/S4-journal.txt" || true
mount -o "remount,hidepid=invisible,gid=$GID" /proc
d="unit_restart_rc=$rc1 b1=$b1_state/pid$b1_pid fw_restart_rc=$rc2 readers_after_fw=$r2 active_after_fw=$a2 audit_procfs_error=$audit_err untouched_backend_readers_before=$untouched"
[[ "$rc1" != 0 && "$b1_state" != active && "$b1_pid" == 0 && "${r2%%/*}" == 0 && "$a2" == 0 && "$audit_err" -ge 1 ]] &&
  record S4-systemd-start-unprotected GREEN "$d" || record S4-systemd-start-unprotected RED "$d"
recover S4

# S5: explicit operator opt-out is honoured, visible and recorded; then re-enabled.
bash "$MANAGER" proc-hardening disable </dev/null > "$OUT/S5-disable.log" 2>&1; drc=$?
systemctl restart "$B1" >/dev/null 2>&1; src=$?; sleep 2
st="$(systemctl is-active "$B1")"
warned="$(journalctl -u "$B1" -n 30 --no-pager 2>/dev/null | grep -c 'procfs hardening disabled by the operator' || true)"
bash "$MANAGER" audit "$H1" </dev/null > "$OUT/S5-audit.log" 2>&1
audit_warn="$(grep -c 'явно отключена оператором\|explicitly disabled by the operator' "$OUT/S5-audit.log" || true)"
policy="$(head -n1 /etc/twebproxy/proc-policy 2>/dev/null)"
bash "$MANAGER" proc-hardening enable </dev/null > "$OUT/S5-enable.log" 2>&1; erc=$?
[[ $drc == 0 && "$st" == active && "$policy" == off && $erc == 0 && "$audit_warn" -ge 1 ]] &&
  record S5-explicit-opt-out GREEN "disable_rc=$drc start=$st journal_warning=$warned audit_warning=$audit_warn policy=$policy enable_rc=$erc" ||
  record S5-explicit-opt-out RED "disable_rc=$drc start=$st journal_warning=$warned audit_warning=$audit_warn policy=$policy enable_rc=$erc"
recover S5

echo "FINAL: active=$(active_backends) readers=$(readers) hidepid_host=$(findmnt -no OPTIONS /proc | tail -1) fstab_changed=$([[ "$(sha256sum /etc/fstab | cut -d' ' -f1)" == "$FSTAB_SHA0" ]] && echo no || echo yes)" | tee "$OUT/final.txt"
exit "$fail"
