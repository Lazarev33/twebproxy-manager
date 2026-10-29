#!/usr/bin/env bash
# Stage A / A4 regression: a transient DNS failure must never delete canonical
# DPI intent.
#
# The 0.2.9 shape was:
#     hosts="$(dpi_hosts_for_ipv4 "$DPI_SCOPE_IPV4" 2>/dev/null || true)"
#     [[ -n "$hosts" ]] || rm -f "$file"
# dpi_hosts_for_ipv4 resolves every configured instance and prints the ones that
# map to the address. It returns EMPTY both when no host owns the address any
# more (a genuine orphan) and when the resolver could not answer at all - so a
# SERVFAIL, an unreachable resolver, or an ambiguous multi-address answer
# destroyed state the operator had deliberately configured.
#
# `getent` is replaced here because it is the resolver: that is the input under
# test, not the code under test. Everything else - dpi_prune_orphan_state,
# dpi_repair_all, dpi_remove_host_state_if_orphaned - is production code.
#
# Usage: sa4-dns-prune-safety.sh [path/to/twebproxy-manager.sh]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
pass=0; fail=0
t_ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
t_bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }

TMP="$(mktemp -d /tmp/sa4-dns.XXXXXX)"; trap 'rm -rf -- "$TMP"' EXIT

# shellcheck source=/dev/null
source "$ROOT/tests/lib/dpi-harness.sh"
dpi_harness_env "$TMP"
# shellcheck source=/dev/null
source "$MGR"
trap - ERR
set +e
dpi_harness_bind "$ROOT" "$TMP"

A_IP=198.51.100.10; B_IP=198.51.100.20
A_HOST=alpha.example; B_HOST=beta.example

# --- the resolver under test -------------------------------------------------
# DNS_MODE: ok | servfail | unreachable | ambiguous
DNS_MODE=ok
getent() {
  local db="${1:-}" host="${2:-}"
  [[ "$db" == ahostsv4 ]] || return 2
  case "$DNS_MODE" in
    servfail|unreachable) return 2;;                       # nothing resolves
    ambiguous) printf '%s STREAM %s\n%s STREAM %s\n' "$A_IP" "$host" "$B_IP" "$host"; return 0;;
  esac
  case "$host" in
    "$A_HOST") printf '%s STREAM %s\n' "$A_IP" "$host";;
    "$B_HOST") printf '%s STREAM %s\n' "$B_IP" "$host";;
    *) return 2;;
  esac
}
# Configured instances, independent of DNS.
INSTANCES="$A_HOST $B_HOST"
list_hosts_array() { local h; for h in $INSTANCES; do printf '%s\n' "$h"; done; }
instance_exists() { local h; for h in $INSTANCES; do [[ "$h" == "${1:-}" ]] && return 0; done; return 1; }
dpi_local_ipv4_addresses() { printf '%s\n' "$A_IP" "$B_IP"; }

reset_state() {
  rm -rf "$DPI_DIR" "$SYSTEMD_DIR" "$SYSTEMCTL_ACTIVE_DIR" "$SYSTEMCTL_ENABLED_DIR"
  mkdir -p "$SYSTEMD_DIR" "$SYSTEMCTL_ACTIVE_DIR" "$SYSTEMCTL_ENABLED_DIR"
  rm -f "$MOCK_NFT_LIVE"
  DNS_MODE=ok; INSTANCES="$A_HOST $B_HOST"
  CURRENT_LOG="$TMP/manager.log"; : > "$CURRENT_LOG"; chmod 0600 "$CURRENT_LOG"
  install -d -o root -g root -m 0700 "$DPI_DIR" "$DPI_STATE_DIR"
  dpi_write_scope_state "$DPI_STATE_DIR" "$A_IP" window1152 "$A_HOST"
  dpi_write_scope_state "$DPI_STATE_DIR" "$B_IP" mss88 "$B_HOST"
}
has() { [[ -f "$DPI_STATE_DIR/$1.env" ]]; }

printf '\n--- 0. precondition ---\n'
reset_state
has "$A_IP" && has "$B_IP" && t_ok sa4_precondition_two_scopes || t_bad sa4_precondition_two_scopes

# =====================================================================
# 1. transient resolver failures must preserve canonical intent
# =====================================================================
for mode in servfail unreachable ambiguous; do
  printf '\n--- 1.%s transient DNS: %s ---\n' "$mode" "$mode"
  reset_state
  DNS_MODE="$mode"
  dpi_prune_orphan_state >/dev/null 2>&1; rc=$?
  has "$A_IP" && t_ok "sa4_${mode}_scope_a_preserved" || t_bad "sa4_${mode}_scope_a_preserved: canonical intent destroyed by a transient DNS result"
  has "$B_IP" && t_ok "sa4_${mode}_scope_b_preserved" || t_bad "sa4_${mode}_scope_b_preserved: canonical intent destroyed by a transient DNS result"
  # repair() must reach the same conclusion through the higher-level path.
  reset_state; DNS_MODE="$mode"
  dpi_repair_all >/dev/null 2>&1
  has "$A_IP" && has "$B_IP" && t_ok "sa4_${mode}_repair_preserves_state" \
                             || t_bad "sa4_${mode}_repair_preserves_state"
done

# =====================================================================
# 2. a genuine orphan is still pruned - and only it
# =====================================================================
printf '\n--- 2. genuine orphan with a working resolver ---\n'
reset_state
INSTANCES="$B_HOST"                     # alpha.example was deleted by the operator
dpi_prune_orphan_state >/dev/null 2>&1; rc=$?
has "$A_IP" && t_bad "sa4_orphan_pruned: the deleted host's scope survived" \
            || t_ok  "sa4_orphan_pruned"
has "$B_IP" && t_ok  "sa4_orphan_prune_leaves_other_scope" \
            || t_bad "sa4_orphan_prune_leaves_other_scope"
(( rc == 0 )) && t_ok "sa4_orphan_prune_returns_success" || t_bad "sa4_orphan_prune_returns_success (rc=$rc)"

printf '\n--- 2b. deleted host + broken resolver: nothing else may be destroyed ---\n'
reset_state
INSTANCES="$B_HOST"; DNS_MODE=servfail
dpi_prune_orphan_state >/dev/null 2>&1
has "$B_IP" && t_ok "sa4_broken_resolver_keeps_surviving_host_scope" \
            || t_bad "sa4_broken_resolver_keeps_surviving_host_scope: a still-configured host lost its scope"

printf '\n--- 2c. every instance removed: the resolver is not needed to prune ---\n'
reset_state
INSTANCES=""; DNS_MODE=servfail
dpi_prune_orphan_state >/dev/null 2>&1
has "$A_IP" && t_bad sa4_no_instances_prunes_a || t_ok sa4_no_instances_prunes_a
has "$B_IP" && t_bad sa4_no_instances_prunes_b || t_ok sa4_no_instances_prunes_b

# =====================================================================
# 2d. a permanently multi-homed host must not freeze pruning for everyone
# =====================================================================
# dpi_resolve_ipv4 refuses a multi-address answer because ACTIVATION needs
# exactly one address. Ownership is a different question: if that refusal were
# read as "resolution failed", one multi-homed hostname would make every scope
# permanently unprunable. Caught by tests/stage-x-dpi-fixture.sh.
printf '\n--- 2d. multi-homed host present, genuine orphan elsewhere ---\n'
reset_state
MULTI_HOST=multi.example
INSTANCES="$B_HOST $MULTI_HOST"          # alpha.example deleted; multi is multi-homed
getent() {
  local db="${1:-}" host="${2:-}"
  [[ "$db" == ahostsv4 ]] || return 2
  case "$host" in
    "$A_HOST") printf '%s STREAM %s\n' "$A_IP" "$host";;
    "$B_HOST") printf '%s STREAM %s\n' "$B_IP" "$host";;
    "$MULTI_HOST") printf '203.0.113.7 STREAM %s\n203.0.113.8 STREAM %s\n' "$host" "$host";;
    *) return 2;;
  esac
}
dpi_prune_orphan_state >/dev/null 2>&1
has "$A_IP" && t_bad "sa4_multihomed_host_does_not_block_pruning: the genuine orphan survived" \
            || t_ok  "sa4_multihomed_host_does_not_block_pruning"
has "$B_IP" && t_ok  "sa4_multihomed_case_keeps_owned_scope" \
            || t_bad "sa4_multihomed_case_keeps_owned_scope"

printf '\n--- 2e. a multi-homed host that DOES own the address keeps it ---\n'
reset_state
install -d -o root -g root -m 0700 "$DPI_STATE_DIR"
dpi_write_scope_state "$DPI_STATE_DIR" 203.0.113.7 window1152 "$MULTI_HOST"
INSTANCES="$MULTI_HOST"
dpi_prune_orphan_state >/dev/null 2>&1
has 203.0.113.7 && t_ok  "sa4_multihomed_owner_keeps_its_scope" \
                || t_bad "sa4_multihomed_owner_keeps_its_scope: an address the host really has was pruned"
# restore the default resolver for the remaining sections
getent() {
  local db="${1:-}" host="${2:-}"
  [[ "$db" == ahostsv4 ]] || return 2
  case "$DNS_MODE" in
    servfail|unreachable) return 2;;
    ambiguous) printf '%s STREAM %s\n%s STREAM %s\n' "$A_IP" "$host" "$B_IP" "$host"; return 0;;
  esac
  case "$host" in
    "$A_HOST") printf '%s STREAM %s\n' "$A_IP" "$host";;
    "$B_HOST") printf '%s STREAM %s\n' "$B_IP" "$host";;
    *) return 2;;
  esac
}

# =====================================================================
# 2f. one permanently unresolvable host must not freeze pruning for all
# =====================================================================
# getent answers "not found" for a deleted record, an IPv6-only host or a typo
# exactly as it does for a resolver outage. Treating any such answer as a global
# "cannot determine" meant a single dead hostname made EVERY scope unprunable
# forever - a functional regression against 0.2.9, which pruned.
printf '\n--- 2f. NXDOMAIN host alongside a genuine orphan ---\n'
reset_state
DEAD_HOST=dead.example
INSTANCES="$A_HOST $DEAD_HOST"
getent() {
  [[ "${1:-}" == ahostsv4 ]] || return 2
  case "${2:-}" in
    "$A_HOST") printf '%s STREAM %s\n' "$A_IP" "$2";;
    *) return 2;;
  esac
}
dpi_prune_orphan_state >/dev/null 2>&1
has "$B_IP" && t_bad "sa4_nxdomain_host_does_not_freeze_pruning: the genuine orphan survived" \
            || t_ok  "sa4_nxdomain_host_does_not_freeze_pruning"
has "$A_IP" && t_ok  "sa4_nxdomain_case_keeps_owned_scope" \
            || t_bad "sa4_nxdomain_case_keeps_owned_scope"

printf '\n--- 2g. the scope OWN host being unresolvable still protects it ---\n'
# Propagation delay on the host that asked for the scope: its mapping cannot be
# checked right now, so its intent must survive even though the resolver works.
reset_state
INSTANCES="$A_HOST $B_HOST"
getent() {
  [[ "${1:-}" == ahostsv4 ]] || return 2
  case "${2:-}" in
    "$A_HOST") printf '%s STREAM %s\n' "$A_IP" "$2";;
    *) return 2;;
  esac
}
dpi_prune_orphan_state >/dev/null 2>&1
has "$B_IP" && t_ok  "sa4_recording_host_unresolvable_keeps_its_scope" \
            || t_bad "sa4_recording_host_unresolvable_keeps_its_scope: a temporary DNS gap deleted the owner scope"
getent() {
  local db="${1:-}" host="${2:-}"
  [[ "$db" == ahostsv4 ]] || return 2
  case "$DNS_MODE" in
    servfail|unreachable) return 2;;
    ambiguous) printf '%s STREAM %s\n%s STREAM %s\n' "$A_IP" "$host" "$B_IP" "$host"; return 0;;
  esac
  case "$host" in
    "$A_HOST") printf '%s STREAM %s\n' "$A_IP" "$host";;
    "$B_HOST") printf '%s STREAM %s\n' "$B_IP" "$host";;
    *) return 2;;
  esac
}

# =====================================================================
# 3. the authoritative delete path removes exactly the right scope
# =====================================================================
printf '\n--- 3. dpi_remove_host_state_if_orphaned ---\n'
reset_state
INSTANCES="$B_HOST"                     # alpha.example has just been deleted
dpi_remove_host_state_if_orphaned "$A_IP" >/dev/null 2>&1
has "$A_IP" && t_bad sa4_delete_removes_target_scope || t_ok sa4_delete_removes_target_scope
has "$B_IP" && t_ok  sa4_delete_keeps_other_scope    || t_bad sa4_delete_keeps_other_scope

printf '\n--- 3b. a shared address still owned by a live host is not removed ---\n'
reset_state
# beta.example is deleted, but it shared A_IP with the still-configured alpha.
rm -f "$DPI_STATE_DIR/$B_IP.env"
INSTANCES="$A_HOST"
dpi_remove_host_state_if_orphaned "$A_IP" >/dev/null 2>&1
has "$A_IP" && t_ok sa4_delete_keeps_scope_owned_by_a_live_host \
            || t_bad sa4_delete_keeps_scope_owned_by_a_live_host

printf '\n--- 3c. delete path with a broken resolver must not destroy a live scope ---\n'
reset_state
rm -f "$DPI_STATE_DIR/$B_IP.env"
INSTANCES="$A_HOST"; DNS_MODE=servfail
dpi_remove_host_state_if_orphaned "$A_IP" >/dev/null 2>&1
has "$A_IP" && t_ok sa4_delete_broken_resolver_keeps_live_scope \
            || t_bad sa4_delete_broken_resolver_keeps_live_scope: a transient DNS failure deleted a scope a configured host still owns

# =====================================================================
# 4. an undecidable prune is reported, not silently skipped
# =====================================================================
printf '\n--- 4. diagnostics ---\n'
reset_state
DNS_MODE=servfail
dpi_prune_orphan_state >/dev/null 2>&1
if grep -Fq 'prune' "$CURRENT_LOG" 2>/dev/null; then
  t_ok sa4_undecidable_prune_is_recorded
else
  t_bad sa4_undecidable_prune_is_recorded: nothing in the manager transcript explains why state was kept
fi

printf '\nsa4-dns-prune-safety: %s pass, %s fail\n' "$pass" "$fail"
(( fail == 0 ))
