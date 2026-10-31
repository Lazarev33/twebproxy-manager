#!/usr/bin/env bash
# 0=all mandatory checks executed/PASS; 1=FAIL; 77=INCOMPLETE.
# Stage H: guided setup, menus, Anti-DPI explanations, client help, status hints
# and RU/EN text through the real prompts (tests/stageh/ux-harness.sh, model
# host boundary), plus the static heredoc guard. Root required for the shared
# harness; nothing outside temporary sandboxes is touched.
# Scope: h-scope-invariants.sh <v0.2.21 tree>.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
source "$ROOT/tests/lib/stage-a-results.sh"
stage_a_run_case "H UX: setup, menus, Anti-DPI text, client help, status hints (MODEL)" "$ROOT/tests/stageh/ux-fixture.sh" 1200 "$MGR"
stage_a_run_case "H static: no backtick in an unquoted heredoc" "$ROOT/tests/stageh/heredoc-guard.sh" 60 "$MGR"
rc=0; stage_a_result || rc=$?
case "$rc" in
  0) echo 'stage-h-suite: PASS (all mandatory checks executed)';;
  77) echo 'stage-h-suite: INCOMPLETE (mandatory checks NOT_EXECUTED)';;
  *) echo 'stage-h-suite: FAIL';;
esac
exit "$rc"
