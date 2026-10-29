#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$ROOT/tests"

run_case() {
  local label="$1" script="$2"
  printf 'RUN Stage4-%s %s\n' "$label" "$(basename "$script")"
  bash "$script"
  printf 'Stage4-%s: PASS\n' "$label"
}

bash "$TESTS/stage4-update-backup-fixture.sh"
run_case Q-stage1-read-only-core "$TESTS/read-only-core-fixture.sh"
run_case R-stage2-tui-presentation "$TESTS/tui-presentation-fixture.sh"
run_case S-stage3-cleanup-baseline "$TESTS/cleanup-baseline-fixture.sh"

printf 'RUN Stage4-T-static-and-certificate\n'
bash "$TESTS/static-smoke.sh"
bash "$TESTS/certificate-smoke.sh"
printf 'Stage4-T-static-and-certificate: PASS\n'

bash "$TESTS/stage4-corrections-fixture.sh"

printf 'stage4-mandatory-suite: PASS (A-V all executed)\n'
