#!/usr/bin/env bash
# Stage A / A5: is concurrent DPI mutation actually racy?
#
# Stage 4 has its own update lock; that says nothing about DPI. Every DPI
# mutation is a read-modify-write over shared resources:
#     $DPI_STATE_DIR, the generated $DPI_NFT_FILE, the live twebproxy_dpi table,
#     the DPI systemd units and the nfqws runtime artifacts
# dpi_transaction_set copies the CURRENT state into a candidate directory, adds
# one scope, and then publishes that candidate as the WHOLE authoritative state.
# Two such operations that overlap would each publish a candidate built from a
# state the other has already moved on from - a classic lost update.
#
# This runs two REAL processes against one shared sandbox. The interleaving is
# made deterministic by gating the first process between its read and its
# publish; the read, the publish and everything else stay production code, and
# the gate is a test-side wrapper, not a production seam.
#
#   t0  A acquires (whatever serialisation exists), reads state, reaches the gate
#   t1  B runs a complete `dpi set` for a DIFFERENT scope
#   t2  A publishes the candidate it built at t0
#   ->  unserialised: B's scope is gone. serialised: B waits, then both survive.
#
# Usage: sa5-concurrent-mutation.sh [path/to/twebproxy-manager.sh]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
pass=0; fail=0
t_ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
t_bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }

TMP="$(mktemp -d /tmp/sa5-concurrent.XXXXXX)"; trap 'rm -rf -- "$TMP"' EXIT
export SA5_TMP="$TMP"

# shellcheck source=/dev/null
source "$ROOT/tests/lib/dpi-harness.sh"
dpi_harness_env "$TMP"

A_IP=198.51.100.10; B_IP=198.51.100.20
A_HOST=alpha.example; B_HOST=beta.example

# --- the driver: one real process performing one real DPI mutation -----------
cat > "$TMP/driver.sh" <<'DRV'
#!/usr/bin/env bash
# usage: driver.sh <gated|plain> <ip> <mode> <host>
set -uo pipefail
ROLE="$1"; IP="$2"; MODE="$3"; HOST="$4"
ROOT="${SA5_ROOT:?}"; MGR="${SA5_MGR:?}"; TMP="${SA5_TMP:?}"
# shellcheck source=/dev/null
source "$ROOT/tests/lib/dpi-harness.sh"
# shellcheck source=/dev/null
source "$MGR"
trap - ERR
set +e
dpi_harness_bind "$ROOT" "$TMP"
dpi_local_ipv4_addresses() { printf '%s\n' 198.51.100.10 198.51.100.20; }

if [[ "$ROLE" == gated ]]; then
  # Wrap a function the transaction calls AFTER it has read the current state
  # and BEFORE it publishes its candidate. Nothing about the read or the
  # publish is altered; only the scheduling between them is made deterministic.
  _sa5_render="$(declare -f dpi_render_rules)"
  eval "${_sa5_render/dpi_render_rules/_sa5_real_render_rules}"
  dpi_render_rules() {
    if [[ ! -e "$TMP/gate.done" ]]; then
      : > "$TMP/gate.reached"
      local waited=0
      while [[ ! -e "$TMP/peer.done" ]] && (( waited < 80 )); do sleep 0.1; waited=$((waited+1)); done
      : > "$TMP/gate.done"
    fi
    _sa5_real_render_rules "$@"
  }
fi

dpi_transaction_set "$IP" "$MODE" "$HOST" >"$TMP/$ROLE.out" 2>&1
printf '%s\n' "$?" > "$TMP/$ROLE.rc"
DRV
chmod 0755 "$TMP/driver.sh"
export SA5_ROOT="$ROOT" SA5_MGR="$MGR"

# Bind in this shell too, purely to read the resulting state.
# shellcheck source=/dev/null
source "$MGR"; trap - ERR; set +e
dpi_harness_bind "$ROOT" "$TMP"

reset_world() {
  rm -rf "$DPI_DIR" "$SYSTEMD_DIR" "$LIBEXEC_DIR" "$SYSTEMCTL_ACTIVE_DIR" "$SYSTEMCTL_ENABLED_DIR"
  mkdir -p "$SYSTEMD_DIR" "$LIBEXEC_DIR" "$SYSTEMCTL_ACTIVE_DIR" "$SYSTEMCTL_ENABLED_DIR"
  rm -f "$MOCK_NFT_LIVE" "$TMP"/gate.* "$TMP"/peer.* "$TMP"/*.rc "$TMP"/*.out
  rm -f "$DPI_LOCK_FILE" 2>/dev/null
}
has() { [[ -f "$DPI_STATE_DIR/$1.env" ]]; }
live_has() { local l; l="$("$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE" 2>/dev/null)"; [[ "$l" == *"$1"* ]]; }

# =====================================================================
# 1. distinct scopes, overlapping transactions
# =====================================================================
# The lock must live inside the disposable sandbox. DPI_LOCK_FILE is expanded
# from BASE_DIR when the manager is sourced, i.e. before the harness rebinds it,
# so without an explicit rebind these tests would create and contend on the real
# /etc/twebproxy lock of the machine running them - and would silently pass on a
# host where /etc is not writable.
if [[ "$DPI_LOCK_FILE" == "$TMP"/* ]]; then
  t_ok "sa5_mutation_lock_is_inside_the_sandbox"
else
  t_bad "sa5_mutation_lock_is_inside_the_sandbox: $DPI_LOCK_FILE"
fi

printf '\n--- 1. two processes, two distinct scopes ---\n'
reset_world
"$TMP/driver.sh" gated "$A_IP" window1152 "$A_HOST" & a_pid=$!
waited=0
while [[ ! -e "$TMP/gate.reached" ]] && (( waited < 100 )); do sleep 0.1; waited=$((waited+1)); done
if [[ -e "$TMP/gate.reached" ]]; then
  t_ok "sa5_gate_reached (process A is between its read and its publish)"
else
  t_bad "sa5_gate_reached: the interleaving could not be established; the verdict below would be meaningless"
fi
"$TMP/driver.sh" plain "$B_IP" mss88 "$B_HOST"
b_rc="$(cat "$TMP/plain.rc" 2>/dev/null || echo 99)"
: > "$TMP/peer.done"
wait "$a_pid"
a_rc="$(cat "$TMP/gated.rc" 2>/dev/null || echo 99)"
printf '    process A rc=%s   process B rc=%s\n' "$a_rc" "$b_rc"

# The invariant is NOT "both scopes exist": a correctly serialised manager may
# legitimately refuse the second operation. It is that a transaction which
# REPORTED SUCCESS must have actually taken effect. Silent loss is the defect.
lost=""
(( a_rc == 0 )) && ! has "$A_IP" && lost="$lost A"
(( b_rc == 0 )) && ! has "$B_IP" && lost="$lost B"
if [[ -z "$lost" ]]; then
  t_ok "sa5_no_lost_update_distinct_scopes (every transaction that reported success took effect)"
else
  t_bad "sa5_no_lost_update_distinct_scopes: transaction(s)$lost returned 0 but their scope is gone"
fi
# Whatever survived in state must also be live: state and runtime may not split.
split=""
for ip in "$A_IP" "$B_IP"; do
  has "$ip" && ! live_has "$ip" && split="$split $ip"
done
if [[ -z "$split" ]]; then t_ok "sa5_state_and_live_table_agree"
else t_bad "sa5_state_and_live_table_agree: committed but not live:$split"; fi

# =====================================================================
# 2. same scope, overlapping transactions
# =====================================================================
printf '\n--- 2. two processes, the SAME scope ---\n'
reset_world
"$TMP/driver.sh" gated "$A_IP" window1152 "$A_HOST" & a_pid=$!
waited=0
while [[ ! -e "$TMP/gate.reached" ]] && (( waited < 100 )); do sleep 0.1; waited=$((waited+1)); done
"$TMP/driver.sh" plain "$A_IP" mss88 "$A_HOST"
: > "$TMP/peer.done"
wait "$a_pid"
if has "$A_IP"; then
  mode="$(sed -n 's/^MODE=//p' "$DPI_STATE_DIR/$A_IP.env")"
  if live_has "$A_IP"; then t_ok "sa5_same_scope_state_and_runtime_consistent (final MODE=$mode)"
  else t_bad "sa5_same_scope_state_and_runtime_consistent: MODE=$mode committed but no live rule"; fi
else
  t_bad "sa5_same_scope_state_and_runtime_consistent: the scope was lost entirely"
fi

# =====================================================================
# 3. set + disable, overlapping
# =====================================================================
printf '\n--- 3. set overlapping with disable of another scope ---\n'
reset_world
"$TMP/driver.sh" plain "$B_IP" window1152 "$B_HOST" >/dev/null 2>&1
rm -f "$TMP"/gate.* "$TMP"/peer.* "$TMP"/*.rc
"$TMP/driver.sh" gated "$A_IP" window1152 "$A_HOST" & a_pid=$!
waited=0
while [[ ! -e "$TMP/gate.reached" ]] && (( waited < 100 )); do sleep 0.1; waited=$((waited+1)); done
cat > "$TMP/disable.sh" <<'DIS'
#!/usr/bin/env bash
set -uo pipefail
ROOT="${SA5_ROOT:?}"; MGR="${SA5_MGR:?}"; TMP="${SA5_TMP:?}"
source "$ROOT/tests/lib/dpi-harness.sh"
source "$MGR"; trap - ERR; set +e
dpi_harness_bind "$ROOT" "$TMP"
dpi_transaction_disable_ip "$1" >"$TMP/disable.out" 2>&1
printf '%s\n' "$?" > "$TMP/disable.rc"
DIS
chmod 0755 "$TMP/disable.sh"
"$TMP/disable.sh" "$B_IP"
: > "$TMP/peer.done"
wait "$a_pid"
if has "$A_IP"; then t_ok "sa5_set_survives_concurrent_disable_of_another_scope"
else t_bad "sa5_set_survives_concurrent_disable_of_another_scope: the newly set scope was lost"; fi
d_rc="$(cat "$TMP/disable.rc" 2>/dev/null || echo 99)"
if (( d_rc != 0 )); then
  t_ok "sa5_concurrent_disable_took_effect (disable refused, rc=$d_rc; nothing silently undone)"
elif has "$B_IP"; then
  t_bad "sa5_concurrent_disable_took_effect: disable returned 0 but the scope came back"
else
  t_ok "sa5_concurrent_disable_took_effect"
fi

# =====================================================================
# 4. the lock must not deadlock against itself
# =====================================================================
printf '\n--- 4. re-entrancy and read-only paths ---\n'
if grep -q 'dpi_mutation_lock_acquire' "$MGR"; then
  reset_world
  # A locked entrypoint calling another locked operation must not self-deadlock.
  ( dpi_with_mutation_lock dpi_with_mutation_lock dpi_reconcile_runtime ) >/dev/null 2>&1 &
  n_pid=$!
  waited=0
  while kill -0 "$n_pid" 2>/dev/null && (( waited < 100 )); do sleep 0.1; waited=$((waited+1)); done
  if kill -0 "$n_pid" 2>/dev/null; then
    kill -9 "$n_pid" 2>/dev/null; wait "$n_pid" 2>/dev/null
    t_bad "sa5_nested_lock_does_not_deadlock: still blocked after 10s"
  else
    wait "$n_pid" 2>/dev/null
    t_ok "sa5_nested_lock_does_not_deadlock"
  fi

  # The lock must be released again, so the very next mutation still works.
  "$TMP/driver.sh" plain "$A_IP" window1152 "$A_HOST"
  r="$(cat "$TMP/plain.rc" 2>/dev/null || echo 99)"
  (( r == 0 )) && t_ok "sa5_lock_released_after_use" || t_bad "sa5_lock_released_after_use (rc=$r)"

  # Read-only paths must never be blocked by a held mutation lock.
  cat > "$TMP/reader.sh" <<'RDR'
#!/usr/bin/env bash
set -uo pipefail
ROOT="${SA5_ROOT:?}"; MGR="${SA5_MGR:?}"; TMP="${SA5_TMP:?}"
source "$ROOT/tests/lib/dpi-harness.sh"
source "$MGR"; trap - ERR; set +e
dpi_harness_bind "$ROOT" "$TMP"
dpi_mode_for_host() { printf 'x\ty\n'; }
dpi_list_methods_cmd >/dev/null 2>&1
printf '%s\n' "$?" > "$TMP/reader.rc"
RDR
  chmod 0755 "$TMP/reader.sh"
  (
    exec 8>>"$DPI_LOCK_FILE"
    flock 8
    timeout 8 "$TMP/reader.sh"
  ) >/dev/null 2>&1
  r="$(cat "$TMP/reader.rc" 2>/dev/null || echo 99)"
  (( r == 0 )) && t_ok "sa5_read_only_path_not_blocked_by_the_mutation_lock" \
                || t_bad "sa5_read_only_path_not_blocked_by_the_mutation_lock (rc=$r)"

  # A busy lock must fail fast and clearly, not hang forever.
  reset_world
  start="$(date +%s)"
  (
    exec 8>>"$DPI_LOCK_FILE"
    flock 8
    TWEBPROXY_DPI_LOCK_WAIT=2 timeout 20 "$TMP/driver.sh" plain "$B_IP" mss88 "$B_HOST"
  ) >/dev/null 2>&1
  elapsed=$(( $(date +%s) - start ))
  r="$(cat "$TMP/plain.rc" 2>/dev/null || echo 99)"
  if (( r != 0 && elapsed < 15 )); then
    t_ok "sa5_busy_lock_fails_fast (rc=$r after ${elapsed}s)"
  else
    t_bad "sa5_busy_lock_fails_fast (rc=$r after ${elapsed}s)"
  fi
  has "$B_IP" && t_bad "sa5_busy_lock_changes_nothing" || t_ok "sa5_busy_lock_changes_nothing"
else
  t_ok "sa5_lock_absent_in_this_build (race verdict above stands on its own)"
fi

printf '\nsa5-concurrent-mutation: %s pass, %s fail\n' "$pass" "$fail"
(( fail == 0 ))
