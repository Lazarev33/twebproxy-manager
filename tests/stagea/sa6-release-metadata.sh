#!/usr/bin/env bash
# Stage A / A6 regression: release identity must come from ONE authoritative
# source, and no gate test may hard-code a release number again.
#
# On the shipped 0.2.9 tree three mandatory suites (Stage X-DPI, Stage 4,
# Stage X-FixUI) could not even run to completion, because four gate tests still
# asserted 0.2.8 literals - one of them by pinning the SHA-256 of the VERSION
# file itself. This pins the shape that makes the next bump free.
#
# Usage: sa6-release-metadata.sh [path/to/twebproxy-manager.sh]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
MGR_ROOT="$(cd "$(dirname "$MGR")" && pwd -P)"
pass=0; fail=0
t_ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
t_bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }

# shellcheck source=/dev/null
source "$ROOT/tests/lib/release-metadata.sh"
release_metadata_load "$MGR_ROOT" && t_ok sa6_metadata_readable || t_bad sa6_metadata_readable
release_metadata_consistent \
  && t_ok "sa6_metadata_consistent (VERSION=$RELEASE_MACHINE_VERSION label=$RELEASE_LABEL)" \
  || t_bad "sa6_metadata_consistent: VERSION=$RELEASE_MACHINE_VERSION embedded=$RELEASE_EMBEDDED_VERSION label=$RELEASE_LABEL"

# The manager's own header comment must not drift from the label either.
if grep -q "^# TWebProxy Manager v$RELEASE_LABEL$" "$MGR"; then
  t_ok sa6_manager_header_matches_label
else
  t_bad "sa6_manager_header_matches_label: header does not say v$RELEASE_LABEL"
fi

# Stage 4's own parser must accept the machine version.
# shellcheck source=/dev/null
( source "$MGR" >/dev/null 2>&1; trap - ERR; valid_manager_version "$RELEASE_MACHINE_VERSION" ) \
  && t_ok sa6_stage4_parser_accepts_machine_version \
  || t_bad sa6_stage4_parser_accepts_machine_version

# No release-gate test may hard-code a release number again. The Stage 4 backup
# fixtures are excluded on purpose: their "0.2.8" strings are synthetic backup
# payloads, not assertions about this release.
GATE_FILES=(
  tests/static-smoke.sh
  tests/cleanup-baseline-fixture.sh
  tests/tui-presentation-fixture.sh
  tests/stage-x-dpi-installed-asset-fixture.sh
)
offenders=""
for f in "${GATE_FILES[@]}"; do
  # Scanned in the tree the manager under test belongs to, so pointing this
  # regression at an older release really inspects that release's gate tests.
  [[ -f "$MGR_ROOT/$f" ]] || continue
  # A release literal in either the bare `0.2.8` or the prefixed `v0.2.8` form,
  # on a line that is not a comment. The trailing class is what keeps IPv4
  # literals out: in 198.51.100.10 the third component is followed by another
  # dot, so a dotted quad never matches a three-component version.
  if grep -vE '^[[:space:]]*#' "$MGR_ROOT/$f" \
     | grep -qE '(^|[^0-9A-Za-z.])v?[0-9]+\.[0-9]+\.[0-9]+([^0-9.]|$)'; then
    offenders="$offenders $f"
  fi
done
if [[ -z "$offenders" ]]; then
  t_ok sa6_no_release_literals_in_gate_tests
else
  t_bad "sa6_no_release_literals_in_gate_tests:$offenders"
fi

# And the authoritative source really is a single file.
n="$(grep -c '^MANAGER_VERSION=' "$MGR")"
[[ "$n" == 1 ]] && t_ok sa6_single_embedded_machine_version || t_bad "sa6_single_embedded_machine_version (got $n)"

printf '\nsa6-release-metadata: %s pass, %s fail\n' "$pass" "$fail"
(( fail == 0 ))
