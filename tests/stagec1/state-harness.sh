#!/usr/bin/env bash
# Behavioral sandbox for the Stage C1 profile/state regressions.
#
# The profile, instance, state-writing, locking and port code under test is the
# unmodified manager. Only the host boundary is replaced: systemctl, ss and curl
# are small models in $TMP/bin, tproxy-server -check validates profiles.json with
# jq, and the interactive prompts read scripted answers. Nothing outside $TMP is
# read or written. This proves control flow and file postconditions, not real
# systemd behaviour.
#
#   TMP=... ; source tests/stagec1/state-harness.sh ; c1_harness
#
# Commands under test run through c1_run/c1_eval in a SEPARATE bash process
# with production `set -Eeuo pipefail`: inside an `if`/`check` condition bash
# ignores errexit even in a ( set -e; ... ) subshell, which would hide failures
# of code that relies on errexit. Several processes may share one $TMP.

C1_HARNESS="${BASH_SOURCE[0]}"

c1_harness() {
  export ROOT MGR TMP C1_HARNESS
  export TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 TWEBPROXY_UI_LANGUAGE=en
  export TWEBPROXY_LANGUAGE_FILE="$TMP/ui-language"
  # shellcheck source=/dev/null
  source "$MGR"
  trap - ERR
  set +e
  # Sourced inside this function, the manager's top-level `declare -A` catalog
  # is local; the prompts of the add flow need it after the harness returns.
  declare -gA UI_EN=() UI_RU=()
  BASE_DIR="$TMP/etc"; INSTANCES_DIR="$BASE_DIR/instances"; BACKENDS_DIR="$BASE_DIR/backends"
  MTPROXY_DATA_DIR="$BASE_DIR/mtproxy"; GLOBAL_ENV="$BASE_DIR/global.env"
  FIREWALL_FILE="$BASE_DIR/firewall.nft"; DPI_DIR="$BASE_DIR/dpi"
  DPI_LOCK_FILE="$BASE_DIR/.dpi-mutation.lock"
  SITES_DIR="$TMP/srv"; LIBEXEC_DIR="$TMP/libexec"; SYSTEMD_DIR="$TMP/systemd"
  PROJECT_DIR="$TMP/opt"; LOG_DIR="$PROJECT_DIR/logs"; LOG_MANAGER_DIR="$LOG_DIR/manager"
  LOG_RUNTIME_DIR="$LOG_DIR/runtime"; LOG_BUNDLE_DIR="$LOG_DIR/bundles"; LOG_FULL_DIR="$LOG_DIR/full"
  TPROXY_BIN="$TMP/bin/tproxy-server"; MTPROXY_BIN="$LIBEXEC_DIR/mtproto-proxy"
  UI_LANGUAGE=en
  export C1_ROOT="$TMP" C1_BACKENDS_DIR="$BACKENDS_DIR"
  install -d -m 0700 "$BASE_DIR" "$INSTANCES_DIR" "$BACKENDS_DIR" "$MTPROXY_DATA_DIR" "$TMP/bin" "$TMP/units"
  install -d -m 0755 "$SITES_DIR" "$LIBEXEC_DIR" "$SYSTEMD_DIR"
  [[ -x "$TMP/bin/systemctl" ]] || c1_write_models
  case ":$PATH:" in *":$TMP/bin:"*) ;; *) export PATH="$TMP/bin:$PATH";; esac
  # Host-only preconditions and the Stage B firewall (covered by its own suite).
  need_root() { :; }; need_systemd() { :; }; check_platform() { :; }; banner() { :; }
  # v0.2.23 host-only steps: the procfs policy and the owned guard session are
  # real-host behaviour (tests/prerc). The model guard mirrors backend state.
  proc_hardening_ensure() { :; }; proc_hardening_state() { builtin printf hidden; }
  proc_hidepid_value() { builtin printf invisible; }
  fw_guard_live() { BF_BACKENDS="$BACKENDS_DIR" backend_fw_collect; }
  export TWEBPROXY_CADDY_CERT_WAIT=0
  ensure_core() { :; }
  # Stage B firewall stand-in: the protected port set is what the real
  # backend_fw_collect derives from backends/*.env at rebuild time.
  rebuild_firewall() {
    local ports
    ports="$(BF_BACKENDS="$BACKENDS_DIR" backend_fw_collect)" || return 1
    builtin printf '%s\n' "$ports" > "$TMP/firewall.applied"
    builtin printf 'rebuild %s\n' "$ports" | tee -a "$TMP/firewall.calls" >> "$TMP/events"
  }
  c1_answers
  c1_faults
  [[ "${C1_INSTANCE_STUBS:-}" != 1 ]] || c1_instance_stubs
}

# Production semantics, separate process (see header).
c1_run() { bash -c 'source "$C1_HARNESS"; c1_harness; set -Eeuo pipefail; "$@"' c1-run "$@"; }
c1_eval() { bash -c 'source "$C1_HARNESS"; c1_harness; set -Eeuo pipefail; eval "$1"' c1-eval "$1"; }

# Injected one-shot write failures (command failures, not a real ENOSPC):
#   C1_FAULT=<text> + $TMP/fault : the printf whose format contains <text> fails
#   $TMP/fault-jq                : the final profiles.json jq invocation fails
c1_faults() {
  printf() {
    if [[ -n "${C1_FAULT:-}" && -e "$TMP/fault" && "${1:-}" == *"$C1_FAULT"* ]]; then
      rm -f "$TMP/fault"; return 1
    fi
    builtin printf "$@"
  }
  jq() {
    if [[ -e "$TMP/fault-jq" && "$*" == *'{profiles:$profiles}'* ]]; then rm -f "$TMP/fault-jq"; return 1; fi
    command jq "$@"
  }
}

c1_write_models() {
  cat > "$TMP/bin/systemctl" <<'SH'
#!/bin/bash
# Unit model: a started twebproxy-mtproxy@ID listens on the port of its env file.
# Faults: fail-stop-<unit> (stop fails, unit stays active), state-<unit> (is-active
# prints that state, unit stays up), fail-is-active (is-active errors, no output).
printf '%s\n' "$*" >> "$C1_ROOT/systemctl.calls"
printf 'systemctl %s\n' "$*" >> "$C1_ROOT/events"
quiet=0; [[ "${2:-}" == --quiet ]] && quiet=1
args=("$@"); unit="${args[-1]}"
case "$1" in
  reset-failed|daemon-reload|enable) [[ "${2:-}" != --now ]] && exit 0;;
esac
start_unit() {
  local u="$1" id port
  : > "$C1_ROOT/units/$u"
  if [[ "$u" == twebproxy-mtproxy@*.service ]]; then
    id="${u#twebproxy-mtproxy@}"; id="${id%.service}"
    port="$(sed -n 's/^MTPROXY_CLIENT_PORT=//p' "$C1_BACKENDS_DIR/$id.env" 2>/dev/null)"
    [[ -n "$port" ]] || { rm -f "$C1_ROOT/units/$u"; exit 1; }
    printf 'LISTEN 0 4096 0.0.0.0:%s 0.0.0.0:*\n' "$port" > "$C1_ROOT/units/$u"
  fi
}
case "$1" in
  enable|restart|start) start_unit "$unit";;
  disable|stop)
    [[ ! -e "$C1_ROOT/fail-stop-$unit" ]] || { echo "model: stop of $unit failed" >&2; exit 1; }
    [[ -e "$C1_ROOT/state-$unit" ]] || rm -f "$C1_ROOT/units/$unit";;
  is-active)
    [[ ! -e "$C1_ROOT/fail-is-active" ]] || exit 1
    if [[ -e "$C1_ROOT/state-$unit" ]]; then (( quiet )) || cat "$C1_ROOT/state-$unit"; exit 3; fi
    [[ -e "$C1_ROOT/units/$unit" ]] || { (( quiet )) || echo inactive; exit 3; }; (( quiet )) || echo active;;
  *) exit 0;;
esac
SH
  cat > "$TMP/bin/ss" <<'SH'
#!/bin/bash
# Listener model: started units, extra lines, optional padding, failure.
[[ ! -e "$C1_ROOT/fail-ss" ]] || exit 1
cat "$C1_ROOT"/units/* "$C1_ROOT/ss-extra" 2>/dev/null
n="${C1_SS_PAD:-0}"
(( n > 0 )) && awk -v n="$n" 'BEGIN{for(i=0;i<n;i++) printf "LISTEN 0 128 10.%d.%d.%d:%d 0.0.0.0:*\n", i%250, (i/250)%250, 1, 40000+i%20000}'
exit 0
SH
  cat > "$TMP/bin/curl" <<'SH'
#!/bin/bash
exit 0
SH
  cat > "$TMP/bin/journalctl" <<'SH'
#!/bin/bash
echo 'journal model: no entries'
SH
  cat > "$TMP/bin/tproxy-server" <<'SH'
#!/bin/bash
# -check model: config and profiles must parse; profile names unique; injectable failure.
[[ ! -e "$C1_ROOT/fail-validate" ]] || { echo 'model: injected validation failure' >&2; exit 1; }
cfg="" prof=""
while (( $# )); do case "$1" in -config) cfg="$2"; shift;; -profiles-file) prof="$2"; shift;; esac; shift; done
jq -e . "$cfg" >/dev/null && jq -e '(.profiles|length) >= 1 and ((.profiles|map(.name)|unique|length) == (.profiles|length))' "$prof" >/dev/null
SH
  chmod 0755 "$TMP/bin/"*
}

# Scripted interactive answers (production prompts are otherwise unchanged).
#   C1_HOST        hostname answer for add_instance_cmd
#   C1_NAME        profile name answer
#   C1_MANUAL_PORTS=1 with C1_BACKEND_PORT/C1_STATS_PORT: manual port answers
#   C1_CARRIER     carrier answer (https|https-lanes|websocket|websocket-lanes)
#   C1_SECRET      value returned by `openssl rand -hex 16`
#   C1_AT_CARRIER  barrier: touch $TMP/<value>.reached, wait for $TMP/<value>.go
#   C1_AT_MAXCONN  same barrier, at the last profile prompt (after port choice)
c1_answers() {
  ask() {
    case "$1" in
      'Hostname WEB-proxy (без https://)') printf '%s' "${C1_HOST:-}";;
      'Имя профиля/секрета') printf '%s' "${C1_NAME:-$2}";;
      'MTProxy backend port') printf '%s' "${C1_BACKEND_PORT:-$2}";;
      'MTProxy stats port') printf '%s' "${C1_STATS_PORT:-$2}";;
      'Max connections на worker') c1_barrier "${C1_AT_MAXCONN:-}"; printf '%s' "$2";;
      *) printf '%s' "$2";;
    esac
  }
  yesno() {
    case "$1" in
      'Backend/stats порты подобрать автоматически?') [[ -z "${C1_MANUAL_PORTS:-}" ]];;
      *) return 0;;
    esac
  }
  # add_instance_cmd: advanced setup (every prompt below is asked), placeholder
  # site, manual TLS frontend.
  choose() { case "$1" in 'Setup type:'|'Тип настройки:') printf 2;; 'Обычный сайт на hostname:') printf 1;; 'SSL / reverse proxy:') printf 4;; *) printf 1;; esac; }
  carrier_choose() { c1_barrier "${C1_AT_CARRIER:-}"; printf '%s' "${C1_CARRIER:-https}"; }
  openssl() {
    if [[ "${1:-} ${2:-}" == "rand -hex" && -n "${C1_SECRET:-}" ]]; then printf '%s\n' "$C1_SECRET"; return 0; fi
    command openssl "$@"
  }
}

# Frontend, TLS, DPI, audit and install steps of add_instance_cmd are other
# subsystems; replace them so its state/port/lock path can be exercised.
# The same holds for repair/delete: these touch production paths that the
# sandbox does not rebind (/etc/caddy, /etc/nginx, the Stage 4 restore helper
# path, host users), so they are never reached from a test.
c1_instance_stubs() {
  check_frontend_compatibility() { :; }; configure_tls_for_instance() { :; }; configure_ufw() { :; }
  dpi_with_mutation_lock() { :; }; audit_instance_impl() { :; }; install_manager_copy() { :; }
  show_instance_cmd() { printf 'instance %s\n' "$1"; }
  remove_reverse_proxy_for_instance() { :; }; dpi_resolve_ipv4() { return 1; }
  prepare_users_and_dirs() { :; }; stage4_install_restore_helper() { :; }
  write_runner_helpers() { :; }; write_systemd_templates() { :; }
}

c1_barrier() {
  local name="$1" i
  [[ -n "$name" ]] || return 0
  : > "$TMP/$name.reached"
  for ((i = 0; i < 400; i++)); do [[ -e "$TMP/$name.go" ]] && return 0; sleep 0.05; done
  printf 'barrier %s timed out\n' "$name" >&2; return 1
}
c1_wait_reached() { local i; for ((i = 0; i < 400; i++)); do [[ -e "$TMP/$1.reached" ]] && return 0; sleep 0.05; done; return 1; }

# Seed state exactly as v0.2.13 save_instance/save_profile wrote it.
c1_seed_instance() { # $1=host $2=relay $3=admin
  install -d -m 0700 "$INSTANCES_DIR/$1" "$INSTANCES_DIR/$1/profiles.d"
  {
    printf 'HOSTNAME=%q\nRELAY_PORT=%q\nADMIN_PORT=%q\nTLS_MODE=%q\nSITE_MODE=%q\n' "$1" "$2" "$3" manual placeholder
    printf 'SITE_UPSTREAM=%q\nSOURCE_SITE_DIR=%q\nACME_EMAIL=%q\nNGINX_CERT=%q\nNGINX_KEY=%q\n' '' '' '' '' ''
    printf 'CREATED_AT=%q\n' 2026-01-01T00:00:00+00:00
  } > "$INSTANCES_DIR/$1/instance.env"
  chmod 0600 "$INSTANCES_DIR/$1/instance.env"
  printf '{"public_hostname":"%s"}\n' "$1" > "$INSTANCES_DIR/$1/config.json"
}
c1_seed_profile() { # $1=host $2=name $3=secret $4=carrier $5=backend $6=stats [$7=workers]
  local f="$INSTANCES_DIR/$1/profiles.d/$2.env"
  {
    printf 'PROFILE_NAME=%q\nSECRET=%q\nCARRIER_MODE=%q\nBACKEND_PORT=%q\nSTATS_PORT=%q\n' "$2" "$3" "$4" "$5" "$6"
    printf 'WORKERS=%q\nMAX_CONNECTIONS=%q\nCREATED_AT=%q\n' "${7:-1}" 4096 2026-01-02T00:00:00+00:00
  } > "$f"; chmod 0600 "$f"
  {
    printf 'MTPROXY_SECRET=%q\nMTPROXY_CLIENT_PORT=%q\nMTPROXY_STATS_PORT=%q\n' "${3#dd}" "$5" "$6"
    printf 'MTPROXY_WORKERS=%q\nMTPROXY_MAX_CONNECTIONS=%q\n' "${7:-1}" 4096
  } > "$BACKENDS_DIR/$1--$2.env"; chmod 0600 "$BACKENDS_DIR/$1--$2.env"
}
c1_field() { sed -n "s/^$2=//p" "$1"; }   # $1=file $2=key
