#!/usr/bin/env bash
# This script is intentionally only for the immutable v0.2.11 input.
set -euo pipefail
MGR="${1:?v0.2.11 manager}"
TMP="$(mktemp -d /tmp/twebproxy-stageb-before.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1
source "$MGR"
trap - ERR
BASE_DIR="$TMP/etc"; BACKENDS_DIR="$BASE_DIR/backends"; FIREWALL_FILE="$BASE_DIR/firewall.nft"
LIBEXEC_DIR="$TMP/libexec"; SYSTEMD_DIR="$TMP/systemd"
mkdir -p "$BACKENDS_DIR" "$LIBEXEC_DIR" "$SYSTEMD_DIR" "$TMP/bin"
export BF_TEST_ROOT="$TMP" BF_TEST_CANONICAL="$FIREWALL_FILE"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cp "$ROOT/tests/stageb/nft-model.sh" "$TMP/bin/nft"; chmod 0700 "$TMP/bin/nft"
export PATH="$TMP/bin:$PATH"
systemctl() { printf '%s\n' "$*" >> "$TMP/systemctl.calls"; return 0; }
write_runner_helpers
write_systemd_templates
# Rebase the legacy fixed path only; run its actual generated delete/load body.
sed "s|/etc/twebproxy/firewall.nft|$FIREWALL_FILE|g" "$LIBEXEC_DIR/apply-firewall" > "$TMP/old-helper"
printf 'old isolation\n' > "$TMP/live"
printf 'table inet twebproxy_backend {\n}\n' > "$FIREWALL_FILE"
touch "$TMP/fail-apply"
rc=0; bash "$TMP/old-helper" || rc=$?
[[ "$rc" != 0 && ! -e "$TMP/live" ]]
printf 'REPRODUCED old-helper: load rc=%s, previous isolation deleted\n' "$rc"
rm "$TMP/fail-apply"
printf 'MTPROXY_CLIENT_PORT=23980\nMTPROXY_STATS_PORT=28980\n' > "$BACKENDS_DIR/a.env"
(rebuild_firewall)
grep -q '^restart twebproxy-firewall.service' "$TMP/systemctl.calls"
grep '^ExecStop=' "$SYSTEMD_DIR/twebproxy-firewall.service"
printf 'REPRODUCED rebuild: restart invokes destructive ExecStop\n'
# Faulted canonical write in the exact conditional-errexit context.
rm "$FIREWALL_FILE"
ln -s /dev/full "$FIREWALL_FILE"
if (rebuild_firewall) 2>"$TMP/write.err"; then
  printf 'REPRODUCED canonical write failure: rebuild rc=0\n'
else printf 'FAIL write failure did not reproduce\n'; exit 1; fi
grep 'No space left' "$TMP/write.err"
