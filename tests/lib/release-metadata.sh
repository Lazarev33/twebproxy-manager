#!/usr/bin/env bash
# Single authoritative source for release identity inside the test tree.
#
# Before Stage A, four separate gate tests each hard-coded the release number.
# A semver bump therefore broke the mandatory suites until every literal was
# hunted down by hand - and on the shipped 0.2.9 tree three mandatory suites
# were already red for exactly that reason.
#
# The machine semver comes from the VERSION file and nothing else; the embedded
# manager constants and the display label are asserted to AGREE with it. A bump
# then needs no test edits at all.
#
# Usage:
#   source tests/lib/release-metadata.sh
#   release_metadata_load "$REPO_ROOT" || fail
#   release_metadata_consistent        || fail
# Sets: RELEASE_MACHINE_VERSION, RELEASE_EMBEDDED_VERSION, RELEASE_LABEL

release_metadata_load() {
  local root="${1:?release_metadata_load: repository root required}"
  local mgr="$root/twebproxy-manager.sh"
  [[ -f "$root/VERSION" && -f "$mgr" ]] || return 1
  RELEASE_MACHINE_VERSION="$(tr -d '[:space:]' < "$root/VERSION")"
  RELEASE_EMBEDDED_VERSION="$(sed -n 's/^MANAGER_VERSION="\(.*\)"$/\1/p' "$mgr" | head -n1)"
  RELEASE_LABEL="$(sed -n 's/^MANAGER_RELEASE_VERSION="\(.*\)"$/\1/p' "$mgr" | head -n1)"
  [[ -n "$RELEASE_MACHINE_VERSION" && -n "$RELEASE_EMBEDDED_VERSION" && -n "$RELEASE_LABEL" ]]
}

release_metadata_consistent() {
  # Stage 4 requires a strict semver machine version; the beta label is a
  # separate display string that must still be derived from it.
  [[ "$RELEASE_MACHINE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$RELEASE_EMBEDDED_VERSION" == "$RELEASE_MACHINE_VERSION" ]] || return 1
  [[ "$RELEASE_LABEL" == "$RELEASE_MACHINE_VERSION" \
     || "$RELEASE_LABEL" == "$RELEASE_MACHINE_VERSION"-* ]] || return 1
}
