#!/usr/bin/env bash
# TG-5b — production-errexit control-flow regression for the TWP-003 gate.
#
# The manager runs with `set -Eeuo pipefail`. A bare
#     dpi_scope_locally_configured "$ip"
#     case $? in ...
# is NOT an errexit-safe way to capture a return code: when the probe returns 1
# or 2 the ERR trap fires and execution stops before the `case` is reached. The
# operator then sees the generic "Error at line N" instead of the localized,
# actionable message, and audit collection aborts instead of recording ERROR.
#
# TG-5 cannot see this: it does `set +e` after sourcing the manager so it can
# check return codes itself. This file therefore drives the affected commands in
# separate subprocesses that keep PRODUCTION semantics exactly - no `set +e`,
# ERR trap left installed.
#
# Usage: tg5b-errexit-control-flow.sh [path/to/twebproxy-manager.sh]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
MGR="$(cd "$(dirname "$MGR")" && pwd -P)/$(basename "$MGR")"

pass=0; fail=0
t_ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
t_bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }

TMP="$(mktemp -d /tmp/tg5b-errexit.XXXXXX)"; trap 'rm -rf -- "$TMP"' EXIT
PUBLIC_IP=198.51.100.10
PRIVATE_IP=172.31.4.7

# ---- shared driver preamble: production errexit, ERR trap installed ---------
# Deliberately NO `set +e` and NO `trap - ERR` around the code under test.
cat > "$TMP/preamble.sh" <<'PRE'
BASE_DIR="$SB/etc"; INSTANCES_DIR="$BASE_DIR/instances"
DPI_DIR="$BASE_DIR/dpi"; DPI_STATE_DIR="$DPI_DIR/scopes"; DPI_NFT_FILE="$DPI_DIR/firewall.nft"
LIBEXEC_DIR="$SB/libexec"; SYSTEMD_DIR="$SB/systemd"; DPI_DOC_DIR="$SB/doc"
LOG_RUNTIME_DIR="$SB/logs"
DPI_NFT_BIN="$SB/bin/nft"
install -d -m 0700 "$BASE_DIR" "$INSTANCES_DIR" >/dev/null 2>&1
mkdir -p "$SB/logs" "$SB/libexec" "$SB/systemd" "$INSTANCES_DIR/alpha.example"
: > "$INSTANCES_DIR/alpha.example/instance.env"
UI_LANGUAGE=en
getent() { case "${1:-}" in ahostsv4) printf '%s STREAM alpha.example\n' "$PUB";; *) return 1;; esac; }
systemctl() { return 0; }
case "$LOCALITY" in
  local)           dpi_local_ipv4_addresses() { printf '%s\n' "$PUB"; } ;;
  notlocal)        dpi_local_ipv4_addresses() { printf '%s\n' "$PRIV"; } ;;
  undeterminable)  dpi_local_ipv4_addresses() { return 1; } ;;
esac
PRE

mkdrv() { # $1=name  $2=body executed under production errexit
  { printf '#!/usr/bin/env bash\nMGR="$1"; SB="$2"; LOCALITY="$3"; PUB="$4"; PRIV="$5"\n'
    printf 'source "$MGR"\n'
    cat "$TMP/preamble.sh"
    printf '%s\n' "$2"
  } > "$TMP/$1"
}
run() { # $1=driver $2=locality -> OUT, RC
  local sb="$TMP/sb-$1-$2"; rm -rf "$sb"; mkdir -p "$sb"
  OUT="$(timeout 90 bash "$TMP/$1" "$MGR" "$sb" "$2" "$PUBLIC_IP" "$PRIVATE_IP" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
  RC=${PIPESTATUS[0]}
}
errtrap_fired() { grep -qE 'Error at line [0-9]+\. Command:|Ошибка на строке' <<<"$OUT"; }

# =============== A. non-local scope through dpi_set_cmd ======================
mkdrv drv-set.sh 'dpi_set_cmd alpha.example mss88 --accept-shared-scope'
run drv-set.sh notlocal
if grep -q 'is not configured on any local interface' <<<"$OUT"; then
  t_ok "tg5b_A_setcmd_notlocal_reaches_localized_message"
else
  t_bad "tg5b_A_setcmd_notlocal_reaches_localized_message: got '$(head -2 <<<"$OUT" | tr '\n' ' ')'"
fi
if errtrap_fired; then
  t_bad "tg5b_A_setcmd_notlocal_no_generic_err_trap: generic ERR trap fired before the intended path"
else
  t_ok "tg5b_A_setcmd_notlocal_no_generic_err_trap"
fi
# the refusal must still be a refusal, and must not touch state
[[ "$RC" -ne 0 ]] && t_ok "tg5b_A_setcmd_notlocal_still_fails_closed (rc=$RC)" \
                 || t_bad "tg5b_A_setcmd_notlocal_still_fails_closed: rc=0"
sbA="$TMP/sb-drv-set.sh-notlocal"
if [[ -e "$sbA/etc/dpi/scopes" ]] && [[ -n "$(ls -A "$sbA/etc/dpi/scopes" 2>/dev/null)" ]]; then
  t_bad "tg5b_A_setcmd_notlocal_no_state_written"
else
  t_ok "tg5b_A_setcmd_notlocal_no_state_written"
fi
[[ -e "$sbA/etc/dpi/firewall.nft" ]] \
  && t_bad "tg5b_A_setcmd_notlocal_no_runtime_written" \
  || t_ok "tg5b_A_setcmd_notlocal_no_runtime_written"

# =============== B. undeterminable scope through dpi_set_cmd =================
run drv-set.sh undeterminable
if grep -q 'could not be determined' <<<"$OUT"; then
  t_ok "tg5b_B_setcmd_undeterminable_reaches_localized_message"
else
  t_bad "tg5b_B_setcmd_undeterminable_reaches_localized_message: got '$(head -2 <<<"$OUT" | tr '\n' ' ')'"
fi
errtrap_fired \
  && t_bad "tg5b_B_setcmd_undeterminable_no_generic_err_trap" \
  || t_ok "tg5b_B_setcmd_undeterminable_no_generic_err_trap"
[[ "$RC" -ne 0 ]] && t_ok "tg5b_B_setcmd_undeterminable_still_fails_closed (rc=$RC)" \
                 || t_bad "tg5b_B_setcmd_undeterminable_still_fails_closed: rc=0"

# =============== C/D. dpi_collect_host_check must not abort collection =======
# The marker after the call proves the surrounding collection continued.
mkdrv drv-audit.sh '
# An ACTIVE (non-STOCK) scope is required or dpi_collect_host_check short-circuits
# before the locality check and the defect path is never reached.
install -d -o root -g root -m 0700 "$DPI_STATE_DIR"
{ printf "FORMAT=%s\n" "$DPI_STATE_FORMAT"
  printf "IPV4=%s\n" "$PUB"
  printf "MODE=mss88\n"
  printf "HOSTNAME=alpha.example\n"
  printf "CONFIRMED_ADDRESS_SCOPE=yes\n"
  printf "UPDATED_AT=2026-01-01T00:00:00Z\n"; } > "$DPI_STATE_DIR/$PUB.env"
chown root:root "$DPI_STATE_DIR/$PUB.env"; chmod 0600 "$DPI_STATE_DIR/$PUB.env"
# sanity: the fixture must really be exercising a non-STOCK scope
row="$(dpi_mode_for_host alpha.example)"; printf "FIXTURE_MODE=%s\n" "${row#*	}"
tcore_reset audit global
dpi_collect_host_check alpha.example
printf "COLLECTION_CONTINUED\n"
for i in "${!TCORE_IDS[@]}"; do
  [[ "${TCORE_IDS[$i]}" == anti_dpi.mode ]] && printf "ANTI_DPI_STATUS=%s\n" "${TCORE_STATUSES[$i]}"
done
tcore_finalize
printf "OVERALL=%s\n" "$TCORE_OVERALL"
printf "DRIVER_COMPLETED\n"'

for loc in notlocal undeterminable; do
  label=$([[ "$loc" == notlocal ]] && echo C || echo D)
  run drv-audit.sh "$loc"
  grep -q 'FIXTURE_MODE=mss88' <<<"$OUT" \
    && t_ok "tg5b_${label}_fixture_exercises_active_mode" \
    || t_bad "tg5b_${label}_fixture_exercises_active_mode: scope is STOCK, defect path unreachable"
  grep -q 'COLLECTION_CONTINUED' <<<"$OUT" \
    && t_ok "tg5b_${label}_audit_${loc}_collection_not_aborted" \
    || t_bad "tg5b_${label}_audit_${loc}_collection_not_aborted: aborted at dpi_collect_host_check"
  grep -q 'ANTI_DPI_STATUS=ERROR' <<<"$OUT" \
    && t_ok "tg5b_${label}_audit_${loc}_records_error" \
    || t_bad "tg5b_${label}_audit_${loc}_records_error: got '$(grep -o 'ANTI_DPI_STATUS=[A-Z]*' <<<"$OUT" || echo none)'"
  grep -q 'DRIVER_COMPLETED' <<<"$OUT" && (( RC == 0 )) \
    && t_ok "tg5b_${label}_audit_${loc}_driver_exits_clean" \
    || t_bad "tg5b_${label}_audit_${loc}_driver_exits_clean: rc=$RC"
  errtrap_fired \
    && t_bad "tg5b_${label}_audit_${loc}_no_generic_err_trap" \
    || t_ok "tg5b_${label}_audit_${loc}_no_generic_err_trap"
done

# =============== E. the local (rc=0) path is unaffected ======================
run drv-audit.sh local
grep -q 'COLLECTION_CONTINUED' <<<"$OUT" && grep -q 'ANTI_DPI_STATUS=' <<<"$OUT" \
  && t_ok "tg5b_E_audit_local_scope_unaffected" \
  || t_bad "tg5b_E_audit_local_scope_unaffected"

printf 'tg5b: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
