#!/usr/bin/env bash
# Stage A / A1 regression: dpi_verify_runtime must not turn a SUCCESSFUL
# verification into a failure because of SIGPIPE under `set -o pipefail`.
#
# Field evidence (real VPS, window1152 confirmed working - live rule present,
# counter incrementing, outgoing SYN,ACK carrying win 1152):
#     PIPESTATUS=141 0
# i.e. grep found the address and exited immediately, the still-writing `nft`
# producer got SIGPIPE (128+13=141), and the manager's global `pipefail` turned
# that into a verification failure and a false rollback.
#
# The mechanism is reproduced here with a real external producer, not simulated:
# the nft mock streams a large table listing (MOCK_NFT_PAD_LINES), which is what
# a busy ruleset looks like, so `... | grep -Fq` closes the pipe early every time.
#
# Usage: sa1-verify-runtime-sigpipe.sh [path/to/twebproxy-manager.sh]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
pass=0; fail=0
t_ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
t_bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }

TMP="$(mktemp -d /tmp/sa1-sigpipe.XXXXXX)"; trap 'rm -rf -- "$TMP"' EXIT

# A listing big enough that grep -q always closes the pipe while nft is writing.
export MOCK_NFT_PAD_LINES=200000
# shellcheck source=/dev/null
source "$ROOT/tests/lib/dpi-harness.sh"
dpi_harness_env "$TMP"

# shellcheck source=/dev/null
source "$MGR"
trap - ERR
# NOTE: pipefail stays ON. It is the production setting and it is the whole
# point of this regression, so it is never relaxed here. Only errexit is
# dropped, because this harness inspects return codes itself.
set +e
set -o pipefail
[[ -o pipefail ]] && t_ok sa1_pipefail_is_active_in_this_harness \
                  || t_bad sa1_pipefail_is_active_in_this_harness

dpi_harness_bind "$ROOT" "$TMP"
SCOPE_IP=198.51.100.10
dpi_local_ipv4_addresses() { printf '%s\n' "$SCOPE_IP"; }

install -d -o root -g root -m 0700 "$DPI_DIR" "$DPI_STATE_DIR"
dpi_harness_seed_scope "$SCOPE_IP" window1152 alpha.example \
  && t_ok sa1_scope_state_seeded || t_bad sa1_scope_state_seeded
dpi_render_rules "$DPI_STATE_DIR" "$DPI_NFT_FILE" \
  && t_ok sa1_rules_rendered || t_bad sa1_rules_rendered
"$DPI_NFT_BIN" -f "$DPI_NFT_FILE" >/dev/null \
  && t_ok sa1_rules_live || t_bad sa1_rules_live

# The live table really does contain the configured scope: verification is
# semantically TRUE, so any failure below is a false negative and nothing else.
# Read once into memory - deliberately NOT through a pipe, so this check
# cannot itself fall into the very trap it is establishing a baseline for.
live_now="$("$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE" 2>/dev/null)"
if [[ "$live_now" == *"$SCOPE_IP"* ]]; then
  t_ok sa1_precondition_scope_is_really_in_the_live_table
else
  t_bad sa1_precondition_scope_is_really_in_the_live_table
fi

# --- 1. the defect: an early-exit reader kills a still-writing producer -------
sig=0
for i in $(seq 1 5); do
  "$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE" 2>/dev/null | grep -Fq "$SCOPE_IP"
  rc=$?
  (( rc != 0 )) && sig=$((sig+1))
done
if (( sig > 0 )); then
  t_ok "sa1_producer_pipeline_is_genuinely_sigpipe_prone ($sig/5 false failures, rc=$rc)"
else
  t_bad "sa1_producer_pipeline_is_genuinely_sigpipe_prone: the harness could not create the window; the A1 result below would be meaningless"
fi

# --- 2. the contract: repeated verification must be stable -------------------
runs=30
bad=0; first_rc=""
for i in $(seq 1 "$runs"); do
  dpi_verify_runtime 0
  rc=$?
  if (( rc != 0 )); then bad=$((bad+1)); [[ -n "$first_rc" ]] || first_rc="$rc"; fi
done
if (( bad == 0 )); then
  t_ok "sa1_verify_runtime_stable_under_pipefail ($runs/$runs succeeded)"
else
  t_bad "sa1_verify_runtime_stable_under_pipefail: $bad/$runs false failures (first rc=$first_rc) while the scope IS in the live table"
fi

# --- 3. verification must still be able to FAIL for real reasons -------------
# Removing the scope from the live table must be detected. A verifier that was
# "fixed" by ignoring its own result would pass test 2 and fail here.
saved_live="$TMP/live.saved"
cp "$MOCK_NFT_LIVE" "$saved_live"
printf 'table ip twebproxy_dpi {\n  chain out {\n    ip saddr 203.0.113.99 counter\n  }\n}\n' > "$MOCK_NFT_LIVE"
dpi_verify_runtime 0; rc=$?
(( rc != 0 )) && t_ok "sa1_verify_runtime_still_detects_a_missing_scope (rc=$rc)" \
              || t_bad "sa1_verify_runtime_still_detects_a_missing_scope: returned 0"
cp "$saved_live" "$MOCK_NFT_LIVE"

# An absent table must still fail.
rm -f "$MOCK_NFT_LIVE"
dpi_verify_runtime 0; rc=$?
(( rc != 0 )) && t_ok "sa1_verify_runtime_still_detects_an_absent_table (rc=$rc)" \
              || t_bad "sa1_verify_runtime_still_detects_an_absent_table: returned 0"
cp "$saved_live" "$MOCK_NFT_LIVE"

# An empty rules file must still fail.
: > "$DPI_NFT_FILE"
dpi_verify_runtime 0; rc=$?
(( rc != 0 )) && t_ok "sa1_verify_runtime_still_detects_empty_rules (rc=$rc)" \
              || t_bad "sa1_verify_runtime_still_detects_empty_rules: returned 0"
dpi_render_rules "$DPI_STATE_DIR" "$DPI_NFT_FILE"

# --- 4. two scopes: both must be matched in one pass -------------------------
dpi_harness_seed_scope 198.51.100.20 mss88 beta.example
dpi_render_rules "$DPI_STATE_DIR" "$DPI_NFT_FILE" && "$DPI_NFT_BIN" -f "$DPI_NFT_FILE" >/dev/null
bad=0
for i in $(seq 1 10); do dpi_verify_runtime 0 || bad=$((bad+1)); done
(( bad == 0 )) && t_ok "sa1_verify_runtime_stable_with_multiple_scopes (10/10)" \
               || t_bad "sa1_verify_runtime_stable_with_multiple_scopes: $bad/10 false failures"
# ... and a scope that is genuinely absent from the table must still fail.
dpi_harness_seed_scope 198.51.100.30 window1152 gamma.example
dpi_verify_runtime 0; rc=$?
(( rc != 0 )) && t_ok "sa1_verify_runtime_detects_one_missing_scope_among_many (rc=$rc)" \
              || t_bad "sa1_verify_runtime_detects_one_missing_scope_among_many: returned 0"

printf '\nsa1-verify-runtime-sigpipe: %s pass, %s fail\n' "$pass" "$fail"
(( fail == 0 ))
