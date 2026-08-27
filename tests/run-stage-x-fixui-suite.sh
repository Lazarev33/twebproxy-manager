#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$ROOT/tests"

bash -n "$ROOT/twebproxy-manager.sh"
printf 'FixUI-A-bash-syntax: PASS\n'

# Accepted runtime/update regression, including Stage 4 A-V, Stage 1, Stage 2,
# Stage 3 non-reintroduction, static smoke and certificate smoke.
bash "$TESTS/run-stage4-mandatory-suite.sh"
printf 'FixUI-B-accepted-regression-A-V: PASS\n'

for locale in C C.UTF-8; do
  LC_ALL="$locale" bash "$TESTS/localization-static-audit.sh"
  printf 'FixUI-C-localization-static-audit-%s: PASS\n' "$locale"

  LC_ALL="$locale" bash "$TESTS/localization-flow-fixture.sh"
  printf 'FixUI-D-localization-real-flows-%s: PASS\n' "$locale"

  LC_ALL="$locale" bash "$TESTS/stage-x-fixui-fixture.sh"
  printf 'FixUI-E-language-menu-dashboard-status-statistics-%s: PASS\n' "$locale"
done

printf 'stage-x-fixui-suite: PASS (all mandatory tests executed; none skipped)\n'
