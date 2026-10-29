#!/usr/bin/env bash
# Behavioral sandbox for the Stage D frontend (Caddy / Nginx) and TLS lifecycle.
#
# Extends tests/stagec2/relay-harness.sh (same rules: unmodified manager code,
# commands run through d_run/d_eval in a separate bash process with production
# `set -Eeuo pipefail`, nothing outside $TMP is read or written). The frontend
# locations are rebound into $TMP through CADDY_DIR/CADDYFILE/NGINX_DIR/LE_DIR/
# ACME_WEBROOT; a manager whose frontend functions still name the real paths is
# refused. Host-boundary models in $TMP/bin:
#   caddy    validate (braces, duplicate site addresses, injected rejection), fmt
#   nginx    -t over conf.d/*.conf and sites-enabled/* (dangling links, braces,
#            certificate files, key/certificate match with real openssl)
#   certbot  certonly/renew into an $LE_DIR lineage (real self-signed certs);
#            HTTP-01 succeeds only if the RUNNING Nginx serves the challenge
#   systemctl  caddy/nginx units: start/reload activate the on-disk config only
#            if it is valid and keep a snapshot of what is running; a failed
#            Caddy reload keeps the previous config, an Nginx reload of an
#            invalid config is a no-op (as nginx -s reload); restarts are logged
# This proves control flow and file/served-state postconditions, not real
# Caddy, Nginx, certbot or systemd behaviour.
#
# Faults (files in $TMP): fail-caddy-validate, caddy-reject-<site>,
# fail-nginx-t, nginx-reject-tls-<host>, fail-reload-<caddy|nginx>,
# fail-start-<caddy|nginx>, fail-certbot-issue-<host>, fail-certbot-renew-<host>,
# fail-frontend-write (the next write of file content into the frontend
# directories stops half-way and fails).
# Barriers (name.reached / name.go, manager pid in name.pid):
#   D_AT_VALIDATE=<name>           first `caddy validate`
#   D_AT_NGINX_T=<name>            first `nginx -t`
#   D_AT_RELOAD=<name>:<unit>      first reload of caddy|nginx

D_HARNESS="${BASH_SOURCE[0]}"
# shellcheck source=/dev/null
source "$(dirname "$D_HARNESS")/../stagec2/relay-harness.sh"

D_FRONTEND_FUNCS=(configure_tls_for_instance remove_reverse_proxy_for_instance configure_caddy_host
  remove_caddy_block nginx_common_install nginx_domain_conflict write_nginx_tls_conf render_nginx_tls_conf
  configure_nginx_le configure_nginx_custom install_nginx_certbot_deploy_hook cert_renew_cmd
  caddy_publish caddy_remove_host frontend_file_replace nginx_managed_apply nginx_managed_remove
  nginx_managed_restore nginx_link_enable le_cert_usable render_nginx_acme_conf)

d_harness() {
  export D_HARNESS
  c2_harness
  export D_MANAGER_PID=$$ D_ROOT="$TMP"
  CADDY_DIR="$TMP/caddy"; CADDYFILE="$CADDY_DIR/Caddyfile"; NGINX_DIR="$TMP/nginx"
  LE_DIR="$TMP/letsencrypt"; ACME_WEBROOT="$TMP/acme"
  export D_CADDYFILE="$CADDYFILE" D_NGINX_DIR="$NGINX_DIR" D_LE_DIR="$LE_DIR"
  if [[ ! -e "$TMP/bin/.d-models" ]]; then
    install -d -m 0755 "$CADDY_DIR" "$NGINX_DIR/conf.d" "$NGINX_DIR/sites-available" "$NGINX_DIR/sites-enabled" \
      "$LE_DIR/live" "$LE_DIR/archive" "$TMP/run"
    d_write_models
    : > "$TMP/bin/.d-models"
  fi
  # Stage D exercises the real frontend code that the C1 stubs replace.
  eval "$(TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 bash -c 'source "$1" >/dev/null 2>&1; trap - ERR
    declare -f configure_tls_for_instance remove_reverse_proxy_for_instance check_frontend_compatibility' _ "$MGR")"
  local leak
  leak="$(declare -f "${D_FRONTEND_FUNCS[@]}" 2>/dev/null | grep -nE '/etc/(caddy|nginx|letsencrypt)|/var/lib/twebproxy/acme' || true)"
  if [[ -n "$leak" ]]; then
    printf 'REFUSED: frontend functions of %s name real frontend paths:\n%s\n' "$MGR" "$leak" >&2
    exit 2
  fi
  check_dns_for_host() { return 0; }
  cert_status_impl() { printf 'cert status %s\n' "$1"; }
  fetch_public_leaf_cert() { return 1; }
  configure_ufw() { :; }
  d_answers
  d_faults
}

d_run() { bash -c 'source "$D_HARNESS"; d_harness; set -Eeuo pipefail; "$@"' d-run "$@"; }
d_eval() { bash -c 'source "$D_HARNESS"; d_harness; set -Eeuo pipefail; eval "$1"' d-eval "$1"; }

# TLS prompts of add_instance_cmd: D_TLS (1 caddy, 2 nginx-le, 3 nginx-custom,
# 4 manual), D_EMAIL, D_CERT, D_KEY. Everything else answers as in C1.
d_answers() {
  eval "d_c1_ask() $(declare -f ask | tail -n +2)"
  eval "d_c1_choose() $(declare -f choose | tail -n +2)"
  ask() {
    case "$1" in
      'Email для Let’s Encrypt') printf '%s' "${D_EMAIL:-admin@example.org}";;
      'Путь к fullchain.pem') printf '%s' "${D_CERT:-}";;
      'Путь к privkey.pem') printf '%s' "${D_KEY:-}";;
      *) d_c1_ask "$@";;
    esac
  }
  choose() { if [[ "$1" == 'SSL / reverse proxy:' ]]; then printf '%s' "${D_TLS:-4}"; else d_c1_choose "$@"; fi; }
}

# fail-frontend-write: the next `cat` whose output goes into a frontend
# directory writes 40 bytes and fails (a write stopped half-way, e.g. ENOSPC).
d_faults() {
  cat() {
    if [[ -e "$TMP/fail-frontend-write" ]]; then
      local me=$BASHPID out
      out="$(readlink -f "/proc/$me/fd/1" 2>/dev/null)"
      case "$out" in
        "$CADDY_DIR"/*|"$NGINX_DIR"/*|"$LE_DIR"/*)
          rm -f "$TMP/fail-frontend-write"
          command cat "$@" | head -c 40
          printf 'model: write to %s interrupted\n' "$out" >&2
          return 1;;
      esac
    fi
    command cat "$@"
  }
}

d_write_models() {
  cat > "$TMP/bin/d-barrier" <<'SH'
#!/bin/bash
# $1=barrier name: park until <name>.go (once per name)
[[ -n "$1" && ! -e "$D_ROOT/$1.reached" ]] || exit 0
echo "$D_MANAGER_PID" > "$D_ROOT/$1.pid"; : > "$D_ROOT/$1.reached"
for ((i = 0; i < 600; i++)); do [[ -e "$D_ROOT/$1.go" ]] && exit 0; sleep 0.05; done
exit 0
SH
  cat > "$TMP/bin/caddy-check" <<'SH'
#!/bin/bash
f="$1"
[[ -f "$f" ]] || { echo "model caddy: no such file $f" >&2; exit 1; }
[[ ! -e "$D_ROOT/fail-caddy-validate" ]] || { echo 'model caddy: injected validation failure' >&2; exit 1; }
! grep -q 'INVALID-USER-CONFIG' "$f" || { echo 'model caddy: unrecognized directive INVALID-USER-CONFIG' >&2; exit 1; }
awk -v root="$D_ROOT" '
  { line = $0; sub(/#.*/, "", line); o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line)
    if (depth == 0 && o > 0) {
      addr = line; sub(/\{.*/, "", addr); n = split(addr, a, /[ ,\t]+/)
      for (i = 1; i <= n; i++) if (a[i] != "") {
        s = a[i]; sub(/^https?:\/\//, "", s); sub(/:443$/, "", s)
        if (seen[s]++) dup = dup " " s
        sites[s] = 1
      }
    }
    depth += o - c; if (depth < 0) neg = 1 }
  END {
    if (neg || depth != 0) { print "model caddy: unbalanced braces" > "/dev/stderr"; exit 1 }
    if (dup != "") { print "model caddy: ambiguous site definition:" dup > "/dev/stderr"; exit 1 }
    for (s in sites) if ((getline x < (root "/caddy-reject-" s)) >= 0) { print "model caddy: site " s " rejected" > "/dev/stderr"; exit 1 }
  }' "$f"
SH
  cat > "$TMP/bin/caddy" <<'SH'
#!/bin/bash
printf 'caddy %s\n' "$*" >> "$D_ROOT/events"
case "$1" in
  validate) cfg=""; while (( $# )); do [[ "$1" == --config ]] && { cfg="$2"; shift; }; shift; done
            "$D_ROOT/bin/d-barrier" "${D_AT_VALIDATE:-}"
            exec "$D_ROOT/bin/caddy-check" "$cfg";;
  version) echo 'v2.0.0 model';;
esac
exit 0
SH
  cat > "$TMP/bin/nginx-check" <<'SH'
#!/bin/bash
shopt -s nullglob
rc=0
for f in "$D_NGINX_DIR"/conf.d/*.conf "$D_NGINX_DIR"/sites-enabled/*; do
  [[ -e "$f" ]] || { echo "nginx: [emerg] open() \"$f\" failed (2: No such file or directory)" >&2; rc=1; continue; }
  ! grep -q 'INVALID-USER-CONFIG' "$f" || { echo "nginx: [emerg] unknown directive \"INVALID-USER-CONFIG\" in $f" >&2; rc=1; }
  o=$(tr -cd '{' < "$f" | wc -c); c=$(tr -cd '}' < "$f" | wc -c)
  last=$(tr -d ' \t\n\r' < "$f" | tail -c 1)
  (( o == c )) && [[ -z "$last" || "$last" == '}' || "$last" == ';' ]] ||
    { echo "nginx: [emerg] unexpected end of file in $f" >&2; rc=1; }
  cert=$(sed -n 's/^[[:space:]]*ssl_certificate[[:space:]]\+\([^;]*\);.*/\1/p' "$f" | head -n 1)
  key=$(sed -n 's/^[[:space:]]*ssl_certificate_key[[:space:]]\+\([^;]*\);.*/\1/p' "$f" | head -n 1)
  [[ -n "$cert$key" ]] || continue
  if [[ ! -r "$cert" || ! -r "$key" ]]; then
    echo "nginx: [emerg] cannot load certificate \"$cert\"" >&2; rc=1
  elif [[ "$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | sha256sum)" != "$(openssl pkey -in "$key" -pubout 2>/dev/null | sha256sum)" ]]; then
    echo "nginx: [emerg] SSL_CTX_use_PrivateKey(\"$key\") failed (key values mismatch)" >&2; rc=1
  fi
  for h in $(sed -n 's/^[[:space:]]*server_name[[:space:]]\+\([^;]*\);.*/\1/p' "$f"); do
    [[ ! -e "$D_ROOT/nginx-reject-tls-$h" ]] || { echo "nginx: [emerg] model: TLS server $h rejected" >&2; rc=1; }
  done
done
(( rc )) && echo 'nginx: configuration file test failed' >&2 || echo 'nginx: configuration file test is successful' >&2
exit "$rc"
SH
  cat > "$TMP/bin/nginx" <<'SH'
#!/bin/bash
printf 'nginx %s\n' "$*" >> "$D_ROOT/events"
[[ "${1:-}" == -t ]] || exit 0
"$D_ROOT/bin/d-barrier" "${D_AT_NGINX_T:-}"
[[ ! -e "$D_ROOT/fail-nginx-t" ]] || { echo 'nginx: [emerg] model: injected test failure' >&2; exit 1; }
exec "$D_ROOT/bin/nginx-check"
SH
  cat > "$TMP/bin/d-le-issue" <<'SH'
#!/bin/bash
# $1=lineage name $2=validity days: new certificate in the lineage (real openssl)
name="$1" days="${2:-90}" d="$D_LE_DIR/archive/$1" live="$D_LE_DIR/live/$1"
install -d -m 0700 "$d"; install -d -m 0755 "$live"
n=$(( $(find "$d" -name 'cert*.pem' | wc -l) + 1 ))
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days "$days" -subj "/CN=$name" \
  -keyout "$d/privkey$n.pem" -out "$d/cert$n.pem" >/dev/null 2>&1 || exit 1
cp "$d/cert$n.pem" "$d/fullchain$n.pem"; cp "$d/cert$n.pem" "$d/chain$n.pem"
for k in cert chain fullchain privkey; do ln -sfn "../../archive/$name/$k$n.pem" "$live/$k.pem"; done
install -d -m 0755 "$D_LE_DIR/renewal"; printf 'cert = %s\n' "$live/cert.pem" > "$D_LE_DIR/renewal/$name.conf"
SH
  cat > "$TMP/bin/certbot" <<'SH'
#!/bin/bash
printf 'certbot %s\n' "$*" >> "$D_ROOT/events"
sub="$1"; shift; name="" dry=0 force=0 keep=0
while (( $# )); do case "$1" in
  --cert-name) name="$2"; shift;; -d) [[ -n "$name" ]] || name="$2"; shift;;
  --dry-run) dry=1;; --force-renewal) force=1;; --keep-until-expiring) keep=1;; esac; shift; done
live="$D_LE_DIR/live/$name"
due() { local end; end="$(openssl x509 -in "$live/cert.pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  [[ -z "$end" ]] || (( $(date -d "$end" +%s) - $(date +%s) < 30 * 86400 )); }
challenge_served() { # the RUNNING Nginx answers HTTP-01 for $name
  awk -v h="$name" '/^### /{ if (n && a) ok = 1; n = 0; a = 0; next }
    $0 ~ ("server_name[ \t]+" h ";") { n = 1 } /acme-challenge/ { a = 1 }
    END { if (n && a) ok = 1; exit !ok }' "$D_ROOT/run/nginx" 2>/dev/null; }
case "$sub" in
  certonly)
    [[ ! -e "$D_ROOT/fail-certbot-issue-$name" ]] || { echo "model certbot: issuance for $name failed" >&2; exit 1; }
    if (( keep )) && [[ -e "$live/cert.pem" ]] && ! due; then echo 'Certificate not yet due for renewal; no action taken.'; exit 0; fi
    challenge_served || { echo "model certbot: HTTP-01 challenge for $name not served" >&2; exit 1; }
    "$D_ROOT/bin/d-le-issue" "$name" "${D_ISSUE_DAYS:-90}" || exit 1
    echo 'Successfully received certificate.';;
  renew)
    [[ -e "$live/cert.pem" ]] || { echo "No certificate found with name $name" >&2; exit 1; }
    [[ ! -e "$D_ROOT/fail-certbot-renew-$name" ]] || { echo "model certbot: renewal of $name failed" >&2; exit 1; }
    (( dry )) && { echo 'The dry run was successful.'; exit 0; }
    if (( ! force )) && ! due; then echo 'No renewals were attempted.'; exit 0; fi
    challenge_served || { echo "model certbot: HTTP-01 challenge for $name not served" >&2; exit 1; }
    "$D_ROOT/bin/d-le-issue" "$name" "${D_ISSUE_DAYS:-90}" || exit 1
    for h in "$D_LE_DIR"/renewal-hooks/deploy/*; do [[ -x "$h" ]] && RENEWED_LINEAGE="$live" "$h"; done
    echo 'Congratulations, all renewals succeeded.';;
esac
exit 0
SH
  cat > "$TMP/bin/apt-get" <<'SH'
#!/bin/bash
printf 'apt-get %s\n' "$*" >> "$D_ROOT/events"
exit 0
SH
  cat > "$TMP/bin/ufw" <<'SH'
#!/bin/bash
exit 1
SH
  # ss: public listener queries (sport = :80/:443) answer from $TMP/ss-public.
  mv "$TMP/bin/ss" "$TMP/bin/ss-c1"
  cat > "$TMP/bin/ss" <<'SH'
#!/bin/bash
case "$*" in *'sport = :80'*|*'sport = :443'*) cat "$D_ROOT/ss-public" 2>/dev/null; exit 0;; esac
exec "$(dirname "$0")/ss-c1" "$@"
SH
  # systemctl: caddy/nginx units here, everything else to the C2/C1 models.
  mv "$TMP/bin/systemctl" "$TMP/bin/systemctl-c2"
  cat > "$TMP/bin/systemctl" <<'SH'
#!/bin/bash
args=("$@"); unit="${args[-1]}"; u="${unit%.service}"
case "$u" in caddy|nginx) ;; *) exec "$(dirname "$0")/systemctl-c2" "$@";; esac
printf '%s\n' "$*" >> "$D_ROOT/systemctl.calls"
printf 'systemctl %s\n' "$*" >> "$D_ROOT/events"
quiet=0; [[ "${2:-}" == --quiet ]] && quiet=1
run="$D_ROOT/run"
valid() { if [[ "$u" == caddy ]]; then "$D_ROOT/bin/caddy-check" "$D_CADDYFILE" 2>> "$D_ROOT/frontend.log"
          else "$D_ROOT/bin/nginx-check" 2>> "$D_ROOT/frontend.log"; fi; }
snapshot() { # what the unit serves from now on
  if [[ "$u" == caddy ]]; then cp "$D_CADDYFILE" "$run/caddy"; return; fi
  local f c h
  : > "$run/nginx.new"
  for f in "$D_NGINX_DIR"/conf.d/*.conf "$D_NGINX_DIR"/sites-enabled/*; do
    [[ -e "$f" ]] || continue
    printf '### %s\n' "${f##*/}" >> "$run/nginx.new"; cat "$f" >> "$run/nginx.new"
    c=$(sed -n 's/^[[:space:]]*ssl_certificate[[:space:]]\+\([^;]*\);.*/\1/p' "$f" | head -n 1)
    [[ -n "$c" ]] || continue
    for h in $(sed -n 's/^[[:space:]]*server_name[[:space:]]\+\([^;]*\);.*/\1/p' "$f" | tr ' ' '\n' | sort -u); do
      printf 'SERVED %s %s\n' "$h" "$(sha256sum < "$c" | cut -c1-16)" >> "$run/nginx.new"
    done
  done
  mv "$run/nginx.new" "$run/nginx"
  { echo '=== activation'; grep '^SERVED ' "$run/nginx"; } >> "$run/nginx.history"
}
start() {
  [[ ! -e "$D_ROOT/fail-start-$u" ]] || { echo "model: start of $u failed" >&2; exit 1; }
  if valid; then snapshot; : > "$run/$u.active"; echo "ACTIVATED $u" >> "$D_ROOT/events"; exit 0; fi
  rm -f "$run/$u.active" "$run/$u"; echo "model: $u failed to start (invalid configuration)" >&2; exit 1
}
case "$1" in
  is-active) if [[ -e "$run/$u.active" ]]; then (( quiet )) || echo active; exit 0; fi; (( quiet )) || echo inactive; exit 3;;
  enable) [[ "${2:-}" == --now ]] || exit 0; [[ -e "$run/$u.active" ]] && exit 0; start;;
  start) [[ -e "$run/$u.active" ]] && exit 0; start;;
  restart) echo "RESTART $u" >> "$D_ROOT/events"; rm -f "$run/$u.active" "$run/$u"; start;;
  reload)
    [[ -z "${D_AT_RELOAD:-}" || "${D_AT_RELOAD#*:}" != "$u" ]] || "$D_ROOT/bin/d-barrier" "${D_AT_RELOAD%%:*}"
    [[ ! -e "$D_ROOT/fail-reload-$u" ]] || { echo "model: reload of $u failed" >&2; exit 1; }
    [[ -e "$run/$u.active" ]] || { echo "model: $u.service is not active, cannot reload" >&2; exit 1; }
    if valid; then snapshot; echo "ACTIVATED $u" >> "$D_ROOT/events"; exit 0; fi
    [[ "$u" == nginx ]] && exit 0     # nginx -s reload: the master keeps its old configuration
    echo 'model: caddy reload: configuration rejected' >&2; exit 1;;
  stop|disable) rm -f "$run/$u.active" "$run/$u"; echo "STOP $u" >> "$D_ROOT/events"; exit 0;;
  *) exit 0;;
esac
SH
  chmod 0755 "$TMP"/bin/*
}

# ---- seeding and assertion helpers (fixture side) ----
d_seed_instance() { # $1=host $2=relay $3=admin $4=tls mode [$5=email|cert] [$6=key]
  local email="" cert="" key=""
  case "$4" in nginx-le) email="${5:-admin@example.org}";; nginx-custom) cert="$5"; key="$6";; esac
  install -d -m 0700 "$INSTANCES_DIR/$1" "$INSTANCES_DIR/$1/profiles.d"
  {
    printf 'HOSTNAME=%q\nRELAY_PORT=%q\nADMIN_PORT=%q\nTLS_MODE=%q\nSITE_MODE=%q\n' "$1" "$2" "$3" "$4" placeholder
    printf 'SITE_UPSTREAM=%q\nSOURCE_SITE_DIR=%q\nACME_EMAIL=%q\nNGINX_CERT=%q\nNGINX_KEY=%q\n' '' '' "$email" "$cert" "$key"
    printf 'CREATED_AT=%q\n' 2026-01-01T00:00:00+00:00
  } > "$INSTANCES_DIR/$1/instance.env"
  chmod 0600 "$INSTANCES_DIR/$1/instance.env"
  printf '{"public_hostname":"%s"}\n' "$1" > "$INSTANCES_DIR/$1/config.json"
}
d_make_cert() { # $1=cert $2=key $3=CN [$4=days]: self-signed pair (real openssl)
  install -d -m 0700 "$(dirname "$1")" "$(dirname "$2")"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days "${4:-90}" -subj "/CN=$3" \
    -keyout "$2" -out "$1" >/dev/null 2>&1 && chmod 0600 "$2"
}
d_tree_sum() { # content and link targets of a directory tree, for "unchanged" checks
  (cd "$1" 2>/dev/null && find . \( -type f -o -type l \) -printf '%p %l\n' | LC_ALL=C sort | while read -r p l; do
    if [[ -L "$p" ]]; then printf '%s -> %s\n' "$p" "$l"; else printf '%s %s\n' "$p" "$(sha256sum < "$p" | cut -c1-16)"; fi
  done) | sha256sum | cut -c1-16
}
d_caddy_valid() { "$TMP/bin/caddy-check" "$CADDYFILE" 2>/dev/null; }
d_nginx_valid() { "$TMP/bin/nginx-check" 2>/dev/null; }
d_served_caddy() { grep -qE "^[[:space:]]*$(sed 's/\./\\./g' <<<"$1")[[:space:]]*\{" "$TMP/run/caddy" 2>/dev/null; }   # $1=site
d_served_nginx() { grep -q "^SERVED $1 " "$TMP/run/nginx" 2>/dev/null; }                                          # $1=host (HTTPS)
d_served_nginx_cert() { sed -n "s/^SERVED $1 //p" "$TMP/run/nginx" 2>/dev/null; }
d_restarted() { grep -q "^RESTART $1" "$TMP/events"; }
d_https_never_lost() { # $1=host: every Nginx activation since the last reset served it over HTTPS
  awk -v h="$1" '/^=== activation/ { if (n++ && !s) bad = 1; s = 0; next } $1 == "SERVED" && $2 == h { s = 1 }
    END { if (n && !s) bad = 1; exit bad }' "$TMP/run/nginx.history" 2>/dev/null
}
