#!/usr/bin/env bash
# Writes a copy of a pre-Stage-D manager whose literal frontend paths
# (/etc/caddy, /etc/nginx, /etc/letsencrypt, /var/lib/twebproxy/acme) are
# replaced by the Stage D variables CADDYFILE/CADDY_DIR/NGINX_DIR/LE_DIR/
# ACME_WEBROOT, so its frontend code runs inside the frontend harness sandbox.
# Only those literals change (the diff is printed); it is used to reproduce the
# RED baseline and is never installed.
# Usage: rebind-baseline.sh <manager> <output>
set -Eeuo pipefail
in="${1:?manager}" out="${2:?output}"
sed -e 's#/etc/caddy/Caddyfile#${CADDYFILE}#g' -e 's#/etc/caddy#${CADDY_DIR}#g' -e 's#/etc/nginx#${NGINX_DIR}#g' \
    -e 's#/etc/letsencrypt#${LE_DIR}#g' -e 's#/var/lib/twebproxy/acme#${ACME_WEBROOT}#g' "$in" > "$out"
bash -n "$out"
diff "$in" "$out" | grep -E '^[<>]' | sed -E 's#\$\{(CADDYFILE|CADDY_DIR|NGINX_DIR|LE_DIR|ACME_WEBROOT)\}#<\1>#g' |
  awk '{print}' > "$out.diff" || true
changed="$(diff "$in" "$out" | grep -c '^<' || true)"
# Every changed line differs only in the substituted literals.
paste -d '\n' <(diff "$in" "$out" | grep '^<' | cut -c3-) <(diff "$in" "$out" | grep '^>' | cut -c3- |
  sed -e 's#${CADDYFILE}#/etc/caddy/Caddyfile#g' -e 's#${CADDY_DIR}#/etc/caddy#g' -e 's#${NGINX_DIR}#/etc/nginx#g' \
      -e 's#${LE_DIR}#/etc/letsencrypt#g' -e 's#${ACME_WEBROOT}#/var/lib/twebproxy/acme#g') |
  awk 'NR % 2 { a = $0; next } a != $0 { bad = 1 } END { exit bad }'
printf 'rebind-baseline: %s lines changed, only frontend path literals; written %s\n' "$changed" "$out"
