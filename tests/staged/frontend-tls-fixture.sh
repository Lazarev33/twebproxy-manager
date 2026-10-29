#!/usr/bin/env bash
# Stage D regression: frontend (Caddy / Nginx) and TLS lifecycle changes are
# failure-safe. A failed, invalid, interrupted or partially written change never
# leaves an invalid or truncated frontend configuration, never restarts the
# frontend, never loses user-managed sites or another instance's block, never
# replaces or removes a valid certificate and never interrupts HTTPS of a
# working hostname; create, repair, delete and renew report frontend failures.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-d-frontend.XXXXXX)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf -- "$TMP"' EXIT
source "$ROOT/tests/staged/frontend-harness.sh"
d_harness
export TWEBPROXY_RELAY_READY_WAIT=3
pass=0; fail=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
not() { ! "$@"; }
show() { grep -E '\[(x|!|\+)\]' "$TMP/out" | tail -n 3 | sed 's/\x1b\[[0-9;]*m//g; s/^/  | /'; }
op() { d_run "$@" > "$TMP/out" 2>&1; rc=$?; }
in_flock() { local c; for c in $(pgrep -P "$1"); do [[ "$(cat "/proc/$c/comm" 2>/dev/null)" == flock ]] && return 0; in_flock "$c" && return 0; done; return 1; }
A=alpha.example B=beta.example C=gamma.example D=delta.example U=shop.example O=other.example

# What the manager writes for a managed Caddy block / Nginx TLS vhost.
tpl_caddy_block() { # $1=host $2=relay
  printf '# BEGIN TWEBPROXY %s\n%s {\n    encode zstd gzip\n    reverse_proxy 127.0.0.1:%s {\n        transport http {\n            response_header_timeout 40s\n        }\n    }\n    log {\n        output discard\n    }\n}\n# END TWEBPROXY %s\n' "$1" "$1" "$2" "$1"
}
tpl_nginx_tls() { # $1=host $2=relay $3=cert $4=key
  cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $1;
    location /.well-known/acme-challenge/ { root $ACME_WEBROOT; }
    location / { return 301 https://\$host\$request_uri; }
    access_log off;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $1;
    ssl_certificate $3;
    ssl_certificate_key $4;
    ssl_protocols TLSv1.2 TLSv1.3;
    access_log off;

    location / {
        proxy_pass http://127.0.0.1:$2;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$twebproxy_connection_upgrade;
        proxy_read_timeout 90s;
        proxy_send_timeout 90s;
        proxy_buffering off;
        client_max_body_size 2m;
    }
}
EOF
}

reset() {
  rm -rf "$INSTANCES_DIR" "$BACKENDS_DIR" "$SITES_DIR" "$BASE_DIR/.locks" "$TMP"/units/* "$TMP"/fail-* \
    "$TMP"/caddy-reject-* "$TMP"/nginx-reject-* "$TMP"/state-* "$TMP"/*.reached "$TMP"/*.go "$TMP"/*.pid \
    "$CADDY_DIR" "$NGINX_DIR" "$LE_DIR" "$ACME_WEBROOT" "$TMP/run" "$TMP/custom" "$TMP/user-certs" "$TMP/firewall.applied"
  install -d -m 0700 "$INSTANCES_DIR" "$BACKENDS_DIR"
  install -d -m 0755 "$SITES_DIR" "$CADDY_DIR" "$NGINX_DIR/conf.d" "$NGINX_DIR/sites-available" "$NGINX_DIR/sites-enabled" \
    "$LE_DIR/live" "$LE_DIR/archive" "$TMP/run"
  c2_relay_binary old > "$TPROXY_BIN"; chmod 0755 "$TPROXY_BIN"
}
seed_host() { # $1=host $2=index $3=tls [$4 $5]: instance with one running profile and a running relay
  d_seed_instance "$1" $((18080 + 2 * $2)) $((18081 + 2 * $2)) "$3" "${4:-}" "${5:-}"
  c1_seed_profile "$1" main "$(printf '%032d' $(($2 + 1)))" https $((23980 + $2)) $((28980 + $2))
  c1_run rebuild_profiles_json "$1" >/dev/null 2>&1
  "$TMP/bin/systemctl" start "twebproxy-mtproxy@$1--main.service"
  "$TMP/bin/systemctl" start "twebproxy@$1.service"
}
settle() { c1_eval rebuild_firewall >/dev/null 2>&1; : > "$TMP/events"; : > "$TMP/run/nginx.history"; }
no_frontend_debris() { [[ -z "$(find "$CADDY_DIR" "$NGINX_DIR" -name '.twebproxy-*' 2>/dev/null)" ]]; }
instance_kept() { [[ -f "$INSTANCES_DIR/$1/instance.env" && -f "$BACKENDS_DIR/$1--main.env" ]] && c2_relay_up "$1" &&
  [[ -e "$TMP/units/twebproxy-mtproxy@$1--main.service" ]]; }

# ---------- Caddy world: user sites around the managed blocks of alpha and beta ----------
USER_HEAD=$'{\n\temail admin@example.org\n}\n\nshop.example {\n\trespond "user shop"\n}\n'
USER_TAIL=$'\nblog.example {\n\trespond "user blog"\n}\n'
caddy_world() { # [$1=edit before Caddy starts] [$2=edit after it started (on disk only)]
  reset; seed_host "$A" 0 caddy; seed_host "$B" 1 caddy; seed_host "$C" 2 caddy; chmod 0750 "$CADDY_DIR"
  { printf '%s\n' "$USER_HEAD"; tpl_caddy_block "$A" 18080; printf '\n'; tpl_caddy_block "$B" 18082; printf '%s' "$USER_TAIL"; } > "$CADDYFILE"
  [[ -z "${1:-}" ]] || "$1"
  chmod 0644 "$CADDYFILE"
  "$TMP/bin/systemctl" start caddy >/dev/null 2>&1
  [[ -z "${2:-}" ]] || "$2"
  CF0="$(sha256sum < "$CADDYFILE")"; RUN0="$(sha256sum < "$TMP/run/caddy")"
  settle
}
edit_dangling_begin() { awk -v m="# BEGIN TWEBPROXY $C" '/^blog\.example \{/ {print m} {print}' "$CADDYFILE" > "$TMP/cf.edit" && mv "$TMP/cf.edit" "$CADDYFILE"; }
edit_altered_end() { sed -i "s/^# END TWEBPROXY $A\$/& /" "$CADDYFILE"; }
edit_duplicate_pair() { printf '\n# BEGIN TWEBPROXY %s\n# END TWEBPROXY %s\n' "$A" "$A" >> "$CADDYFILE"; }
edit_user_gamma() { printf '\nhttps://%s {\n\trespond "user gamma"\n}\n' "$C" >> "$CADDYFILE"; }
edit_invalid_rest() { printf '\nINVALID-USER-CONFIG\n' >> "$CADDYFILE"; }
caddy_same() { [[ "$(sha256sum < "$CADDYFILE")" == "$CF0" ]]; }
caddy_running_same() { [[ "$(sha256sum < "$TMP/run/caddy")" == "$RUN0" ]]; }
block_of() { awk -v h="$1" '$0 == "# BEGIN TWEBPROXY " h {p = 1} p {print} $0 == "# END TWEBPROXY " h {p = 0}' "$CADDYFILE"; }
blocks() { grep -cx "# BEGIN TWEBPROXY $1" "$CADDYFILE"; }
b_intact() { [[ "$(block_of "$B")" == "$(tpl_caddy_block "$B" 18082)" ]]; }
user_caddy_intact() { grep -qx 'shop.example {' "$CADDYFILE" && grep -qx 'blog.example {' "$CADDYFILE" &&
  grep -qx $'\temail admin@example.org' "$CADDYFILE" && grep -qx $'\trespond "user blog"' "$CADDYFILE"; }
no_caddy_reload() { ! grep -q '^systemctl reload caddy' "$TMP/events"; }

# 1. Add gamma: block appended once, everything else intact, reload only.
caddy_world; op configure_tls_for_instance "$C"; show
check caddy_add_ok test "$rc" -eq 0
check caddy_add_block_once test "$(blocks "$C")" -eq 1
check caddy_add_served d_served_caddy "$C"
check caddy_add_others_intact eval 'user_caddy_intact && b_intact && [[ "$(blocks "$A")" == 1 ]]'
check caddy_add_valid_no_restart eval 'd_caddy_valid && ! d_restarted caddy'
check caddy_add_dir_mode_kept test "$(stat -c %a "$CADDY_DIR")" = 750
# 2. Invalid candidate.
caddy_world; : > "$TMP/caddy-reject-$C"; op configure_tls_for_instance "$C"; show
check caddy_invalid_refused test "$rc" -ne 0
check caddy_invalid_file_unchanged caddy_same
check caddy_invalid_running_unchanged caddy_running_same
check caddy_invalid_no_reload no_caddy_reload
# 3. Failed reload: previous file back, Caddy still serving the previous config, no restart.
caddy_world; : > "$TMP/fail-reload-caddy"; op configure_tls_for_instance "$C"; show
check caddy_reload_fail_reported test "$rc" -ne 0
check caddy_reload_fail_file_restored caddy_same
check caddy_reload_fail_running_unchanged caddy_running_same
check caddy_reload_fail_no_restart not d_restarted caddy
check caddy_reload_fail_still_active "$TMP/bin/systemctl" is-active --quiet caddy
check caddy_reload_fail_no_debris no_frontend_debris
# 4. Write stopped half-way.
caddy_world; : > "$TMP/fail-frontend-write"; op configure_tls_for_instance "$C"; show
check caddy_partial_write_reported test "$rc" -ne 0
check caddy_partial_write_file_unchanged caddy_same
check caddy_partial_write_live_valid d_caddy_valid
check caddy_partial_write_no_debris no_frontend_debris
# 5. Ambiguous ownership is refused with the Caddyfile unchanged.
caddy_world edit_dangling_begin
op configure_tls_for_instance "$C"; show
check caddy_dangling_begin_refused test "$rc" -ne 0
check caddy_dangling_begin_file_unchanged caddy_same
check caddy_dangling_begin_user_site_kept grep -qx 'blog.example {' "$CADDYFILE"
caddy_world edit_altered_end
op configure_tls_for_instance "$A"; show
check caddy_altered_marker_refused test "$rc" -ne 0
check caddy_altered_marker_file_unchanged caddy_same
check caddy_altered_marker_other_block_and_user_kept eval 'b_intact && user_caddy_intact'
caddy_world edit_duplicate_pair
op configure_tls_for_instance "$A"
check caddy_duplicate_block_refused test "$rc" -ne 0
check caddy_duplicate_block_file_unchanged caddy_same
caddy_world edit_user_gamma
op configure_tls_for_instance "$C"
check caddy_user_defined_host_refused test "$rc" -ne 0
check caddy_user_defined_host_file_unchanged caddy_same
# 6. Re-apply alpha (the repair path): beta's block and the user sites stay byte-for-byte.
caddy_world; op configure_tls_for_instance "$A"
check caddy_reapply_ok test "$rc" -eq 0
check caddy_reapply_others_intact eval 'b_intact && user_caddy_intact && [[ "$(blocks "$A")" == 1 ]]'
check caddy_reapply_no_restart not d_restarted caddy
# 6b. Two instances published at the same time: neither block may be lost.
caddy_world; seed_host "$D" 3 caddy; settle
D_AT_VALIDATE=cv d_run configure_tls_for_instance "$C" > "$TMP/out1" 2>&1 & p1=$!
c1_wait_reached cv
d_run configure_tls_for_instance "$D" > "$TMP/out2" 2>&1 & p2=$!
for ((i = 0; i < 100; i++)); do kill -0 "$p2" 2>/dev/null || break; in_flock "$p2" && break; sleep 0.1; done
: > "$TMP/cv.go"; wait "$p1"; rc1=$?; wait "$p2"; rc2=$?
check caddy_concurrent_both_ok test "$rc1" -eq 0 -a "$rc2" -eq 0
check caddy_concurrent_no_block_lost eval '[[ "$(blocks "$C")" == 1 && "$(blocks "$D")" == 1 ]] && b_intact && user_caddy_intact'
check caddy_concurrent_valid_and_served eval 'd_caddy_valid && d_served_caddy "$C" && d_served_caddy "$D"'
# 7. Repair with a failed Caddy reload: reported, Caddyfile unchanged, no restart.
caddy_world; : > "$TMP/fail-reload-caddy"; op repair_instance_cmd "$A"; show
check caddy_repair_fail_reported test "$rc" -ne 0
check caddy_repair_fail_file_unchanged caddy_same
check caddy_repair_fail_running_unchanged caddy_running_same
check caddy_repair_fail_no_restart not d_restarted caddy
# 8. Interrupted (SIGTERM) while Caddy reloads a candidate it then rejects.
caddy_world; : > "$TMP/fail-reload-caddy"
D_AT_RELOAD="ci:caddy" d_run configure_tls_for_instance "$C" > "$TMP/out" 2>&1 & p=$!
c1_wait_reached ci; kill -TERM "$(cat "$TMP/ci.pid")" 2>/dev/null; : > "$TMP/ci.go"; wait "$p"; rc=$?; show
check caddy_interrupted_reported test "$rc" -ne 0
check caddy_interrupted_file_restored caddy_same
check caddy_interrupted_valid_no_restart eval 'd_caddy_valid && ! d_restarted caddy'
# 9. Delete with a failed reload: nothing deleted, the instance keeps serving.
caddy_world; : > "$TMP/fail-reload-caddy"; op delete_instance_cmd "$A"; show
check caddy_delete_fail_reported test "$rc" -ne 0
check caddy_delete_fail_instance_kept instance_kept "$A"
check caddy_delete_fail_file_unchanged caddy_same
check caddy_delete_fail_no_success not grep -q "$A was deleted" "$TMP/out"
caddy_world '' edit_invalid_rest
op delete_instance_cmd "$A"; show
check caddy_delete_invalid_rest_refused test "$rc" -ne 0
check caddy_delete_invalid_rest_instance_kept instance_kept "$A"
check caddy_delete_invalid_rest_file_unchanged caddy_same
# 10. Delete succeeds: only alpha's block goes.
caddy_world; op delete_instance_cmd "$A"; show
check caddy_delete_ok test "$rc" -eq 0 -a ! -e "$INSTANCES_DIR/$A"
check caddy_delete_block_removed test "$(blocks "$A")" -eq 0
check caddy_delete_others_intact eval 'b_intact && user_caddy_intact'
check caddy_delete_served eval '! d_served_caddy "$A" && d_served_caddy "$B" && d_served_caddy "$U"'
check caddy_delete_no_restart not d_restarted caddy

# ---------- Nginx world: user vhost + LE alpha + custom beta + an unrelated LE lineage ----------
nginx_world() { # [$1=days left on alpha's certificate]
  reset
  seed_host "$A" 0 nginx-le admin@example.org
  d_make_cert "$TMP/custom/$B/fullchain.pem" "$TMP/custom/$B/privkey.pem" "$B"
  seed_host "$B" 1 nginx-custom "$TMP/custom/$B/fullchain.pem" "$TMP/custom/$B/privkey.pem"
  "$TMP/bin/d-le-issue" "$A" "${1:-60}"; "$TMP/bin/d-le-issue" "$O" 60
  d_make_cert "$TMP/user-certs/shop.pem" "$TMP/user-certs/shop.key" "$U"
  printf 'map $http_upgrade $twebproxy_connection_upgrade {\n    default upgrade;\n    %s      close;\n}\n' "''" > "$NGINX_DIR/conf.d/twebproxy-map.conf"
  tpl_nginx_tls "$A" 18080 "$LE_DIR/live/$A/fullchain.pem" "$LE_DIR/live/$A/privkey.pem" > "$NGINX_DIR/sites-available/twebproxy-$A.conf"
  tpl_nginx_tls "$B" 18082 "$TMP/custom/$B/fullchain.pem" "$TMP/custom/$B/privkey.pem" > "$NGINX_DIR/sites-available/twebproxy-$B.conf"
  printf 'server {\n    listen 443 ssl;\n    server_name %s;\n    ssl_certificate %s;\n    ssl_certificate_key %s;\n    root /srv/shop;\n}\n' \
    "$U" "$TMP/user-certs/shop.pem" "$TMP/user-certs/shop.key" > "$NGINX_DIR/sites-available/shop.conf"
  for f in "twebproxy-$A.conf" "twebproxy-$B.conf" shop.conf; do ln -s "$NGINX_DIR/sites-available/$f" "$NGINX_DIR/sites-enabled/$f"; done
  chmod 0750 "$NGINX_DIR/conf.d"
  "$TMP/bin/systemctl" start nginx >/dev/null 2>&1
  NG0="$(d_tree_sum "$NGINX_DIR")"; LE0="$(d_tree_sum "$LE_DIR/live")$(d_tree_sum "$LE_DIR/archive")"
  LO0="$(d_tree_sum "$LE_DIR/live/$O")$(d_tree_sum "$LE_DIR/archive/$O")"
  SA0="$(d_served_nginx_cert "$A")"; SB0="$(d_served_nginx_cert "$B")"; SU0="$(d_served_nginx_cert "$U")"
  settle
}
nginx_same() { [[ "$(d_tree_sum "$NGINX_DIR")" == "$NG0" ]]; }
le_same() { [[ "$(d_tree_sum "$LE_DIR/live")$(d_tree_sum "$LE_DIR/archive")" == "$LE0" ]]; }
others_served() { [[ "$(d_served_nginx_cert "$B")" == "$SB0" && "$(d_served_nginx_cert "$U")" == "$SU0" ]]; }
no_managed() { [[ ! -e "$NGINX_DIR/sites-available/twebproxy-$1.conf" && ! -L "$NGINX_DIR/sites-enabled/twebproxy-$1.conf" ]]; }
custom_gamma() { # $1=mismatched key? : gamma with a custom certificate, not yet configured
  d_make_cert "$TMP/custom/$C/fullchain.pem" "$TMP/custom/$C/privkey.pem" "$C"
  [[ -z "${1:-}" ]] || d_make_cert "$TMP/custom/$C/other.pem" "$TMP/custom/$C/privkey.pem" "$C"
  seed_host "$C" 2 nginx-custom "$TMP/custom/$C/fullchain.pem" "$TMP/custom/$C/privkey.pem"; settle
  NG0="$(d_tree_sum "$NGINX_DIR")"; RN0="$(sha256sum < "$TMP/run/nginx")"
}
nginx_running_same() { [[ "$(sha256sum < "$TMP/run/nginx")" == "$RN0" ]]; }

# 11. Custom-certificate hostname added next to the others.
nginx_world; custom_gamma; op configure_tls_for_instance "$C"; show
check nginx_custom_add_ok test "$rc" -eq 0
check nginx_custom_add_served d_served_nginx "$C"
check nginx_custom_add_others_unchanged eval 'others_served && [[ "$(d_served_nginx_cert "$A")" == "$SA0" ]]'
check nginx_custom_add_dir_mode_kept test "$(stat -c %a "$NGINX_DIR/conf.d")" = 750
# 12. Candidate rejected by nginx -t.
nginx_world; custom_gamma; : > "$TMP/nginx-reject-tls-$C"; op configure_tls_for_instance "$C"; show
check nginx_invalid_refused test "$rc" -ne 0
check nginx_invalid_nothing_left no_managed "$C"
check nginx_invalid_disk_valid d_nginx_valid
check nginx_invalid_running_unchanged nginx_running_same
# 13. Key that does not belong to the certificate.
nginx_world; custom_gamma mismatch; op configure_tls_for_instance "$C"; show
check nginx_key_mismatch_refused test "$rc" -ne 0
check nginx_key_mismatch_nothing_left no_managed "$C"
check nginx_key_mismatch_disk_valid d_nginx_valid
# 14. Failed reload: the new vhost is taken back.
nginx_world; custom_gamma; : > "$TMP/fail-reload-nginx"; op configure_tls_for_instance "$C"; show
check nginx_reload_fail_reported test "$rc" -ne 0
check nginx_reload_fail_restored no_managed "$C"
check nginx_reload_fail_disk_valid d_nginx_valid
check nginx_reload_fail_running_unchanged nginx_running_same
# 15. Write stopped half-way while re-applying beta.
nginx_world; : > "$TMP/fail-frontend-write"; op configure_tls_for_instance "$B"; show
check nginx_partial_write_reported test "$rc" -ne 0
check nginx_partial_write_files_unchanged nginx_same
check nginx_partial_write_disk_valid d_nginx_valid
check nginx_partial_write_no_debris no_frontend_debris
# 16. Repair of a working LE hostname: HTTPS is never taken away.
nginx_world; op configure_tls_for_instance "$A"; show
check nginx_le_reapply_ok test "$rc" -eq 0
check nginx_le_reapply_https_never_lost d_https_never_lost "$A"
check nginx_le_reapply_same_cert test "$(d_served_nginx_cert "$A")" = "$SA0"
check nginx_le_reapply_certs_unchanged le_same
# 17. Renewal due, certbot fails: the still valid certificate stays in service.
nginx_world 10; : > "$TMP/fail-certbot-issue-$A"; op configure_tls_for_instance "$A"; show
check nginx_le_certbot_fail_https_never_lost d_https_never_lost "$A"
check nginx_le_certbot_fail_same_cert test "$(d_served_nginx_cert "$A")" = "$SA0"
check nginx_le_certbot_fail_certs_unchanged le_same
check nginx_le_certbot_fail_warned grep -q 'Certbot' "$TMP/out"
# 18. First issuance fails: nothing is left behind.
nginx_world; seed_host "$C" 2 nginx-le admin@example.org; settle; NG0="$(d_tree_sum "$NGINX_DIR")"
: > "$TMP/fail-certbot-issue-$C"; op configure_tls_for_instance "$C"; show
check nginx_le_issue_fail_reported test "$rc" -ne 0
check nginx_le_issue_fail_nothing_left no_managed "$C"
check nginx_le_issue_fail_disk_valid d_nginx_valid
check nginx_le_issue_fail_certs_unchanged le_same
check nginx_le_issue_fail_others_served eval 'others_served && [[ "$(d_served_nginx_cert "$A")" == "$SA0" ]]'
# 19. First issuance succeeds.
nginx_world; seed_host "$C" 2 nginx-le admin@example.org; settle; op configure_tls_for_instance "$C"; show
check nginx_le_issue_ok test "$rc" -eq 0
check nginx_le_issue_served d_served_nginx "$C"
check nginx_le_issue_hook_installed test -x "$LE_DIR/renewal-hooks/deploy/twebproxy-nginx-reload"
check nginx_le_issue_other_lineage_unchanged eval '[[ "$(d_tree_sum "$LE_DIR/live/$O")$(d_tree_sum "$LE_DIR/archive/$O")" == "$LO0" ]]'
# 20-22. cert-renew.
nginx_world 10; : > "$TMP/fail-certbot-renew-$A"; op cert_renew_cmd "$A"; show
check renew_fail_reported test "$rc" -ne 0
check renew_fail_certs_unchanged le_same
check renew_fail_still_served test "$(d_served_nginx_cert "$A")" = "$SA0"
check renew_fail_says_kept grep -qiE 'previous certificate|kept' "$TMP/out"
nginx_world 10; op cert_renew_cmd "$A"; show
check renew_ok test "$rc" -eq 0
check renew_ok_new_cert_served eval '[[ "$(d_served_nginx_cert "$A")" == "$(sha256sum < "$LE_DIR/live/$A/fullchain.pem" | cut -c1-16)" && "$(d_served_nginx_cert "$A")" != "$SA0" ]]'
nginx_world 10; : > "$TMP/fail-nginx-t"; op cert_renew_cmd "$A"; show
check renew_nginx_test_fail_reported test "$rc" -ne 0
check renew_nginx_test_fail_old_cert_served test "$(d_served_nginx_cert "$A")" = "$SA0"
check renew_nginx_test_fail_explained grep -qiE 'previous certificate' "$TMP/out"
# 23. Delete while Nginx without the vhost fails nginx -t: nothing deleted, still serving.
nginx_world; printf 'INVALID-USER-CONFIG;\n' >> "$NGINX_DIR/sites-available/shop.conf"; NG0="$(d_tree_sum "$NGINX_DIR")"
op delete_instance_cmd "$A"; show
check nginx_delete_fail_reported test "$rc" -ne 0
check nginx_delete_fail_instance_kept instance_kept "$A"
check nginx_delete_fail_files_restored nginx_same
check nginx_delete_fail_still_served test "$(d_served_nginx_cert "$A")" = "$SA0"
check nginx_delete_fail_no_success not grep -q "$A was deleted" "$TMP/out"
# 24. Delete succeeds: only alpha's vhost goes; certificates stay.
nginx_world; op delete_instance_cmd "$A"; show
check nginx_delete_ok test "$rc" -eq 0 -a ! -e "$INSTANCES_DIR/$A"
check nginx_delete_vhost_removed no_managed "$A"
check nginx_delete_not_served not d_served_nginx "$A"
check nginx_delete_others_served others_served
check nginx_delete_certs_kept le_same
# 25. Interrupted (SIGTERM) during nginx -t of a candidate it rejects.
nginx_world; custom_gamma; : > "$TMP/nginx-reject-tls-$C"
D_AT_NGINX_T=ni d_run configure_tls_for_instance "$C" > "$TMP/out" 2>&1 & p=$!
c1_wait_reached ni; kill -TERM "$(cat "$TMP/ni.pid")" 2>/dev/null; : > "$TMP/ni.go"; wait "$p"; rc=$?; show
check nginx_interrupted_reported test "$rc" -ne 0
check nginx_interrupted_nothing_left no_managed "$C"
check nginx_interrupted_disk_valid d_nginx_valid
# 26. A certificate path that would inject configuration is refused.
nginx_world; d_make_cert "$TMP/custom/evil;x.pem" "$TMP/custom/evil.key" "$C"
seed_host "$C" 2 nginx-custom "$TMP/custom/evil;x.pem" "$TMP/custom/evil.key"; settle
op configure_tls_for_instance "$C"; show
check nginx_unsafe_path_refused test "$rc" -ne 0
check nginx_unsafe_path_nothing_written no_managed "$C"

# ---------- Instance creation through add (D3) ----------
caddy_world; D_TLS=1 C1_HOST="$D" C1_NAME=main op add_instance_cmd; show
check add_caddy_ok test "$rc" -eq 0
check add_caddy_served d_served_caddy "$D"
check add_caddy_others_intact eval 'b_intact && user_caddy_intact'
nginx_world; d_make_cert "$TMP/custom/$D/fullchain.pem" "$TMP/custom/$D/privkey.pem" "$D"
d_make_cert "$TMP/custom/$D/other.pem" "$TMP/custom/$D/privkey.pem" "$D"; NG0="$(d_tree_sum "$NGINX_DIR")"
D_TLS=3 D_CERT="$TMP/custom/$D/fullchain.pem" D_KEY="$TMP/custom/$D/privkey.pem" C1_HOST="$D" C1_NAME=main op add_instance_cmd; show
check add_nginx_bad_key_reported test "$rc" -ne 0
check add_nginx_bad_key_nothing_left no_managed "$D"
check add_nginx_bad_key_disk_valid d_nginx_valid
check add_nginx_bad_key_others_served others_served

printf 'd-frontend-tls: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
