#!/usr/bin/env bash
# Real kernel state tests. Never use the host/global namespace.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
# Disposable lab host only (tests/LAB.md); checked again in the inner phase.
source "$ROOT/tests/lib/lab-gate.sh"
lab_gate_or_exit stageb-real-nft
if [[ "${2:-}" != --inside ]]; then
  command -v nft >/dev/null || { echo 'NOT_EXECUTED_ENVIRONMENT_LIMITATION: nft unavailable'; exit 77; }
  timeout 5 unshare --net true || { echo 'NOT_EXECUTED_ENVIRONMENT_LIMITATION: network namespace/CAP_NET_ADMIN unavailable'; exit 77; }
  export STAGEB_PARENT_NETNS="$(readlink /proc/self/ns/net)"
  exec timeout 120 unshare --net bash "$0" "$MGR" --inside
fi
[[ -n "${STAGEB_PARENT_NETNS:-}" && "$(readlink /proc/self/ns/net)" != "$STAGEB_PARENT_NETNS" ]] ||
  { echo 'FAIL: refusing host namespace'; exit 1; }
TMP="$(mktemp -d /tmp/twebproxy-stageb-real.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
export TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1
source "$MGR"
trap - ERR
BASE_DIR="$TMP/etc"; BACKENDS_DIR="$BASE_DIR/backends"; FIREWALL_FILE="$BASE_DIR/firewall.nft"
LIBEXEC_DIR="$TMP/libexec"; SYSTEMD_DIR="$TMP/systemd"
install -d -m 0700 "$BASE_DIR" "$BACKENDS_DIR" "$LIBEXEC_DIR" "$SYSTEMD_DIR" "$TMP/bin"
NFT="$(command -v nft)"
export BF_TEST_ROOT="$TMP" BF_TEST_CANONICAL="$FIREWALL_FILE"
cat > "$TMP/bin/mv" <<'SH'
#!/bin/bash
if [[ -f "$BF_TEST_ROOT/fail-publish" && "${*: -1}" == "$BF_TEST_CANONICAL" ]]; then exit 1; fi
exec /usr/bin/mv "$@"
SH
chmod 0700 "$TMP/bin/mv"; export PATH="$TMP/bin:$PATH"
write_backend_firewall_helper
helper="$LIBEXEC_DIR/apply-firewall"
"$NFT" --version
# A foreign table/chain/rule must be byte-semantically unchanged.
"$NFT" -f - <<'NFT'
table inet stageb_foreign {
  chain unrelated {
    type filter hook output priority 50; policy accept;
    counter
  }
}
NFT
"$NFT" -j -s list table inet stageb_foreign > "$TMP/foreign.before"
printf 'MTPROXY_CLIENT_PORT=23980\nMTPROXY_STATS_PORT=28980\n' > "$BACKENDS_DIR/a.env"
"$helper"
echo 'PASS real-first-install'
"$NFT" -j -n list table inet twebproxy_backend > "$TMP/before.json"
before="$(backend_fw_ports_json "$TMP/before.json")"; [[ "$before" == 23980,28980 ]]
# Later error after delete must abort the entire kernel batch.
{
  printf 'add table inet twebproxy_backend\ndelete table inet twebproxy_backend\n'
  cat "$FIREWALL_FILE"
  printf 'add rule inet stageb_nonexistent missing drop\n'
} > "$TMP/late-failure.nft"
if "$NFT" -f "$TMP/late-failure.nft"; then echo 'FAIL late error accepted'; exit 1; fi
"$NFT" -j -n list table inet twebproxy_backend > "$TMP/after.json"
cmp "$TMP/before.json" "$TMP/after.json"
echo 'PASS real-delete-plus-late-error-preserves-table'
printf 'not valid nft syntax\n' > "$TMP/invalid.nft"
if "$NFT" -f "$TMP/invalid.nft"; then exit 1; fi
"$NFT" -j -n list table inet twebproxy_backend > "$TMP/after.json"
cmp "$TMP/before.json" "$TMP/after.json"
echo 'PASS real-invalid-candidate-preserves-table'
printf 'MTPROXY_CLIENT_PORT=23981\nMTPROXY_STATS_PORT=28981\n' > "$BACKENDS_DIR/b.env"
"$helper"
"$NFT" -j -n list table inet twebproxy_backend > "$TMP/multiple.json"
[[ "$(backend_fw_ports_json "$TMP/multiple.json")" == 23980,23981,28980,28981 ]]
echo 'PASS real-valid-replacement-multiple-backends'
cp "$FIREWALL_FILE" "$TMP/file.before"
"$helper"
cmp "$TMP/file.before" "$FIREWALL_FILE"
echo 'PASS real-repeated-apply'
rm "$BACKENDS_DIR/b.env"
touch "$TMP/fail-publish"
if "$helper"; then echo 'FAIL publish failure hidden'; exit 1; fi
cmp "$TMP/file.before" "$FIREWALL_FILE"
"$NFT" -j -n list table inet twebproxy_backend > "$TMP/restored.json"
[[ "$(backend_fw_ports_json "$TMP/restored.json")" == 23980,23981,28980,28981 ]]
rm "$TMP/fail-publish"
echo 'PASS real-publish-failure-restores-old-kernel-state'
"$helper"
"$NFT" -j -n list table inet twebproxy_backend > "$TMP/one.json"
[[ "$(backend_fw_ports_json "$TMP/one.json")" == 23980,28980 ]]
rm "$BACKENDS_DIR/a.env"
"$helper"
"$NFT" -j -n list table inet twebproxy_backend > "$TMP/empty.json"
[[ "$(backend_fw_ports_json "$TMP/empty.json")" == "" ]]
echo 'PASS real-empty-backend-set'
"$NFT" -j -s list table inet stageb_foreign > "$TMP/foreign.after"
cmp "$TMP/foreign.before" "$TMP/foreign.after"
echo 'PASS real-foreign-table-untouched'
