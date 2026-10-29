#!/usr/bin/env bash
# Stage G regression: the Nginx Let's Encrypt webroot stays traversable for the
# web server when /var/lib/twebproxy already exists with mode 0700 (created that
# way by the Stage 4 updater of v0.2.8-0.2.19 before Nginx LE was configured;
# Stage F DEFERRED item 1).
#
# The real configure_tls_for_instance -> configure_nginx_le code runs in the
# Stage D frontend harness (Nginx/certbot/systemd are models there); the
# decisive observation is real: the kernel decides whether the web server user
# (www-data, uid 33, as on Debian/Ubuntu) can read a challenge file, checked with
# setpriv. Needs root; nothing outside the temporary directory is touched.
#
# Usage: acme-webroot-fixture.sh [path/to/twebproxy-manager.sh]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'NOT_EXECUTED acme-webroot-fixture: needs root'; exit 77; }
command -v setpriv >/dev/null 2>&1 || { echo 'NOT_EXECUTED acme-webroot-fixture: setpriv missing'; exit 77; }
WEB_UID="$(id -u www-data 2>/dev/null || echo 33)"; WEB_GID="$(id -g www-data 2>/dev/null || echo 33)"
TMP="$(mktemp -d /tmp/twebproxy-g-acme.XXXXXX)"
trap 'kill $(jobs -p) 2>/dev/null; [[ -n "${KEEP_G_TMP:-}" ]] || rm -rf -- "$TMP"' EXIT
chmod 0711 "$TMP"                     # the test root itself must be traversable for www-data
source "$ROOT/tests/staged/frontend-harness.sh"
d_harness
export TWEBPROXY_RELAY_READY_WAIT=3
pass=0; fail=0
check() { local name="$1"; shift; if "$@"; then printf 'PASS %s\n' "$name"; pass=$((pass+1)); else printf 'FAIL %s\n' "$name"; fail=$((fail+1)); fi; }
A=alpha.example
PARENT="$TMP/var/lib/twebproxy"; export G_ACME="$PARENT/acme"

world() { # $1=mode of a pre-existing /var/lib/twebproxy
  rm -rf "$INSTANCES_DIR" "$BACKENDS_DIR" "$TMP/var" "$NGINX_DIR" "$LE_DIR" "$TMP/run" "$TMP"/units/*
  install -d -m 0700 "$INSTANCES_DIR" "$BACKENDS_DIR"
  install -d -m 0755 "$NGINX_DIR/conf.d" "$NGINX_DIR/sites-available" "$NGINX_DIR/sites-enabled" "$LE_DIR/live" "$LE_DIR/archive" "$TMP/run" "$TMP/var/lib"
  install -d -m "$1" "$PARENT"
  install -d -m 0700 "$PARENT/update-backups"      # what the updater keeps there
  c2_relay_binary old > "$TPROXY_BIN"; chmod 0755 "$TPROXY_BIN"
  d_seed_instance "$A" 18080 18081 nginx-le admin@example.org
  c1_seed_profile "$A" main "$(printf '%032d' 1)" https 23980 28980
  c1_run rebuild_profiles_json "$A" >/dev/null 2>&1
  "$TMP/bin/systemctl" start "twebproxy-mtproxy@$A--main.service"
  "$TMP/bin/systemctl" start "twebproxy@$A.service"
}
issue() { d_eval "ACME_WEBROOT=\"\$G_ACME\"; configure_tls_for_instance $A" > "$TMP/out" 2>&1; rc=$?; }
# What certbot --webroot does, then what nginx (www-data) does for the CA.
challenge_readable() {
  install -d -m 0755 "$G_ACME/.well-known/acme-challenge"
  printf 'token-content\n' > "$G_ACME/.well-known/acme-challenge/token"; chmod 0644 "$G_ACME/.well-known/acme-challenge/token"
  setpriv --reuid="$WEB_UID" --regid="$WEB_GID" --clear-groups cat "$G_ACME/.well-known/acme-challenge/token" > "$TMP/served" 2>"$TMP/served.err" \
    && grep -qx token-content "$TMP/served"
}
mode() { stat -c %a "$1"; }

# 1. Parent pre-exists with 0700 (an earlier updater created it).
world 0700
check "g4_precondition_parent_0700_denies_www_data" eval '! setpriv --reuid="$WEB_UID" --regid="$WEB_GID" --clear-groups ls "$PARENT" >/dev/null 2>&1'
issue
check "g4_0700_parent_issue_ok (rc=$rc)" test "$rc" -eq 0
check "g4_0700_parent_challenge_readable_by_www_data" challenge_readable
check "g4_0700_parent_only_traversal_added (mode $(mode "$PARENT"))" test "$(mode "$PARENT")" = 711
check "g4_0700_parent_not_listable_by_others" eval '! setpriv --reuid="$WEB_UID" --regid="$WEB_GID" --clear-groups ls "$PARENT" >/dev/null 2>&1'
check "g4_backup_root_still_private" test "$(mode "$PARENT/update-backups")" = 700

# 1b. The parent fell back to 0700 after issuance: cert-renew repairs traversal too.
chmod 0700 "$PARENT"
d_eval "ACME_WEBROOT=\"\$G_ACME\"; cert_renew_cmd $A --force" > "$TMP/out" 2>&1; rc=$?
check "g4_renew_ok (rc=$rc)" test "$rc" -eq 0
check "g4_renew_restores_traversal (mode $(mode "$PARENT"))" test "$(mode "$PARENT")" = 711

# 2. Parent already traversable (0755, as install -d creates it): unchanged.
world 0755
issue
check "g4_0755_parent_issue_ok (rc=$rc)" test "$rc" -eq 0
check "g4_0755_parent_challenge_readable_by_www_data" challenge_readable
check "g4_0755_parent_mode_unchanged" test "$(mode "$PARENT")" = 755

# 3. A parent that is a symbolic link is not modified through the link.
world 0700
mv "$PARENT" "$TMP/real-parent"; ln -s "$TMP/real-parent" "$PARENT"
issue
check "g4_symlinked_parent_target_not_chmodded (mode $(mode "$TMP/real-parent"))" test "$(mode "$TMP/real-parent")" = 700

printf 'acme-webroot-fixture: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
