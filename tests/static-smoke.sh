#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/twebproxy-manager.sh"

bash -n "$SCRIPT"
grep -q 'MANAGER_VERSION="0.2.8"' "$SCRIPT"
grep -q 'MANAGER_RELEASE_VERSION="0.2.8-dpi-beta"' "$SCRIPT"
grep -q 'MANAGER_REPO_SLUG="Lazarev33/twebproxy-manager"' "$SCRIPT"
grep -q 'TPROXY_INSTALL_COMMIT="2873a08806d6e4d84830b9b5c4b0ec0f46af91f8"' "$SCRIPT"
grep -q 'sync_tproxy_upstream latest' "$SCRIPT"
grep -q 'RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK' "$SCRIPT"
grep -q -- '--http-stats' "$SCRIPT"
grep -q 'LoadCredential=config.json:' "$SCRIPT"
grep -q 'LoadCredential=profiles.json:' "$SCRIPT"
grep -q 'LoadCredential=proxy-secret:' "$SCRIPT"
grep -q 'audit \[hostname\]' "$SCRIPT"
grep -q 'check-update' "$SCRIPT"
grep -q 'manager-update' "$SCRIPT"
grep -q 'SHA256SUMS' "$SCRIPT"
grep -q 'manager_update_hint' "$SCRIPT"
grep -q 'listener_addrs_for_port' "$SCRIPT"
grep -q 'public HTTPS + TLS verification PASS' "$SCRIPT"
grep -q 'STRICT_TLS=PASS' "$SCRIPT"
grep -q 'cert-status' "$SCRIPT"
grep -q 'cert-renew' "$SCRIPT"
grep -q 'certbot.timer' "$SCRIPT"
grep -q 'twebproxy-cert-renew.timer' "$SCRIPT"
grep -q -- '--dry-run' "$SCRIPT"
grep -q 'local/public certificate MATCH' "$SCRIPT"
grep -q 'Caddy automatic TLS manager active' "$SCRIPT"
grep -q 'MANIFEST.sha256' "$SCRIPT"
grep -q 'service-history.log' "$SCRIPT"
grep -q -- '-S\[\[:space:\]\]' "$SCRIPT"

count="$(grep -c '^RestrictAddressFamilies=AF_INET AF_INET6$' "$SCRIPT")"
[[ "$count" -ge 1 ]]

[[ "$(tr -d '[:space:]' < "$ROOT/VERSION")" == "0.2.8" ]]
grep -q 'DPI_NFQWS_RELEASE_ARCHIVE_URL="https://github.com/bol-van/zapret/releases/download/v72.13/zapret-v72.13.tar.gz"' "$SCRIPT"
grep -q 'DPI_NFQWS_BINARY_BYTES=125760' "$SCRIPT"

printf 'static-smoke: PASS\n'
