#!/usr/bin/env bash
# Per-function SHA-256 of the manager self-updater (Stage F documentation and
# scope evidence).
#
# Unlike tests/fieldgate/stage4-function-set-hash.sh (the legacy tool behind the
# original protected hash fd0e123c…), the extraction here skips heredoc bodies:
# the legacy extractor stops at the first "}" line inside a heredoc and so
# covered only the first 30 lines of stage4_render_restore_helper. Text-based,
# independent of the Bash version.
#
# Usage: updater-function-hashes.sh <twebproxy-manager.sh> [function...]
#   default functions: the 28-function Stage 4 set, then the Stage F additions
#   and install_manager_copy; prints "<sha256>  <name>" (or "ABSENT  <name>")
#   and "<sha256>  stage4-protected-function-set-full" over the 28 bodies.
set -Eeuo pipefail
MGR="${1:?usage: updater-function-hashes.sh <twebproxy-manager.sh> [function...]}"; shift

STAGE4=(
  stage4_render_restore_helper stage4_no_symlink_components stage4_safe_root_file
  stage4_install_restore_helper stage4_verify_backup stage4_prune_backups
  stage4_prepare_backup_root stage4_acquire_update_lock stage4_current_manager_preflight
  stage4_create_backup stage4_install_candidate_target stage4_manager_health
  stage4_rollback_exact stage4_backup_tui_summary
  manager_backup_list_cmd manager_restore_backup_cmd
  valid_manager_version version_is_newer
  manager_update_cache_fresh write_manager_update_cache load_manager_update_cache
  fetch_manager_update_info manager_check_update_impl manager_check_update_cmd
  set_global_manager_version manager_update_cmd
  fetch_manager_update_hint_info manager_update_hint
)
STAGEF=(
  stage4_restore_helper_valid stage4_backup_parent_ready stage4_release_update_lock stage4_manager_copies_match
  stage4_update_prepare stage4_update_end stage4_update_abort stage4_update_refuse
  manager_release_tag_from_json manager_latest_release_tag manager_release_download
  manager_release_signature_ok manager_release_manifest_fields manager_candidate_identity_ok
  install_manager_copy
)

extract() { # $1=file $2=function: "name() {" to the closing "}" at column 0, heredocs skipped
  awk -v fn="$2" '
    function heredoc_word(line,   rest, w) {
      if (line ~ /^[ \t]*#/) return ""
      while (match(line, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
        if (substr(line, RSTART > 1 ? RSTART - 1 : 1, 1) == "<" && RSTART > 1) { line = substr(line, RSTART + RLENGTH); continue }
        w = substr(line, RSTART, RLENGTH)
        dash = (w ~ /^<<-/)
        sub(/^<<-?[ \t]*["\047]?/, "", w)
        if (substr(line, RSTART + RLENGTH, 1) == "<") { line = substr(line, RSTART + RLENGTH); continue }
        return w
      }
      return ""
    }
    !inside && $0 ~ "^" fn "\\(\\) *\\{" { inside = 1; print; next }
    inside {
      print
      if (term != "") {
        cur = $0; if (dash) sub(/^\t+/, "", cur)
        if (cur == term) term = ""
        next
      }
      if ($0 == "}") exit
      w = heredoc_word($0); if (w != "") term = w
    }
  ' "$1"
}

names=("$@")
(( ${#names[@]} )) || names=("${STAGE4[@]}" "${STAGEF[@]}")
for fn in "${names[@]}"; do
  body="$(extract "$MGR" "$fn")"
  if [[ -z "$body" ]]; then printf 'ABSENT  %s\n' "$fn"; continue; fi
  printf '%s  %s\n' "$(printf '%s\n' "$body" | sha256sum | awk '{print $1}')" "$fn"
done
if (( $# == 0 )); then
  for fn in "${STAGE4[@]}"; do
    printf '### %s\n%s\n' "$fn" "$(extract "$MGR" "$fn")"
  done | sha256sum | awk '{print $1 "  stage4-protected-function-set-full"}'
fi
