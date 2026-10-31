#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/twebproxy-manager.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v openssl >/dev/null

# Load function definitions without executing the manager command dispatcher.
awk '/^cmd="\$\{1:-menu\}"/{exit} {print}' "$SCRIPT" > "$TMP/lib.sh"
# shellcheck disable=SC1090
source "$TMP/lib.sh"

openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
  -subj '/CN=certificate-smoke.test' -days 2 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1

days="$(cert_days_remaining_file "$TMP/cert.pem")"
fp="$(cert_fingerprint_file "$TMP/cert.pem")"
[[ "$days" =~ ^[0-9]+$ ]]
[[ "$fp" == *:* ]]

SYSTEMD_DIR="$TMP/units"
mkdir -p "$SYSTEMD_DIR"
systemctl() { return 0; }
write_certbot_fallback_timer

grep -q 'ExecStart=/usr/bin/certbot renew --quiet' "$SYSTEMD_DIR/twebproxy-cert-renew.service"
grep -q 'Persistent=true' "$SYSTEMD_DIR/twebproxy-cert-renew.timer"
grep -q 'RandomizedDelaySec=1h' "$SYSTEMD_DIR/twebproxy-cert-renew.timer"

printf 'certificate-smoke: PASS\n'
