#!/usr/bin/env bash
# Stage C1 scope against the exact v0.2.13 (Stage B.1) tree: only profile,
# instance-state, lock and port functions may change; ui_localize_legacy may
# only gain lines; Stage B/B.1 firewall, DPI, TLS, relay update, Stage 4 and
# menu code stay byte-identical; README, assets and docs other than the
# GitHub-synchronized ROADMAP.md are unchanged.
# Usage: c1-scope-invariants.sh <v0.2.13 tree> [<candidate tree>]
set -Eeuo pipefail
BASE="${1:?v0.2.13 tree}"; PROJECT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
TMP="$(mktemp -d /tmp/twebproxy-c1-scope.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
MODIFIED=(load_instance load_profile save_instance save_profile port_registered port_listening
  port_available next_free_port rebuild_profiles_json write_instance_config wait_profile_backend_ready
  collect_instance_settings collect_profile_settings add_instance_cmd repair_instance_cmd
  profile_add_cmd profile_delete_cmd profile_rotate_cmd profile_carrier_cmd delete_instance_cmd
  ui_localize_legacy stop_profile_backend)
ADDED=(is_valid_carrier_mode state_read_record profile_record_valid require_instance require_profile
  state_write_file render_instance_record render_profile_record render_backend_env instance_derive_state
  profile_state_commit profile_state_remove profile_state_restore state_lock_path instance_lock_acquire
  instance_lock_release port_lock_acquire port_lock_release claim_instance_ports claim_profile_ports
  render_profile_json_entry require_profile_file stop_backend_unit orphan_backend_ids reconcile_orphan_backends
  backend_id_owners live_backend_pairs shared_backend_ids require_unshared_backends
  backend_id_used_by_other overlapping_hosts)
NEW_VARS=(STATE_LOCK_WAIT_SECONDS INSTANCE_LOCK_FD INSTANCE_LOCK_HOST INSTANCE_LOCK_DEPTH PORT_LOCK_FD PORT_LOCK_DEPTH)
in_list() { local x="$1"; shift; local y; for y; do [[ "$x" == "$y" ]] && return 0; done; return 1; }

for side in baseline candidate; do
  tree="$BASE"; [[ "$side" != candidate ]] || tree="$PROJECT"
  TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 bash -c '
    source "$1"; trap - ERR
    while read -r fn; do
      hash="$(declare -f "$fn" | sha256sum)"
      printf "%s %s\n" "$fn" "${hash%% *}"
    done < <(compgen -A function | sort)
    declare -f ui_localize_legacy > "$2.l10n"
  ' _ "$tree/twebproxy-manager.sh" "$TMP/$side" > "$TMP/$side"
done
unchanged=0; modified=0; added=0
while read -r fn old; do
  new="$(awk -v f="$fn" '$1==f{print $2}' "$TMP/candidate")"
  [[ -n "$new" ]] || { echo "FAIL removed function: $fn"; exit 1; }
  if [[ "$old" == "$new" ]]; then unchanged=$((unchanged+1)); continue; fi
  in_list "$fn" "${MODIFIED[@]}" || { echo "FAIL forbidden modification: $fn"; exit 1; }
  echo "allowed modified: $fn"; modified=$((modified+1))
done < "$TMP/baseline"
while read -r fn hash; do
  awk -v f="$fn" '$1==f{found=1} END{exit !found}' "$TMP/baseline" && continue
  in_list "$fn" "${ADDED[@]}" || { echo "FAIL unexpected added function: $fn"; exit 1; }
  added=$((added+1))
done < "$TMP/candidate"
echo "PASS functions: unchanged=$unchanged modified=$modified added=$added"

# Localization adapter: additions only (new message translations).
if diff "$TMP/baseline.l10n" "$TMP/candidate.l10n" | grep -E '^[<]' >/dev/null; then
  echo 'FAIL ui_localize_legacy lost or changed existing lines'; exit 1
fi
echo "PASS ui_localize_legacy: only $(diff "$TMP/baseline.l10n" "$TMP/candidate.l10n" | grep -c '^>') added lines"

for side in baseline candidate; do
  tree="$BASE"; [[ "$side" != candidate ]] || tree="$PROJECT"
  TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 bash -c '
    before=""; before="$(compgen -v)"
    source "$1"; trap - ERR
    while read -r name; do
      case "$name" in MANAGER_VERSION|MANAGER_RELEASE_VERSION|name) continue;; esac
      if grep -Fxq -- "$name" <<< "$before"; then continue; fi
      declare -p "$name"
    done < <(compgen -v | sort)
  ' _ "$tree/twebproxy-manager.sh" > "$TMP/$side.vars"
done
grep -vE "^declare [-a-zA-Z]+ ($(IFS='|'; echo "${NEW_VARS[*]}"))=" "$TMP/candidate.vars" > "$TMP/candidate.vars.old"
diff -u "$TMP/baseline.vars" "$TMP/candidate.vars.old"
echo 'PASS top-level variables unchanged except release identity and the C1 lock state'

for f in README.md assets/nfqws-linux-x86_64 assets/nfqws-LICENSE.txt assets/NFQWS-PROVENANCE.txt; do
  cmp "$BASE/$f" "$PROJECT/$f"
done
for f in "$BASE"/docs/*.md; do
  [[ "${f##*/}" == ROADMAP.md ]] && continue
  cmp "$f" "$PROJECT/docs/${f##*/}"
done
echo 'PASS README, pinned nfqws assets and docs (except synchronized ROADMAP.md) unchanged'
actual="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$PROJECT/twebproxy-manager.sh")"
[[ "${actual%% *}" == fd0e123c516324c23f0a42084f666104db5c35c58e1518a05abee1704b04abcb ]]
echo "$actual"
printf 'PASS c1-scope unchanged=%s modified=%s added=%s\n' "$unchanged" "$modified" "$added"
