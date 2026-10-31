#!/usr/bin/env bash
# Stage B.1 scope: compared with the exact v0.2.12 tree, only the backend
# firewall generator/rebuild functions may change, plus one added helper and the
# release identity. Stage 4, DPI, relay, profile, frontend and UI code, generated
# non-firewall payloads, README, docs and assets stay byte-identical.
# Usage: b1-scope-invariants.sh <v0.2.12 tree> [<candidate tree>]
set -Eeuo pipefail
BASE="${1:?v0.2.12 tree}"; PROJECT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
TMP="$(mktemp -d /tmp/twebproxy-b1-scope.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
for side in baseline candidate; do
  tree="$BASE"; [[ "$side" != candidate ]] || tree="$PROJECT"
  TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 bash -c '
    source "$1"; trap - ERR
    while read -r fn; do
      hash="$(declare -f "$fn" | sha256sum)"
      printf "%s %s\n" "$fn" "${hash%% *}"
    done < <(compgen -A function | sort)
  ' _ "$tree/twebproxy-manager.sh" > "$TMP/$side"
done
unchanged=0; modified=0; added=0
while read -r fn old; do
  new="$(awk -v f="$fn" '$1==f{print $2}' "$TMP/candidate")"
  [[ -n "$new" ]] || { echo "FAIL removed function: $fn"; exit 1; }
  if [[ "$old" == "$new" ]]; then unchanged=$((unchanged+1)); continue; fi
  case "$fn" in rebuild_firewall|write_backend_firewall_helper|write_backend_firewall_unit|backend_fw_transaction) ;;
    *) echo "FAIL forbidden modification: $fn"; exit 1;; esac
  echo "allowed modified: $fn"; modified=$((modified+1))
done < "$TMP/baseline"
while read -r fn hash; do
  if awk -v f="$fn" '$1==f{found=1} END{exit !found}' "$TMP/baseline"; then continue; fi
  case "$fn" in backend_fw_apply_failed) ;; *) echo "FAIL unexpected added function: $fn"; exit 1;; esac
  echo "allowed added: $fn"; added=$((added+1))
done < "$TMP/candidate"
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
  ' _ "$tree/twebproxy-manager.sh" > "$TMP/$side.outside"
done
diff -u "$TMP/baseline.outside" "$TMP/candidate.outside"
echo 'PASS top-level manager variables unchanged (except release identity)'
for f in README.md assets/nfqws-linux-x86_64 assets/nfqws-LICENSE.txt assets/NFQWS-PROVENANCE.txt; do
  cmp "$BASE/$f" "$PROJECT/$f"
done
for f in "$BASE"/docs/*.md; do cmp "$f" "$PROJECT/docs/${f##*/}"; done
echo 'PASS README, docs and pinned nfqws assets unchanged'
for token in 'cat > "$LIBEXEC_DIR/run-mtproxy"' 'cat > "$LIBEXEC_DIR/refresh-mtproxy-config"' \
  'cat > "$SYSTEMD_DIR/twebproxy@.service"' 'cat > "$SYSTEMD_DIR/twebproxy-mtproxy@.service"' \
  'cat > "$SYSTEMD_DIR/twebproxy-refresh-mtproxy.service"' 'cat > "$SYSTEMD_DIR/twebproxy-refresh-mtproxy.timer"'; do
  for side in baseline candidate; do
    tree="$BASE"; [[ "$side" != candidate ]] || tree="$PROJECT"
    awk -v token="$token" 'index($0,token){p=1;next} p && $0=="EOF"{exit} p{print}' "$tree/twebproxy-manager.sh" > "$TMP/$side.payload"
    [[ -s "$TMP/$side.payload" ]]
  done
  cmp "$TMP/baseline.payload" "$TMP/candidate.payload"
done
echo 'PASS six non-firewall generated helper/unit payloads unchanged'
actual="$(bash "$PROJECT/tests/fieldgate/stage4-function-set-hash.sh" "$PROJECT/twebproxy-manager.sh")"
[[ "${actual%% *}" == fd0e123c516324c23f0a42084f666104db5c35c58e1518a05abee1704b04abcb ]]
echo "$actual"
printf 'PASS b1-scope unchanged=%s modified=%s added=%s\n' "$unchanged" "$modified" "$added"
