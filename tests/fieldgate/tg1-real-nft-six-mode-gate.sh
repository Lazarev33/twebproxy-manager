#!/usr/bin/env bash
# TG-1 / TWP-001 regression.
#
# Closes the audited gap in which tests/stage-x-dpi-fixture.sh replaced nft's
# validation gate with `grep -q '^table ip twebproxy_dpi {'`, so three DPI modes
# that real nftables rejects were reported as a green six-mode matrix.
#
# This regression renders every mode through the PRODUCTION functions
# (dpi_write_scope_state -> dpi_render_rules) and submits each candidate to the
# host's REAL nft, exactly as production line "nft -c -f" does. No mock, no
# grep, no regex substitute.
#
# Usage: tg1-real-nft-six-mode-gate.sh [path/to/twebproxy-manager.sh]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
SCOPE_IP=203.0.113.10
MODES=(stock window1152 mss88 nfqws window1152_nfqws mss88_nfqws)

pass=0; fail=0; neel=0
t_ok()   { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
t_bad()  { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
t_skip() { printf 'NOT_EXECUTED_ENVIRONMENT_LIMITATION %s\n' "$*"; neel=$((neel+1)); }

NFT="$(command -v nft || true)"
if [[ -z "$NFT" ]]; then
  # This gate exists precisely because a mocked validator hid the defect. Without
  # a real nft there is nothing to gate, so fail rather than report a green run
  # in which zero assertions executed.
  t_bad "tg1_requires_real_nft: no nft binary on this host; this gate cannot be satisfied by a mock"
  printf 'tg1: pass=%s fail=%s neel=%s\n' "$pass" "$fail" "$neel"; exit 1
fi

TMP="$(mktemp -d /tmp/tg1-real-nft.XXXXXX)"; trap 'rm -rf -- "$TMP"' EXIT

# Classify a real nft verdict on a candidate file.
#   accepted            - nft took the ruleset
#   eval-error          - nft rejected the ruleset (the TWP-001 defect class)
#   queue-unsupported   - kernel lacks the nft_queue expression; evaluation passed
classify() {
  local out rc
  out="$("$NFT" -c -f "$1" 2>&1)"; rc=$?
  if (( rc == 0 )); then printf 'accepted'; return; fi
  if grep -q 'Could not process rule: No such file or directory' <<<"$out"; then
    printf 'queue-unsupported'; return
  fi
  printf 'eval-error\t%s' "$(sed -n '1p' <<<"$out" | sed 's/.*Error: //')"
}

# Environment control: does this kernel support the queue expression at all?
# Establishes whether a queue-unsupported verdict is the host's fault or ours.
printf 'table ip tg1_probe {\n  chain c {\n    type filter hook output priority mangle; policy accept;\n    counter queue num 1 bypass\n  }\n}\n' > "$TMP/probe.nft"
QUEUE_SUPPORTED=1
[[ "$(classify "$TMP/probe.nft")" == queue-unsupported ]] && QUEUE_SUPPORTED=0
printf '# host nft: %s | queue expression supported: %s\n' "$("$NFT" --version)" \
  "$([[ $QUEUE_SUPPORTED == 1 ]] && echo yes || echo NO)"

# shellcheck source=/dev/null
source "$MGR"
# The manager sets `set -Eeuo pipefail` when sourced. This harness checks return
# codes explicitly, so -e must not abort it on a deliberate non-zero result.
trap - ERR
set +e
DPI_STATE_FORMAT="$DPI_STATE_FORMAT"   # keep the production constant explicit

render() { # $1=mode -> writes $TMP/<mode>.nft via production code only
  local mode="$1" dir="$TMP/state-$mode"
  rm -rf -- "$dir"; install -d -m 0700 "$dir"
  if [[ "$mode" != stock ]]; then
    dpi_write_scope_state "$dir" "$SCOPE_IP" "$mode" alpha.example >/dev/null 2>&1 || return 1
  fi
  dpi_render_rules "$dir" "$TMP/$mode.nft" >/dev/null 2>&1
}

for mode in "${MODES[@]}"; do
  if ! render "$mode"; then t_bad "tg1_${mode}_render: production render failed"; continue; fi

  if [[ "$mode" == stock ]]; then
    # STOCK must produce no ruleset at all (the zero-artifact invariant).
    if [[ -s "$TMP/$mode.nft" ]]; then t_bad "tg1_stock_renders_no_rules: candidate is non-empty"
    else t_ok "tg1_stock_renders_no_rules"; fi
    continue
  fi

  verdict="$(classify "$TMP/$mode.nft")"
  case "${verdict%%$'\t'*}" in
    accepted)
      t_ok "tg1_${mode}_real_nft_accepts" ;;
    queue-unsupported)
      if (( QUEUE_SUPPORTED )); then
        t_bad "tg1_${mode}_real_nft_accepts: queue rejected although this host supports the queue expression"
      else
        # Evaluation succeeded; only the kernel commit stage is unavailable here.
        t_ok "tg1_${mode}_passes_nft_evaluation"
        t_skip "tg1_${mode}_real_nft_accepts: kernel lacks the nft_queue expression (control rule fails identically)"
      fi ;;
    eval-error)
      t_bad "tg1_${mode}_real_nft_accepts: ${verdict#*$'\t'}" ;;
  esac
done

# The specific audited defect must not reappear in any candidate.
for mode in "${MODES[@]}"; do
  [[ -s "$TMP/$mode.nft" ]] || continue
  raw="$("$NFT" -c -f "$TMP/$mode.nft" 2>&1 || true)"
  if printf '%s' "$raw" | grep -q 'Statement after terminal statement'; then
    t_bad "tg1_${mode}_no_statement_after_terminal"
  else
    t_ok "tg1_${mode}_no_statement_after_terminal"
  fi
done

# Ownership/semantic invariants that must survive the fix.
for mode in nfqws window1152_nfqws mss88_nfqws; do
  grep -q "queue num $DPI_NFQUEUE_NUM bypass" "$TMP/$mode.nft" \
    && t_ok "tg1_${mode}_keeps_queue_num_and_bypass" || t_bad "tg1_${mode}_keeps_queue_num_and_bypass"
  grep -q 'counter' "$TMP/$mode.nft" \
    && t_ok "tg1_${mode}_keeps_counter" || t_bad "tg1_${mode}_keeps_counter"
  grep -q "comment \"twebproxy:$SCOPE_IP:" "$TMP/$mode.nft" \
    && t_ok "tg1_${mode}_keeps_ownership_comment" || t_bad "tg1_${mode}_keeps_ownership_comment"
done
w="$(grep -n 'window set' "$TMP/window1152_nfqws.nft" | cut -d: -f1)"
q="$(grep -n 'queue num' "$TMP/window1152_nfqws.nft" | cut -d: -f1)"
[[ -n "$w" && -n "$q" && "$w" -lt "$q" ]] \
  && t_ok "tg1_combined_window_precedes_queue" || t_bad "tg1_combined_window_precedes_queue"

printf 'tg1: pass=%s fail=%s neel=%s\n' "$pass" "$fail" "$neel"
(( fail == 0 ))
