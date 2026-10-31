#!/usr/bin/env bash
# 0=all mandatory checks executed/PASS; 1=FAIL; 77=INCOMPLETE.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TESTS="$ROOT/tests/stagea"
source "$ROOT/tests/lib/stage-a-results.sh"
NAMES=(
  "A1 verify-runtime SIGPIPE/pipefail:sa1-verify-runtime-sigpipe.sh:600"
  "A2 STOCK no-state orphan reconcile:sa2-stock-orphan-reconcile.sh:900"
  "A3 DPI state publication:sa3-state-publication.sh:600"
  "A4 DNS prune safety:sa4-dns-prune-safety.sh:600"
  "A5 concurrent DPI mutation:sa5-concurrent-mutation.sh:600"
  "A6 release metadata single source:sa6-release-metadata.sh:300"
  "A1.1 correction regression:sa1-correction-fixture.sh:900"
  "A1.1 result accounting:sa1-runner-status-fixture.sh:60"
  "A1.1 real nft JSON/runtime:sa1-real-nft-validation.sh:120"
)
for entry in "${NAMES[@]}"; do
  label="${entry%%:*}"; rest="${entry#*:}"; script="${rest%%:*}"; limit="${rest##*:}"
  printf '\n===== %s =====\n' "$label"
  stage_a_run_case "$label" "$TESTS/$script" "$limit" "$MGR"
done
rc=0; stage_a_result || rc=$?
case "$rc" in
  0) printf 'stage-a-suite: PASS (all mandatory checks executed)\n';;
  77) printf 'stage-a-suite: INCOMPLETE (mandatory checks NOT_EXECUTED)\n';;
  *) printf 'stage-a-suite: FAIL\n';;
esac
exit "$rc"
