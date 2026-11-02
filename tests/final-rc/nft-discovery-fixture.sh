#!/bin/bash
# MODEL: replay a failing whole-table JSON CLI. No real host nft or services.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twp-nft-discovery.XXXXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/tests/stageb/backend-harness.sh"
backend_harness
mv "$TMP/bin/nft" "$TMP/bin/nft-model"
cat > "$TMP/bin/nft" <<'WRAP'
#!/bin/bash
if [[ "$*" == '-j list tables inet' ]]; then
  echo 'MODEL: whole-table JSON CLI failed' >&2
  exit 134
fi
exec "$BF_TEST_ROOT/bin/nft-model" "$@"
WRAP
chmod 700 "$TMP/bin/nft"
backend_state a 23980 28980
write_backend_firewall_helper || exit 1
"$BF_TEST_HELPER" > "$TMP/output" 2>&1
rc=$?
if (( rc != 0 )); then cat "$TMP/output"; echo "FAIL whole-table-json-failure-prevents-update rc=$rc (MODEL)"; exit 1; fi
echo 'PASS enumeration-avoids-failing-whole-table-JSON (MODEL)'
cmp "$TMP/live" "$FIREWALL_FILE" || exit 1
cp "$FIREWALL_FILE" "$TMP/before"
touch "$TMP/fail-query"
"$BF_TEST_HELPER" > "$TMP/output" 2>&1
rc=$?
(( rc != 0 )) || exit 1
cmp "$TMP/before" "$FIREWALL_FILE" && cmp "$TMP/before" "$TMP/live" || exit 1
echo 'PASS failed-name-query-is-unknown-and-retains-canonical-and-live (MODEL)'
