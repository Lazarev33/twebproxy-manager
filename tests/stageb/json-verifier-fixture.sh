#!/usr/bin/env bash
# Schema/negative tests; not a substitute for the actual kernel round trip.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1
source "${1:-$ROOT/twebproxy-manager.sh}"
trap - ERR
TMP="$(mktemp -d /tmp/twebproxy-backend-json.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
export BF_TEST_ROOT="$TMP"
backend_fw_render 23980,28980 > "$TMP/live"
bash "$ROOT/tests/stageb/nft-model.sh" -j -n list table inet twebproxy_backend > "$TMP/good.json"
[[ "$(backend_fw_ports_json "$TMP/good.json")" == 23980,28980 ]]
echo 'PASS backend-json-exact-valid'
reject() {
  jq "$2" "$TMP/good.json" > "$TMP/bad.json"
  if backend_fw_ports_json "$TMP/bad.json" > "$TMP/out" 2>&1; then echo "FAIL $1"; exit 1; fi
  echo "PASS $1"
}
reject wrong_port '.nftables[-1].rule.expr[1].match.right.set=[239800,28980]'
reject accept_instead_of_drop '.nftables[-1].rule.expr[-1]={"accept":null}'
reject wrong_hook '.nftables[2].chain.hook="output"'
reject wrong_priority '.nftables[2].chain.prio=0'
reject dormant_table '.nftables[1].table.flags=["dormant"]'
reject wrong_loopback_test '.nftables[-1].rule.expr[0].match.op="=="'
reject missing_port_match '.nftables[-1].rule.expr|=del(.[1])'
reject extra_effect '.nftables[-1].rule.expr|=([{"counter":null}]+.)'
reject foreign_chain '.nftables+=[{"chain":{"family":"inet","table":"twebproxy_backend","name":"operator"}}]'
reject named_set '.nftables+=[{"set":{"family":"inet","table":"twebproxy_backend","name":"operator"}}]'
jq '.nftables[-1].rule.expr|=([{"match":{"op":"==","left":{"meta":{"key":"l4proto"}},"right":6}}]+.)' "$TMP/good.json" > "$TMP/tcp.json"
[[ "$(backend_fw_ports_json "$TMP/tcp.json")" == 23980,28980 ]]
echo 'PASS backend-json-explicit-protocol-dependency'
backend_fw_render '' > "$TMP/live"
bash "$ROOT/tests/stageb/nft-model.sh" -j -n list table inet twebproxy_backend > "$TMP/empty.json"
[[ "$(backend_fw_ports_json "$TMP/empty.json")" == "" ]]
echo 'PASS backend-json-empty-chain'
