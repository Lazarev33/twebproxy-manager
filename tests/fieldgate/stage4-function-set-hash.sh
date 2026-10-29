#!/usr/bin/env bash
# Extracts the accepted Stage 4 protected function set from a manager script and
# prints a stable SHA-256 over its concatenated text. Used to prove that a
# correction pass left Stage 4 byte-identical.
set -Eeuo pipefail
MGR="${1:?usage: stage4-function-set-hash.sh <twebproxy-manager.sh> [--list]}"

STAGE4_FUNCS=(
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

extract() { # $1=file $2=fname -> function body from "name() {" to the matching closing brace at col 0
  awk -v fn="$2" '
    $0 ~ "^"fn"\\(\\) *\\{" {inside=1}
    inside {print}
    inside && /^\}$/ {inside=0; exit}
  ' "$1"
}

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
for fn in "${STAGE4_FUNCS[@]}"; do
  body="$(extract "$MGR" "$fn")"
  [[ -n "$body" ]] || { printf 'stage4-function-set-hash: function not found: %s\n' "$fn" >&2; exit 1; }
  printf '### %s\n%s\n' "$fn" "$body" >> "$tmp"
done

if [[ "${2:-}" == --list ]]; then
  printf '%s functions, %s lines\n' "${#STAGE4_FUNCS[@]}" "$(wc -l < "$tmp")"
  printf '%s\n' "${STAGE4_FUNCS[@]}"
fi
printf '%s  stage4-protected-function-set\n' "$(sha256sum "$tmp" | awk '{print $1}')"
