#!/usr/bin/env bash
# Real nft JSON round-trip in a disposable network namespace only.
# No systemd/nfqws processes are started; no host ruleset is modified.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
# Disposable lab host only (tests/LAB.md); checked again in the inner phase.
source "$ROOT/tests/lib/lab-gate.sh"
lab_gate_or_exit stagea1-real-nft
if [[ "${2:-}" != --inside ]]; then
  NFT="$(command -v nft || true)"
  if [[ -z "$NFT" ]]; then printf 'NOT_EXECUTED real-nft: nft executable unavailable\n'; exit 77; fi
  if ! timeout 5 unshare --net true; then
    printf 'NOT_EXECUTED real-nft: disposable network namespace unavailable\n'; exit 77
  fi
  exec timeout 90 unshare --net bash "$0" "$MGR" --inside
fi
TMP="$(mktemp -d /tmp/twebproxy-a1-real-nft.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
export TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1
source "$MGR"
trap - ERR
DPI_DIR="$TMP/dpi"; DPI_STATE_DIR="$DPI_DIR/scopes"; DPI_NFT_FILE="$DPI_DIR/firewall.nft"
DPI_NFT_BIN="$(command -v nft)"
printf 'nft-version: '; "$DPI_NFT_BIN" --version
for mode in window1152 mss88 nfqws window1152_nfqws mss88_nfqws; do
  rm -rf -- "$DPI_STATE_DIR"; install -d -m 0700 "$DPI_STATE_DIR"
  dpi_write_scope_state "$DPI_STATE_DIR" 198.51.100.10 "$mode" alpha.example
  dpi_render_rules "$DPI_STATE_DIR" "$DPI_NFT_FILE"
  "$DPI_NFT_BIN" -c -f "$DPI_NFT_FILE"
  dpi_apply_rules_file "$DPI_NFT_FILE"
  # Actual kernel listing, parsed by the production semantic verifier.
  "$DPI_NFT_BIN" -j -n list table ip "$DPI_NFT_TABLE"
  dpi_verify_runtime 0
  printf 'PASS real-nft-%s\n' "$mode"
done
dpi_write_scope_state "$DPI_STATE_DIR" 198.51.100.20 mss88 beta.example
dpi_render_rules "$DPI_STATE_DIR" "$DPI_NFT_FILE"
dpi_apply_rules_file "$DPI_NFT_FILE"
dpi_verify_runtime 0
printf 'PASS real-nft-multiple-scopes\n'
# Leave the real table in mss88, but demand a different value in canonical state.
dpi_write_scope_state "$DPI_STATE_DIR" 198.51.100.20 window1152 beta.example
if dpi_verify_runtime 0; then printf 'FAIL real-nft-wrong-mode\n'; exit 1; fi
printf 'PASS real-nft-wrong-mode-rejected\n'
dpi_apply_rules_file /dev/null
printf 'PASS real-nft-stock-removes-exact-owned-table\n'
