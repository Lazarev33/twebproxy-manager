#!/usr/bin/env bash
# Stage C1.1 scope against the exact v0.2.14 (Stage C1, 810beac) tree: only the
# backend stop, profile/instance deletion, repair, add and orphan
# reconciliation paths may change; ui_localize_legacy may only gain lines;
# everything else, including README, assets and all docs, is byte-identical.
# Usage: c11-scope-invariants.sh <v0.2.14 tree> [<candidate tree>]
set -Eeuo pipefail
BASE="${1:?v0.2.14 tree}"; PROJECT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
TMP="$(mktemp -d /tmp/twebproxy-c11-scope.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
MODIFIED=(stop_profile_backend profile_state_remove profile_delete_cmd delete_instance_cmd
  repair_instance_cmd profile_add_cmd add_instance_cmd ui_localize_legacy
  profile_rotate_cmd profile_carrier_cmd)   # C1.2 ownership guard
ADDED=(stop_backend_unit orphan_backend_ids reconcile_orphan_backends
  backend_id_owners live_backend_pairs shared_backend_ids require_unshared_backends   # C1.2
  backend_id_used_by_other overlapping_hosts)
NEW_VARS=()
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
diff -u "$TMP/baseline.vars" "$TMP/candidate.vars"
echo 'PASS top-level variables unchanged except release identity'

for f in README.md assets/nfqws-linux-x86_64 assets/nfqws-LICENSE.txt assets/NFQWS-PROVENANCE.txt; do
  cmp "$BASE/$f" "$PROJECT/$f"
done
for f in "$BASE"/docs/*.md; do
  [[ "${f##*/}" == ROADMAP.md ]] && continue   # stage status table, updated by C1.2
  cmp "$f" "$PROJECT/docs/${f##*/}"
done
echo 'PASS README, pinned nfqws assets and docs (except ROADMAP.md status) unchanged'
actual="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$PROJECT/twebproxy-manager.sh")"
[[ "${actual%% *}" == fd0e123c516324c23f0a42084f666104db5c35c58e1518a05abee1704b04abcb ]]
echo "$actual"
printf 'PASS c11-scope unchanged=%s modified=%s added=%s\n' "$unchanged" "$modified" "$added"
