#!/usr/bin/env bash
# TG-5 / TWP-003 regression.
#
# DPI rules match "ip saddr <public IPv4>" in the output hook. On 1:1-NAT clouds
# the guest only owns a private address, so the rule can never match - yet the
# audited build activated it and reported the mode healthy, because verification
# only grepped the rule text the manager itself had written.
#
# This regression pins the fail-closed contract:
#   dpi_local_ipv4_addresses      -> local IPv4s, one per line; rc=1 if undeterminable
#   dpi_scope_locally_configured  -> 0 configured | 1 not configured | 2 undeterminable
#
# nft/systemd are stubbed here on purpose: the subject is the scope gate, not nft
# syntax (TG-1 covers that against real nft) and not systemd.
#
# Usage: tg5-dpi-scope-local-address-gate.sh [path/to/twebproxy-manager.sh]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
pass=0; fail=0
t_ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
t_bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }

TMP="$(mktemp -d /tmp/tg5-scope.XXXXXX)"; trap 'rm -rf -- "$TMP"' EXIT
LOCAL_IPS="$TMP/local-ips"; LIVE="$TMP/live.nft"
PUBLIC_IP=198.51.100.10          # what DNS says / what the rule would match on
PRIVATE_IP=172.31.4.7            # what the NIC actually owns under 1:1 NAT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/nft" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
live="${MOCK_NFT_LIVE:?}"
if [[ "${1:-}" == -c && "${2:-}" == -f ]]; then grep -q '^table ip twebproxy_dpi {' "$3"
elif [[ "${1:-}" == -f ]]; then cp "$2" "$live"
elif [[ "${1:-}" == list ]]; then [[ -s "$live" ]] || exit 1; cat "$live"
elif [[ "${1:-}" == delete ]]; then rm -f "$live"
else exit 2; fi
MOCK
chmod 0755 "$TMP/bin/nft"; export MOCK_NFT_LIVE="$LIVE"

# shellcheck source=/dev/null
source "$MGR"
# The manager sets `set -Eeuo pipefail` when sourced. This harness checks return
# codes explicitly, so -e must not abort it on a deliberate non-zero result.
trap - ERR
set +e
BASE_DIR="$TMP/etc"; INSTANCES_DIR="$BASE_DIR/instances"
DPI_DIR="$BASE_DIR/dpi"; DPI_STATE_DIR="$DPI_DIR/scopes"; DPI_NFT_FILE="$DPI_DIR/firewall.nft"
LIBEXEC_DIR="$TMP/libexec"; SYSTEMD_DIR="$TMP/systemd"; DPI_DOC_DIR="$TMP/doc"
# The owned nfqws runtime files always live inside LIBEXEC_DIR; redirecting
# LIBEXEC_DIR alone leaves a layout the manager cannot be installed into, which
# trips dpi_remove_owned_nfqws_runtime_files' ownership guard for reasons that
# have nothing to do with this test's subject. Wire them together, as the other
# DPI fixtures do.
DPI_NFQWS_BIN="$LIBEXEC_DIR/twebproxy-nfqws"
DPI_NFQWS_SUM_FILE="$LIBEXEC_DIR/twebproxy-nfqws.sha256"
DPI_NFT_BIN="$TMP/bin/nft"
install -d -m 0700 "$BASE_DIR" "$INSTANCES_DIR"; mkdir -p "$LIBEXEC_DIR" "$SYSTEMD_DIR"
UI_LANGUAGE=en
# systemd is not PID 1 here. A blanket `systemctl() { return 0; }` used to claim
# every unit was always active, which is not how `is-active` behaves for a unit
# that was never installed; the shared model gets that right.
SYSTEMCTL_ACTIVE_DIR="$TMP/systemctl-active"
SYSTEMCTL_LOG="$TMP/systemctl.log"
# shellcheck source=/dev/null
source "$ROOT/tests/lib/systemctl-model.sh"
useradd() { return 0; }; userdel() { return 0; }

# Control which addresses the host appears to own. Overriding this function is
# the same seam the existing DPI fixture uses for systemctl/useradd - production
# gains no environment-variable backdoor.
dpi_local_ipv4_addresses() { [[ -s "$LOCAL_IPS" ]] || return 1; cat "$LOCAL_IPS"; }
getent() { # only ahostsv4/ahostsv6 are consulted by the DPI code
  case "${1:-}" in
    ahostsv4) printf '%s STREAM alpha.example\n' "$PUBLIC_IP";;
    ahostsv6) return 1;;
    *) return 1;;
  esac
}

have_gate=1
declare -F dpi_scope_locally_configured >/dev/null || have_gate=0
if (( ! have_gate )); then
  t_bad "tg5_scope_gate_exists: dpi_scope_locally_configured is not implemented"
fi

# ---------- contract of the probe itself ----------
if (( have_gate )); then
  printf '%s\n' "$PRIVATE_IP" "$PUBLIC_IP" > "$LOCAL_IPS"
  dpi_scope_locally_configured "$PUBLIC_IP"; rc=$?
  (( rc == 0 )) && t_ok "tg5_probe_reports_configured" || t_bad "tg5_probe_reports_configured: rc=$rc"
  printf '%s\n' "$PRIVATE_IP" > "$LOCAL_IPS"
  dpi_scope_locally_configured "$PUBLIC_IP"; rc=$?
  (( rc == 1 )) && t_ok "tg5_probe_reports_not_configured" || t_bad "tg5_probe_reports_not_configured: rc=$rc"
  : > "$LOCAL_IPS"
  dpi_scope_locally_configured "$PUBLIC_IP"; rc=$?
  (( rc == 2 )) && t_ok "tg5_probe_reports_undeterminable" || t_bad "tg5_probe_reports_undeterminable: rc=$rc"
fi

# ---------- 0. the REAL parser, exercised against simulated `ip` output ----------
# Everything below overrides dpi_local_ipv4_addresses to control locality, so this
# block is the only place the shipped awk/cut pipeline itself is executed.
( # re-source so the SHIPPED dpi_local_ipv4_addresses is used, not this
  # harness's locality stub defined above
  source "$MGR"; trap - ERR; set +e
  fake="$TMP/fakebin"; mkdir -p "$fake"
  cat > "$fake/ip" <<'IPMOCK'
#!/usr/bin/env bash
cat <<'OUT'
1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever
2: eth0    inet 172.31.4.7/20 brd 172.31.15.255 scope global dynamic eth0\       valid_lft 3421sec preferred_lft 3421sec
2: eth0    inet 198.51.100.10/32 scope global secondary eth0\       valid_lft forever preferred_lft forever
3: tun0    inet 10.8.0.1 peer 10.8.0.2/32 scope global tun0\       valid_lft forever preferred_lft forever
OUT
IPMOCK
  chmod 0755 "$fake/ip"
  got="$(PATH="$fake:$PATH" dpi_local_ipv4_addresses | paste -sd, -)"
  want='127.0.0.1,172.31.4.7,198.51.100.10,10.8.0.1'
  if [[ "$got" == "$want" ]]; then printf 'PASS tg5_real_parser_handles_ip_output\n'
  else printf 'FAIL tg5_real_parser_handles_ip_output: got %s want %s\n' "$got" "$want" >&2; exit 1; fi
) && pass=$((pass+1)) || fail=$((fail+1))

# ---------- 1. scope IPv4 is locally configured -> activation may proceed ----------
printf '%s\n' "$PRIVATE_IP" "$PUBLIC_IP" > "$LOCAL_IPS"
if dpi_transaction_set "$PUBLIC_IP" window1152 alpha.example >"$TMP/t1.log" 2>&1; then
  t_ok "tg5_local_scope_activation_proceeds"
else
  t_bad "tg5_local_scope_activation_proceeds: $(tail -2 "$TMP/t1.log" | tr '\n' ' ')"
fi
[[ -f "$DPI_STATE_DIR/$PUBLIC_IP.env" ]] \
  && t_ok "tg5_local_scope_state_written" || t_bad "tg5_local_scope_state_written"
active_state="$(cat "$DPI_STATE_DIR/$PUBLIC_IP.env" 2>/dev/null || true)"
active_live="$(cat "$LIVE" 2>/dev/null || true)"

# ---------- 2. scope IPv4 not locally configured -> fail closed ----------
printf '%s\n' "$PRIVATE_IP" > "$LOCAL_IPS"
if dpi_transaction_set "$PUBLIC_IP" mss88 alpha.example >"$TMP/t2.log" 2>&1; then
  t_bad "tg5_nonlocal_scope_fails_closed: activation succeeded on an unmatchable scope"
else
  t_ok "tg5_nonlocal_scope_fails_closed"
fi

# ---------- 3. failed activation preserves the previously active mode ----------
[[ "$(cat "$DPI_STATE_DIR/$PUBLIC_IP.env" 2>/dev/null || true)" == "$active_state" ]] \
  && t_ok "tg5_failed_activation_preserves_prior_state" \
  || t_bad "tg5_failed_activation_preserves_prior_state: prior DPI state was mutated"
[[ "$(cat "$LIVE" 2>/dev/null || true)" == "$active_live" ]] \
  && t_ok "tg5_failed_activation_preserves_live_rules" \
  || t_bad "tg5_failed_activation_preserves_live_rules"
grep -q window1152 "$DPI_STATE_DIR/$PUBLIC_IP.env" 2>/dev/null \
  && t_ok "tg5_prior_mode_still_window1152" || t_bad "tg5_prior_mode_still_window1152"

# ---------- 4. audit must not report an unmatchable scope as healthy ----------
mkdir -p "$INSTANCES_DIR/alpha.example"; : > "$INSTANCES_DIR/alpha.example/instance.env"
tcore_reset audit global
dpi_collect_host_check alpha.example >/dev/null 2>&1 || true
idx=-1
for i in "${!TCORE_IDS[@]}"; do [[ "${TCORE_IDS[$i]}" == anti_dpi.mode ]] && idx=$i; done
if (( idx < 0 )); then
  t_bad "tg5_audit_emits_anti_dpi_check"
else
  st="${TCORE_STATUSES[$idx]}"; msg="${TCORE_MESSAGES[$idx]}"
  [[ "$st" == ERROR ]] \
    && t_ok "tg5_audit_flags_nonlocal_scope (status=$st)" \
    || t_bad "tg5_audit_flags_nonlocal_scope: status=$st (must not be OK) msg='$msg'"
  [[ "$st" != OK ]] \
    && t_ok "tg5_audit_never_reports_ok_for_unmatchable_scope" \
    || t_bad "tg5_audit_never_reports_ok_for_unmatchable_scope"
fi

# ---------- 5. probe undeterminable -> fail closed, never assume reachable ----------
: > "$LOCAL_IPS"
if dpi_transaction_set "$PUBLIC_IP" mss88 alpha.example >"$TMP/t5.log" 2>&1; then
  t_bad "tg5_undeterminable_probe_fails_closed: activation proceeded without evidence"
else
  t_ok "tg5_undeterminable_probe_fails_closed"
fi

printf 'tg5: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
