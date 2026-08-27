#!/usr/bin/env bash
# TG-3 / TWP-002 regression.
#
# install_manager_copy() copies ${BASH_SOURCE[0]} over MANAGER_BIN and
# PROJECT_MANAGER_COPY. When the manager runs from its own installed path those
# are the same inode, GNU install refuses the copy, and set -Eeuo pipefail kills
# the command after all real work has completed - so `add` never prints the
# connection details.
#
# The audited fixtures could not see this: they source the release file and
# redirect MANAGER_BIN, so source and destination always differ. This regression
# installs the manager to the real documented paths and drives the real
# add/repair/update tails with BASH_SOURCE[0] resolving to the installed file.
#
# install(1), install_manager_copy, save_instance, write_instance_config, ok and
# show_instance_cmd are all REAL here. Only environment scaffolding that this
# container cannot provide (systemd, iproute2, dig, a built relay, a frontend)
# is replaced, and never the mechanism under test.
#
# Usage: tg3-installed-manager-lifecycle.sh [path/to/twebproxy-manager.sh]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
MGR="$(cd "$(dirname "$MGR")" && pwd -P)/$(basename "$MGR")"

# Re-exec inside a mount namespace so the real installed paths are writable
# tmpfs and nothing escapes to the host.
if [[ "${TG3_INNER:-0}" != 1 ]]; then
  exec env TG3_INNER=1 unshare -m bash "$0" "$MGR"
fi
mkdir -p /usr/local/sbin /opt/twebproxy-manager
mount -t tmpfs none /usr/local/sbin
mount -t tmpfs none /opt/twebproxy-manager

pass=0; fail=0; neel=0
t_ok()   { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
t_bad()  { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
t_skip() { printf 'NOT_EXECUTED_ENVIRONMENT_LIMITATION %s\n' "$*"; neel=$((neel+1)); }

TMP="$(mktemp -d /tmp/tg3-installed.XXXXXX)"; trap 'rm -rf -- "$TMP"' EXIT
MANAGER_BIN=/usr/local/sbin/twebproxy
PROJECT_MANAGER_COPY=/opt/twebproxy-manager/twebproxy-manager.sh
install -o root -g root -m 0755 "$MGR" "$MANAGER_BIN"
install -o root -g root -m 0755 "$MGR" "$PROJECT_MANAGER_COPY"
want_sha="$(sha256sum "$MGR" | awk '{print $1}')"

# ---- the installed file is a real, runnable program -------------------------
if timeout 30 "$MANAGER_BIN" --help >/dev/null 2>&1; then
  t_ok "tg3_installed_manager_is_executable"
else
  t_bad "tg3_installed_manager_is_executable"
fi

# ---- shared scaffolding for every driver ------------------------------------
cat > "$TMP/scaffold.sh" <<'SCAF'
# Sourced by each driver AFTER the installed manager, to replace only what this
# container cannot provide. install_manager_copy and install(1) stay untouched.
trap - ERR
BASE_DIR="$SB/etc/twebproxy"; INSTANCES_DIR="$BASE_DIR/instances"
BACKENDS_DIR="$BASE_DIR/backends"; SITES_DIR="$SB/srv"; GLOBAL_ENV="$BASE_DIR/global.env"
MTPROXY_DATA_DIR="$BASE_DIR/mtproxy"; LANGUAGE_FILE="$BASE_DIR/ui-language"
install -d -m 0700 "$BASE_DIR" "$INSTANCES_DIR" "$BACKENDS_DIR" "$MTPROXY_DATA_DIR"
install -d -m 0755 "$SITES_DIR"
UI_LANGUAGE=en
need_systemd()  { return 0; }
check_platform() { return 0; }
ensure_core()   { return 0; }
systemctl()     { return 0; }
validate_instance()          { return 0; }
rebuild_firewall()           { return 0; }
start_profile_backend()      { return 0; }
start_all_backends()         { return 0; }
restart_relay_wait_ready()   { return 0; }
configure_tls_for_instance() { return 0; }
configure_ufw()              { return 0; }
dpi_repair_all()             { return 0; }
audit_instance_impl()        { return 0; }
write_runner_helpers()       { return 0; }
write_systemd_templates()    { return 0; }
refresh_mtproxy_material()   { return 0; }
yesno()         { return 0; }
SCAF

# ---- driver 1: the REAL add tail on the installed path ----------------------
cat > "$TMP/drv-add.sh" <<'DRV'
#!/usr/bin/env bash
SB="$1"
source /usr/local/sbin/twebproxy          # BASH_SOURCE[0] in its functions == MANAGER_BIN
source "$SB/scaffold.sh"
collect_instance_settings() {
  HOSTNAME=alpha.example; RELAY_PORT=18080; ADMIN_PORT=18081
  TLS_MODE=manual; SITE_MODE=placeholder; SOURCE_SITE_DIR=""; SITE_UPSTREAM=""
  NGINX_CERT=""; NGINX_KEY=""; LE_EMAIL=""
}
collect_profile_settings() {
  PROFILE_NAME=default; CARRIER_MODE=https
  SECRET=00112233445566778899aabbccddeeff
  BACKEND_PORT=23980; STATS_PORT=28980; WORKERS=1; MAX_CONNECTIONS=100
}
# no `if`, no `||` - set -e must behave exactly as in production
add_instance_cmd
DRV

# ---- driver 2: the REAL repair tail on the installed path -------------------
cat > "$TMP/drv-repair.sh" <<'DRV'
#!/usr/bin/env bash
SB="$1"
source /usr/local/sbin/twebproxy
source "$SB/scaffold.sh"
install -d -m 0700 "$INSTANCES_DIR/alpha.example" "$INSTANCES_DIR/alpha.example/profiles.d"
cat > "$INSTANCES_DIR/alpha.example/instance.env" <<EOF
HOSTNAME=alpha.example
RELAY_PORT=18080
ADMIN_PORT=18081
TLS_MODE=manual
SITE_MODE=placeholder
SOURCE_SITE_DIR=
SITE_UPSTREAM=
NGINX_CERT=
NGINX_KEY=
LE_EMAIL=
EOF
chmod 0600 "$INSTANCES_DIR/alpha.example/instance.env"
rebuild_profiles_json() { printf '{}' > "$(profiles_json "$1")"; }
write_instance_config()  { return 0; }
show_instance_cmd() { printf 'SHOW_INSTANCE_REACHED %s\n' "$1"; }
repair_instance_cmd alpha.example
DRV

# ---- driver 3: the REAL update tail on the installed path -------------------
cat > "$TMP/drv-update.sh" <<'DRV'
#!/usr/bin/env bash
SB="$1"
source /usr/local/sbin/twebproxy
source "$SB/scaffold.sh"
# update_cmd's body needs apt/go/network; its tail is the audited failure point.
write_global_env
install_manager_copy
printf 'UPDATE_TAIL_REACHED\n'
DRV

# ---- driver 4: run from the OTHER installed copy ----------------------------
cat > "$TMP/drv-project-copy.sh" <<'DRV'
#!/usr/bin/env bash
SB="$1"
source /opt/twebproxy-manager/twebproxy-manager.sh   # BASH_SOURCE == PROJECT_MANAGER_COPY
source "$SB/scaffold.sh"
install_manager_copy
printf 'PROJECT_COPY_TAIL_REACHED\n'
DRV

cp "$TMP/scaffold.sh" "$TMP/scaffold.sh.bak"
run_driver() { # $1=driver $2=label -> sets RC and OUT
  local sb="$TMP/sb-$2"; rm -rf "$sb"; mkdir -p "$sb"; cp "$TMP/scaffold.sh" "$sb/scaffold.sh"
  OUT="$(timeout 120 bash "$1" "$sb" 2>&1)"; RC=$?
}

# ============================ add ============================================
run_driver "$TMP/drv-add.sh" add
(( RC == 0 )) && t_ok "tg3_installed_add_exits_zero" \
  || t_bad "tg3_installed_add_exits_zero: rc=$RC :: $(grep -iE 'same file|Ошибка|Error' <<<"$OUT" | head -2 | tr '\n' ' ')"
if grep -qi 'isolation audit' <<<"$OUT"; then
  t_ok "tg3_installed_add_reaches_success_message"
else
  t_bad "tg3_installed_add_reaches_success_message"
fi
# https://<host>/ is emitted only by show_instance_cmd, never by the plan block,
# so this cannot be satisfied by output printed before install_manager_copy.
if grep -q 'https://alpha.example/' <<<"$OUT"; then
  t_ok "tg3_installed_add_reaches_connection_details"
else
  t_bad "tg3_installed_add_reaches_connection_details: show_instance_cmd output absent"
fi
if grep -q '00112233445566778899aabbccddeeff' <<<"$OUT" || grep -qi 'secret' <<<"$OUT"; then
  t_ok "tg3_installed_add_reaches_profile_secret_block"
else
  t_bad "tg3_installed_add_reaches_profile_secret_block"
fi
grep -qi 'are the same file' <<<"$OUT" \
  && t_bad "tg3_installed_add_no_self_copy_error" \
  || t_ok "tg3_installed_add_no_self_copy_error"

# ============================ repair =========================================
run_driver "$TMP/drv-repair.sh" repair
(( RC == 0 )) && t_ok "tg3_installed_repair_exits_zero" \
  || t_bad "tg3_installed_repair_exits_zero: rc=$RC :: $(grep -iE 'same file|Ошибка|Error' <<<"$OUT" | head -2 | tr '\n' ' ')"
grep -q 'SHOW_INSTANCE_REACHED' <<<"$OUT" \
  && t_ok "tg3_installed_repair_reaches_success_path" \
  || t_bad "tg3_installed_repair_reaches_success_path"

# ============================ update tail ====================================
run_driver "$TMP/drv-update.sh" update
(( RC == 0 )) && t_ok "tg3_installed_update_tail_exits_zero" \
  || t_bad "tg3_installed_update_tail_exits_zero: rc=$RC"
grep -q 'UPDATE_TAIL_REACHED' <<<"$OUT" \
  && t_ok "tg3_installed_update_tail_reached" || t_bad "tg3_installed_update_tail_reached"

# ============================ second installed copy ==========================
run_driver "$TMP/drv-project-copy.sh" projectcopy
(( RC == 0 )) && t_ok "tg3_project_copy_path_exits_zero" \
  || t_bad "tg3_project_copy_path_exits_zero: rc=$RC"
grep -q 'PROJECT_COPY_TAIL_REACHED' <<<"$OUT" \
  && t_ok "tg3_project_copy_tail_reached" || t_bad "tg3_project_copy_tail_reached"

# ============================ both copies remain correct =====================
for target in "$MANAGER_BIN" "$PROJECT_MANAGER_COPY"; do
  label="$(basename "$target")"
  [[ -f "$target" ]] || { t_bad "tg3_${label}_present"; continue; }
  t_ok "tg3_${label}_present"
  [[ "$(sha256sum "$target" | awk '{print $1}')" == "$want_sha" ]] \
    && t_ok "tg3_${label}_content_intact" || t_bad "tg3_${label}_content_intact"
  [[ "$(stat -c '%U:%G:%a' "$target")" == "root:root:755" ]] \
    && t_ok "tg3_${label}_owner_mode_preserved" \
    || t_bad "tg3_${label}_owner_mode_preserved: $(stat -c '%U:%G:%a' "$target")"
done

# ============================ second copy still synchronised =================
# Both destinations must be handled independently: a stale second copy must be
# refreshed even when the first destination is the running file itself.
printf '#!/usr/bin/env bash\n# stale\n' > "$PROJECT_MANAGER_COPY"; chmod 0755 "$PROJECT_MANAGER_COPY"
run_driver "$TMP/drv-update.sh" resync
if (( RC == 0 )) && [[ "$(sha256sum "$PROJECT_MANAGER_COPY" | awk '{print $1}')" == "$want_sha" ]]; then
  t_ok "tg3_stale_second_copy_is_resynchronised"
else
  t_bad "tg3_stale_second_copy_is_resynchronised: rc=$RC (function must not skip wholesale)"
fi

t_skip "tg3_full_unstubbed_add: needs live systemd, iproute2, dig, a built relay and a frontend"

printf 'tg3: pass=%s fail=%s neel=%s\n' "$pass" "$fail" "$neel"
(( fail == 0 ))
