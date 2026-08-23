#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# TWebProxy Manager v0.2.6
# Multi-instance / multi-secret manager for telegramdesktop/tproxy-server.
# Target: Debian 12+ / Ubuntu 22.04+, x86_64, systemd.

APP="twebproxy"
MANAGER_VERSION="0.2.6"
TPROXY_REPO="https://github.com/telegramdesktop/tproxy-server.git"
TPROXY_BRANCH="master"
# First real E2E baseline validated on 2026-08-23. Fresh core installs use this
# exact relay revision; `twebproxy update` is the explicit opt-in path to newer master.
TPROXY_INSTALL_COMMIT="2873a08806d6e4d84830b9b5c4b0ec0f46af91f8"
MTPROXY_REPO="https://github.com/TelegramMessenger/MTProxy.git"
# Pinned by the upstream tproxy-server deployment docs at the time v0.2.0 was built.
MTPROXY_COMMIT="f36d8af769ffaeac36978d38c2c0f6d1104c2137"

# Manager release/update source. `check-update` prefers the latest stable GitHub
# release and falls back to the repository VERSION file on the default branch.
MANAGER_REPO_SLUG="Lazarev33/twebproxy-manager"
MANAGER_REPO_URL="https://github.com/$MANAGER_REPO_SLUG"
MANAGER_API_URL="https://api.github.com/repos/$MANAGER_REPO_SLUG"
MANAGER_RAW_URL="https://raw.githubusercontent.com/$MANAGER_REPO_SLUG"
MANAGER_DEFAULT_BRANCH="main"
MANAGER_UPDATE_CACHE_TTL=21600

BASE_DIR="/etc/twebproxy"
INSTANCES_DIR="$BASE_DIR/instances"
BACKENDS_DIR="$BASE_DIR/backends"
MTPROXY_DATA_DIR="$BASE_DIR/mtproxy"
SITES_DIR="/srv/twebproxy"
TPROXY_SRC="/opt/twebproxy-src"
MTPROXY_SRC="/opt/MTProxy"
TPROXY_BIN="/usr/local/bin/tproxy-server"
MANAGER_BIN="/usr/local/sbin/twebproxy"
LIBEXEC_DIR="/usr/local/libexec/twebproxy"
MTPROXY_BIN="$LIBEXEC_DIR/mtproto-proxy"
SYSTEMD_DIR="/etc/systemd/system"
GLOBAL_ENV="$BASE_DIR/global.env"
FIREWALL_FILE="$BASE_DIR/firewall.nft"

# Installed manager project and persistent/shareable logs.
PROJECT_DIR="/opt/twebproxy-manager"
PROJECT_MANAGER_COPY="$PROJECT_DIR/twebproxy-manager.sh"
LOG_DIR="$PROJECT_DIR/logs"
LOG_MANAGER_DIR="$LOG_DIR/manager"
LOG_RUNTIME_DIR="$LOG_DIR/runtime"
LOG_BUNDLE_DIR="$LOG_DIR/bundles"
LOG_FULL_DIR="$LOG_DIR/full"
UPDATE_CACHE_FILE="$PROJECT_DIR/update-check.env"
CURRENT_LOG=""
MANAGER_UPDATE_HINT_ATTEMPTED=0

C_RESET='\033[0m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_CYAN='\033[36m'; C_BOLD='\033[1m'; C_DIM='\033[2m'

log()  { printf "%b[i]%b %s\n" "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf "%b[+]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%b[!]%b %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
die()  { printf "%b[x]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

strip_ansi_stream() {
  sed -u -E -e 's/\x1B\[[0-9;]*m//g'
}

sanitize_log_stream() {
  # Terminal stays untouched; the normal on-disk transcript is safe to share.
  # A separate --full report can include WEB/MTProxy secrets when they are actually useful.
  strip_ansi_stream | sed -u -E \
    -e 's/(Secret:[[:space:]]*)(dd)?[0-9A-Fa-f]{32}/\1[REDACTED]/g' \
    -e 's/([?&]secret=)(dd)?[0-9A-Fa-f]{32}/\1[REDACTED]/g' \
    -e 's/(MTPROXY_SECRET=)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/(-S[[:space:]]+)(dd)?[0-9A-Fa-f]{32}/\1[REDACTED]/g' \
    -e 's/(SECRET=)(dd)?[0-9A-Fa-f]{32}/\1[REDACTED]/g' \
    -e 's/("secret"[[:space:]]*:[[:space:]]*")(dd)?[0-9A-Fa-f]{32}(")/\1[REDACTED]\3/g'
}

setup_logging() {
  local action="${1:-menu}" ts safe
  [[ "${TWEBPROXY_NO_LOG:-0}" == "1" ]] && return 0
  [[ ${EUID:-$(id -u)} -eq 0 ]] || return 0
  install -d -o root -g root -m 0700 "$PROJECT_DIR" "$LOG_DIR" "$LOG_MANAGER_DIR" "$LOG_RUNTIME_DIR" "$LOG_BUNDLE_DIR" "$LOG_FULL_DIR"
  safe="$(printf '%s' "$action" | tr -cs 'A-Za-z0-9._-' '_')"
  ts="$(date '+%Y%m%d-%H%M%S')"
  CURRENT_LOG="$LOG_MANAGER_DIR/${ts}-${safe}-$$.log"
  : > "$CURRENT_LOG"
  chmod 0600 "$CURRENT_LOG"

  # Capture the complete command transcript: installer, apt, git, go, systemctl, etc.
  # fd 3 keeps normal terminal output while the second tee branch writes sanitized logs.
  exec 3>&1 4>&2
  exec > >(tee >(sanitize_log_stream >>"$CURRENT_LOG") >&3) 2>&1
  printf "[log] %s\n" "$CURRENT_LOG"
}

on_error() {
  local rc="$1" line="$2" command="$3" snap=""
  printf "\n%b[x]%b Ошибка на строке %s. Команда: %s (код %s)\n" "$C_RED" "$C_RESET" "$line" "$command" "$rc" >&2
  [[ -n "${CURRENT_LOG:-}" ]] && printf "%b[i]%b Полный лог запуска: %s\n" "$C_BLUE" "$C_RESET" "$CURRENT_LOG" >&2

  # Best-effort failure snapshot. Never let diagnostic collection hide the original error.
  if [[ ${EUID:-$(id -u)} -eq 0 && -n "${LOG_RUNTIME_DIR:-}" && "${TWEBPROXY_ERROR_SNAPSHOT:-0}" != "1" ]]; then
    export TWEBPROXY_ERROR_SNAPSHOT=1
    trap - ERR
    set +e
    snap="$(collect_runtime_snapshot safe failure 2>/dev/null)"
    [[ -n "$snap" ]] && printf "%b[i]%b Автоснимок состояния после ошибки: %s\n" "$C_BLUE" "$C_RESET" "$snap" >&2
    set -e
    trap 'rc=$?; on_error "$rc" "$LINENO" "$BASH_COMMAND"' ERR
  fi
  return "$rc"
}

trap 'rc=$?; on_error "$rc" "$LINENO" "$BASH_COMMAND"' ERR

banner() {
  printf "%b" "$C_BOLD"
  cat <<EOF
┌──────────────────────────────────────────────────────┐
│              TWebProxy Manager v$MANAGER_VERSION              │
│      Telegram WEB Proxy multi-instance manager       │
└──────────────────────────────────────────────────────┘
EOF
  printf "%b" "$C_RESET"
}

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запусти от root: sudo $0"; }
need_systemd() { command -v systemctl >/dev/null 2>&1 || die "Нужен systemd."; }

ask() {
  local prompt="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "$prompt: " value
    printf '%s' "$value"
  fi
}

yesno() {
  local prompt="$1" default="${2:-y}" reply
  if [[ "$default" == "y" ]]; then
    read -r -p "$prompt [Y/n]: " reply
    [[ -z "$reply" || "$reply" =~ ^[YyДд]$ ]]
  else
    read -r -p "$prompt [y/N]: " reply
    [[ "$reply" =~ ^[YyДд]$ ]]
  fi
}

choose() {
  local prompt="$1"; shift
  local options=("$@") i choice
  echo "$prompt" >&2
  for i in "${!options[@]}"; do printf "  %d) %s\n" "$((i+1))" "${options[$i]}" >&2; done
  while true; do
    read -r -p "> " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Введи номер." >&2; continue; }
    (( choice >= 1 && choice <= ${#options[@]} )) || { warn "Нет такого пункта." >&2; continue; }
    printf '%s' "$choice"
    return 0
  done
}

pause() { read -r -p "Нажми Enter для продолжения..." _ || true; }

is_valid_hostname() {
  local h="$1"
  [[ "$h" == "${h,,}" ]] || return 1
  [[ "$h" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || return 1
  [[ "$h" == *.* ]] || return 1
  [[ ${#h} -le 253 ]] || return 1
  local label
  IFS='.' read -r -a labels <<<"$h"
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" != -* && "$label" != *- ]] || return 1
  done
}

is_valid_profile_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; }
is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }
is_valid_secret() { [[ "$1" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]]; }

instance_dir() { printf '%s/%s' "$INSTANCES_DIR" "$1"; }
instance_env() { printf '%s/%s/instance.env' "$INSTANCES_DIR" "$1"; }
profiles_json() { printf '%s/%s/profiles.json' "$INSTANCES_DIR" "$1"; }
profile_dir() { printf '%s/%s/profiles.d' "$INSTANCES_DIR" "$1"; }
profile_env() { printf '%s/%s/profiles.d/%s.env' "$INSTANCES_DIR" "$1" "$2"; }
backend_id() { printf '%s--%s' "$1" "$2"; }
backend_env() { printf '%s/%s.env' "$BACKENDS_DIR" "$(backend_id "$1" "$2")"; }
site_dir() { printf '%s/%s' "$SITES_DIR" "$1"; }

instance_exists() { [[ -f "$(instance_env "$1")" ]]; }
core_installed() { [[ -x "$TPROXY_BIN" && -x "$MTPROXY_BIN" && -f "$SYSTEMD_DIR/twebproxy@.service" ]]; }

list_hosts_array() {
  local f
  [[ -d "$INSTANCES_DIR" ]] || return 0
  find "$INSTANCES_DIR" -mindepth 2 -maxdepth 2 -type f -name instance.env -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do basename "$(dirname "$f")"; done \
    | sort
}

list_profiles_array() {
  local host="$1" f
  local d; d="$(profile_dir "$host")"
  [[ -d "$d" ]] || return 0
  find "$d" -maxdepth 1 -type f -name '*.env' -printf '%f\n' 2>/dev/null | sed 's/\.env$//' | sort
}

count_instances() { list_hosts_array | sed '/^$/d' | wc -l; }
count_profiles() { list_profiles_array "$1" | sed '/^$/d' | wc -l; }

load_instance() {
  local host="$1" f; f="$(instance_env "$host")"
  [[ -f "$f" ]] || die "Инстанс не найден: $host"
  # shellcheck disable=SC1090
  source "$f"
}

load_profile() {
  local host="$1" profile="$2" f; f="$(profile_env "$host" "$profile")"
  [[ -f "$f" ]] || die "Профиль $profile не найден у $host"
  # shellcheck disable=SC1090
  source "$f"
}

save_instance() {
  local host="$1" d; d="$(instance_dir "$host")"
  install -d -m 0700 "$d" "$(profile_dir "$host")"
  {
    printf 'HOSTNAME=%q\n' "$HOSTNAME"
    printf 'RELAY_PORT=%q\n' "$RELAY_PORT"
    printf 'ADMIN_PORT=%q\n' "$ADMIN_PORT"
    printf 'TLS_MODE=%q\n' "$TLS_MODE"
    printf 'SITE_MODE=%q\n' "$SITE_MODE"
    printf 'SITE_UPSTREAM=%q\n' "${SITE_UPSTREAM:-}"
    printf 'SOURCE_SITE_DIR=%q\n' "${SOURCE_SITE_DIR:-}"
    printf 'ACME_EMAIL=%q\n' "${ACME_EMAIL:-}"
    printf 'NGINX_CERT=%q\n' "${NGINX_CERT:-}"
    printf 'NGINX_KEY=%q\n' "${NGINX_KEY:-}"
    printf 'CREATED_AT=%q\n' "${CREATED_AT:-$(date -Is)}"
  } > "$(instance_env "$host")"
  chmod 0600 "$(instance_env "$host")"
}

save_profile() {
  local host="$1" profile="$2" f; f="$(profile_env "$host" "$profile")"
  install -d -m 0700 "$(profile_dir "$host")" "$BACKENDS_DIR"
  {
    printf 'PROFILE_NAME=%q\n' "$PROFILE_NAME"
    printf 'SECRET=%q\n' "$SECRET"
    printf 'CARRIER_MODE=%q\n' "$CARRIER_MODE"
    printf 'BACKEND_PORT=%q\n' "$BACKEND_PORT"
    printf 'STATS_PORT=%q\n' "$STATS_PORT"
    printf 'WORKERS=%q\n' "$WORKERS"
    printf 'MAX_CONNECTIONS=%q\n' "$MAX_CONNECTIONS"
    printf 'CREATED_AT=%q\n' "${PROFILE_CREATED_AT:-$(date -Is)}"
  } > "$f"
  chmod 0600 "$f"

  local backend_secret="$SECRET" bfile
  [[ "$backend_secret" == dd* && ${#backend_secret} -eq 34 ]] && backend_secret="${backend_secret:2}"
  bfile="$(backend_env "$host" "$profile")"
  {
    printf 'MTPROXY_SECRET=%q\n' "$backend_secret"
    printf 'MTPROXY_CLIENT_PORT=%q\n' "$BACKEND_PORT"
    printf 'MTPROXY_STATS_PORT=%q\n' "$STATS_PORT"
    printf 'MTPROXY_WORKERS=%q\n' "$WORKERS"
    printf 'MTPROXY_MAX_CONNECTIONS=%q\n' "$MAX_CONNECTIONS"
  } > "$bfile"
  chown root:root "$bfile"
  chmod 0600 "$bfile"
}

check_platform() {
  [[ "$(uname -m)" == "x86_64" ]] || die "Сейчас поддерживается x86_64 Linux."
  [[ -r /etc/os-release ]] || die "Не найден /etc/os-release."
  local os_id
  # Читаем ID в изолированном subshell: /etc/os-release содержит VERSION=...,
  # поэтому source в текущий shell раньше перезаписывал версию самого manager.
  os_id="$(. /etc/os-release; printf '%s' "${ID:-}")"
  case "$os_id" in debian|ubuntu) ;; *) die "Поддерживаются Debian/Ubuntu. Обнаружено: ${os_id:-unknown}" ;; esac
  command -v apt-get >/dev/null 2>&1 || die "apt-get не найден."
}

install_base_deps() {
  log "Проверяю базовые зависимости..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl git jq openssl nftables build-essential libssl-dev zlib1g-dev \
    dnsutils iproute2 xxd procps netcat-openbsd
}

ensure_go() {
  local gobin="" gov="" minor=""
  if command -v go >/dev/null 2>&1; then
    gov="$(go env GOVERSION 2>/dev/null || true)"
    minor="$(sed -nE 's/^go1\.([0-9]+).*/\1/p' <<<"$gov")"
    if [[ "$minor" =~ ^[0-9]+$ ]] && (( minor >= 20 )); then gobin="$(command -v go)"; fi
  fi
  if [[ -z "$gobin" ]]; then
    log "Ставлю актуальный stable Go с проверкой SHA-256..."
    local meta version filename sha tmp dest
    meta="$(curl -fsSL --proto '=https' --tlsv1.2 'https://go.dev/dl/?mode=json')"
    version="$(jq -r '[.[] | select(.stable == true)][0].version' <<<"$meta")"
    [[ "$version" =~ ^go1\.[0-9]+(\.[0-9]+)?$ ]] || die "Не удалось определить stable Go."
    filename="${version}.linux-amd64.tar.gz"
    sha="$(jq -r --arg v "$version" --arg f "$filename" '.[] | select(.version==$v) | .files[] | select(.filename==$f) | .sha256' <<<"$meta")"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "Не удалось получить SHA-256 Go."
    tmp="$(mktemp /tmp/go.XXXXXX.tar.gz)"
    curl -fL --proto '=https' --tlsv1.2 -o "$tmp" "https://go.dev/dl/$filename"
    [[ "$(sha256sum "$tmp" | awk '{print $1}')" == "$sha" ]] || die "SHA-256 Go не совпал."
    dest="/opt/$version"
    rm -rf "$dest"; install -d -m 0755 "$dest"
    tar -C "$dest" --strip-components=1 -xzf "$tmp"; rm -f "$tmp"
    gobin="$dest/bin/go"
  fi
  GO_BIN="$gobin"
  ok "Go: $($GO_BIN version)"
}

prepare_users_and_dirs() {
  id tproxy >/dev/null 2>&1 || useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
  id mtproxy >/dev/null 2>&1 || useradd --system --home /nonexistent --shell /usr/sbin/nologin mtproxy

  # State/secrets stay root-only. Runtime services receive the few files they
  # need through systemd credentials, so service accounts never need to traverse
  # /etc/twebproxy.
  install -d -o root -g root -m 0700 "$BASE_DIR" "$INSTANCES_DIR" "$BACKENDS_DIR" "$MTPROXY_DATA_DIR"
  install -d -o root -g root -m 0755 "$SITES_DIR" "$LIBEXEC_DIR"
  install -d -o root -g root -m 0700 "$PROJECT_DIR" "$LOG_DIR" "$LOG_MANAGER_DIR" "$LOG_RUNTIME_DIR" "$LOG_BUNDLE_DIR" "$LOG_FULL_DIR"
}

sync_tproxy_upstream() {
  local mode="${1:-validated}" origin target_desc
  [[ "$mode" == "validated" || "$mode" == "latest" ]] || die "sync_tproxy_upstream: validated|latest"

  if [[ -d "$TPROXY_SRC/.git" ]]; then
    origin="$(git -C "$TPROXY_SRC" remote get-url origin 2>/dev/null || true)"
    [[ "$origin" == "$TPROXY_REPO" || "$origin" == "${TPROXY_REPO%.git}" ]] || die "У $TPROXY_SRC неожиданный origin: $origin"
  else
    rm -rf "$TPROXY_SRC"
    # Keep a normal git repository so an explicit later `twebproxy update` can
    # move to upstream master without replacing source/state directories.
    git clone --no-checkout "$TPROXY_REPO" "$TPROXY_SRC"
  fi

  if [[ "$mode" == "validated" ]]; then
    target_desc="validated commit $TPROXY_INSTALL_COMMIT"
    log "Синхронизирую telegramdesktop/tproxy-server: $target_desc..."
    # Use the exact field-validated revision. A fresh full clone already contains
    # it. For an older shallow checkout, first try a direct fetch, then unshallow
    # the tracked branch as a compatibility fallback.
    if ! git -C "$TPROXY_SRC" cat-file -e "$TPROXY_INSTALL_COMMIT^{commit}" 2>/dev/null; then
      git -C "$TPROXY_SRC" fetch origin "$TPROXY_INSTALL_COMMIT" || {
        git -C "$TPROXY_SRC" fetch --unshallow origin "$TPROXY_BRANCH" 2>/dev/null || git -C "$TPROXY_SRC" fetch origin "$TPROXY_BRANCH"
      }
    fi
    git -C "$TPROXY_SRC" cat-file -e "$TPROXY_INSTALL_COMMIT^{commit}" 2>/dev/null || die "Validated tproxy-server commit недоступен в upstream repository."
    git -C "$TPROXY_SRC" reset --hard "$TPROXY_INSTALL_COMMIT"
    [[ "$(git -C "$TPROXY_SRC" rev-parse HEAD)" == "$TPROXY_INSTALL_COMMIT" ]] || die "Не удалось checkout validated tproxy-server commit."
  else
    target_desc="latest $TPROXY_BRANCH"
    log "Обновляю telegramdesktop/tproxy-server: $target_desc..."
    git -C "$TPROXY_SRC" fetch --depth 1 origin "$TPROXY_BRANCH"
    git -C "$TPROXY_SRC" reset --hard "origin/$TPROXY_BRANCH"
  fi

  UPSTREAM_COMMIT="$(git -C "$TPROXY_SRC" rev-parse HEAD)"
  ok "tproxy-server commit: $UPSTREAM_COMMIT ($mode)"
}

build_tproxy_server() {
  log "Тестирую и собираю WEB relay..."
  # Manager работает с umask 077 для защиты secrets. Upstream test suite,
  # однако, специально создаёт файл с mode 0444 и проверяет отказ вне
  # systemd credentials. Унаследованный umask 077 превращал 0444 в 0400
  # и ложно ронял upstream-тест. Для тестов/сборки используем стандартный 022.
  if ! (umask 022; cd "$TPROXY_SRC" && "$GO_BIN" test ./...); then
    die "Upstream test suite tproxy-server не прошёл; установка relay остановлена."
  fi
  local tmpbin; tmpbin="$(mktemp /tmp/tproxy-server.XXXXXX)"
  if ! (umask 022; cd "$TPROXY_SRC" && "$GO_BIN" build -trimpath -ldflags='-s -w' -o "$tmpbin" ./cmd/tproxy-server); then
    rm -f "$tmpbin"
    die "Не удалось собрать tproxy-server."
  fi
  install -o root -g root -m 0755 "$tmpbin" "$TPROXY_BIN"
  rm -f "$tmpbin"
  ok "Relay собран."
}

build_mtproxy_pinned() {
  log "Собираю официальный MTProxy на закреплённом commit $MTPROXY_COMMIT..."
  if [[ ! -d "$MTPROXY_SRC/.git" ]]; then
    rm -rf "$MTPROXY_SRC"
    git clone "$MTPROXY_REPO" "$MTPROXY_SRC"
  fi
  local origin
  origin="$(git -C "$MTPROXY_SRC" remote get-url origin 2>/dev/null || true)"
  [[ "$origin" == "$MTPROXY_REPO" || "$origin" == "${MTPROXY_REPO%.git}" ]] || die "У $MTPROXY_SRC неожиданный origin: $origin"
  git -C "$MTPROXY_SRC" fetch --tags origin
  git -C "$MTPROXY_SRC" cat-file -e "$MTPROXY_COMMIT^{commit}" 2>/dev/null || git -C "$MTPROXY_SRC" fetch origin "$MTPROXY_COMMIT"
  git -C "$MTPROXY_SRC" reset --hard "$MTPROXY_COMMIT"
  # Manager runs with umask 077, which made the upstream binary 0700 on the first
  # real VPS test. Build with a normal umask, then copy only the runtime binary
  # into our libexec directory with explicit permissions. The source tree can
  # remain root-private.
  if ! (umask 022; cd "$MTPROXY_SRC" && { make clean >/dev/null 2>&1 || true; make -j"$(nproc)"; }); then
    die "Не удалось собрать официальный MTProxy."
  fi
  [[ -x "$MTPROXY_SRC/objs/bin/mtproto-proxy" ]] || die "MTProxy не собрался."
  install -o root -g root -m 0755 "$MTPROXY_SRC/objs/bin/mtproto-proxy" "$MTPROXY_BIN"
  ok "Official MTProxy собран и установлен: $MTPROXY_BIN"
}

refresh_mtproxy_material() {
  log "Получаю официальный proxy-secret и proxy-multi.conf..."
  local sec_tmp cfg_tmp
  sec_tmp="$(mktemp)"; cfg_tmp="$(mktemp)"
  trap 'rm -f "$sec_tmp" "$cfg_tmp"' RETURN
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 https://core.telegram.org/getProxySecret -o "$sec_tmp"
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 https://core.telegram.org/getProxyConfig -o "$cfg_tmp"
  [[ "$(wc -c < "$sec_tmp")" -ge 100 ]] || die "proxy-secret подозрительно короткий."
  [[ "$(wc -c < "$cfg_tmp")" -ge 100 ]] || die "proxy-multi.conf подозрительно короткий."
  grep -q '^default ' "$cfg_tmp" || die "proxy-multi.conf не прошёл проверку."
  grep -q '^proxy_for ' "$cfg_tmp" || die "proxy-multi.conf не прошёл проверку."
  install -o root -g root -m 0600 "$sec_tmp" "$MTPROXY_DATA_DIR/proxy-secret"
  install -o root -g root -m 0600 "$cfg_tmp" "$MTPROXY_DATA_DIR/proxy-multi.conf"
  trap - RETURN
  rm -f "$sec_tmp" "$cfg_tmp"
}

write_global_env() {
  local upstream="${UPSTREAM_COMMIT:-}"
  if [[ -z "$upstream" && -f "$GLOBAL_ENV" ]]; then
    upstream="$( (unset TPROXY_UPSTREAM_COMMIT; source "$GLOBAL_ENV"; printf '%s' "${TPROXY_UPSTREAM_COMMIT:-}") )"
  fi
  [[ -n "$upstream" ]] || upstream=unknown
  {
    printf 'MANAGER_VERSION=%q\n' "$MANAGER_VERSION"
    printf 'TPROXY_UPSTREAM_COMMIT=%q\n' "$upstream"
    printf 'MTPROXY_COMMIT=%q\n' "$MTPROXY_COMMIT"
  } > "$GLOBAL_ENV"
  chmod 0600 "$GLOBAL_ENV"
}

write_runner_helpers() {
  cat > "$LIBEXEC_DIR/run-mtproxy" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${MTPROXY_SECRET:?}"
: "${MTPROXY_CLIENT_PORT:?}"
: "${MTPROXY_STATS_PORT:?}"
: "${MTPROXY_WORKERS:?}"
: "${MTPROXY_MAX_CONNECTIONS:?}"
: "${CREDENTIALS_DIRECTORY:?systemd credentials directory missing}"
exec /usr/local/libexec/twebproxy/mtproto-proxy \
  -u mtproxy \
  -p "$MTPROXY_STATS_PORT" \
  -H "$MTPROXY_CLIENT_PORT" \
  -S "$MTPROXY_SECRET" \
  --http-stats \
  --aes-pwd "$CREDENTIALS_DIRECTORY/proxy-secret" "$CREDENTIALS_DIRECTORY/proxy-multi.conf" \
  -M "$MTPROXY_WORKERS" \
  -C "$MTPROXY_MAX_CONNECTIONS"
EOF
  chmod 0755 "$LIBEXEC_DIR/run-mtproxy"

  cat > "$LIBEXEC_DIR/apply-firewall" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if nft list table inet twebproxy_backend >/dev/null 2>&1; then
  nft delete table inet twebproxy_backend
fi
if [[ -s /etc/twebproxy/firewall.nft ]]; then
  nft -f /etc/twebproxy/firewall.nft
fi
EOF
  chmod 0755 "$LIBEXEC_DIR/apply-firewall"

  cat > "$LIBEXEC_DIR/refresh-mtproxy-config" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
dest=/etc/twebproxy/mtproxy/proxy-multi.conf
tmp="$(mktemp /etc/twebproxy/mtproxy/proxy-multi.conf.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --output "$tmp" https://core.telegram.org/getProxyConfig
test "$(wc -c < "$tmp")" -ge 100
grep -q '^default ' "$tmp"
grep -q '^proxy_for ' "$tmp"
chown root:root "$tmp"
chmod 0600 "$tmp"
if [[ -e "$dest" ]] && cmp -s "$tmp" "$dest"; then
  rm -f "$tmp"; trap - EXIT; exit 0
fi
mv -f "$tmp" "$dest"; trap - EXIT
while read -r unit _; do
  [[ -n "$unit" ]] && systemctl try-restart "$unit" || true
done < <(systemctl list-units --type=service --all --no-legend 'twebproxy-mtproxy@*.service' 2>/dev/null || true)
EOF
  chmod 0755 "$LIBEXEC_DIR/refresh-mtproxy-config"
}

write_systemd_templates() {
  cat > "$SYSTEMD_DIR/twebproxy@.service" <<'EOF'
[Unit]
Description=Telegram WEB Proxy relay for %i
After=network-online.target twebproxy-firewall.service
Wants=network-online.target
Requires=twebproxy-firewall.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=tproxy
Group=tproxy
LoadCredential=config.json:/etc/twebproxy/instances/%i/config.json
LoadCredential=profiles.json:/etc/twebproxy/instances/%i/profiles.json
ExecStart=/usr/local/bin/tproxy-server -config %d/config.json
Restart=on-failure
RestartSec=3s
TimeoutStopSec=20s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectClock=true
ProtectControlGroups=true
ProtectHome=true
ProtectHostname=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectProc=invisible
ProtectSystem=strict
ProcSubset=pid
ReadOnlyPaths=-/srv/twebproxy/%i
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
CapabilityBoundingSet=
IPAddressDeny=any
IPAddressAllow=localhost
SystemCallArchitectures=native
SystemCallFilter=@system-service
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

  cat > "$SYSTEMD_DIR/twebproxy-mtproxy@.service" <<'EOF'
[Unit]
Description=Official Telegram MTProxy backend for %i
After=network-online.target twebproxy-firewall.service
Wants=network-online.target
Requires=twebproxy-firewall.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=mtproxy
Group=mtproxy
EnvironmentFile=/etc/twebproxy/backends/%i.env
LoadCredential=proxy-secret:/etc/twebproxy/mtproxy/proxy-secret
LoadCredential=proxy-multi.conf:/etc/twebproxy/mtproxy/proxy-multi.conf
ExecStart=/usr/local/libexec/twebproxy/run-mtproxy
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectHome=true
ProtectProc=invisible
ProtectSystem=strict
ProcSubset=pid
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

  cat > "$SYSTEMD_DIR/twebproxy-firewall.service" <<'EOF'
[Unit]
Description=Firewall for TWebProxy backend-only ports
# Debian/Ubuntu nftables.service may reload a ruleset that starts with "flush ruleset".
# PartOf + ordering makes our backend-only table get reapplied on nftables restart.
After=nftables.service
PartOf=nftables.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/twebproxy/apply-firewall
ExecReload=/usr/local/libexec/twebproxy/apply-firewall
ExecStop=-/usr/sbin/nft delete table inet twebproxy_backend
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat > "$SYSTEMD_DIR/twebproxy-refresh-mtproxy.service" <<'EOF'
[Unit]
Description=Refresh official MTProxy routing configuration for all TWebProxy backends
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/twebproxy/refresh-mtproxy-config
ProtectProc=invisible
ProcSubset=pid
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/etc/twebproxy/mtproxy
EOF

  cat > "$SYSTEMD_DIR/twebproxy-refresh-mtproxy.timer" <<'EOF'
[Unit]
Description=Daily official MTProxy routing refresh for TWebProxy

[Timer]
OnBootSec=10m
OnUnitActiveSec=1d
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable twebproxy-firewall.service >/dev/null 2>&1 || true
  systemctl enable --now twebproxy-refresh-mtproxy.timer >/dev/null 2>&1 || true
}

rebuild_firewall() {
  install -d -m 0700 "$BASE_DIR"
  local ports=() f p
  shopt -s nullglob
  for f in "$BACKENDS_DIR"/*.env; do
    # shellcheck disable=SC1090
    source "$f"
    ports+=("$MTPROXY_CLIENT_PORT" "$MTPROXY_STATS_PORT")
  done
  shopt -u nullglob

  if ((${#ports[@]} == 0)); then
    cat > "$FIREWALL_FILE" <<'EOF'
table inet twebproxy_backend {
  chain input {
    type filter hook input priority -5; policy accept;
  }
}
EOF
  else
    local joined
    joined="$(printf '%s\n' "${ports[@]}" | sort -n -u | paste -sd, -)"
    cat > "$FIREWALL_FILE" <<EOF
table inet twebproxy_backend {
  chain input {
    type filter hook input priority -5; policy accept;
    iifname != "lo" tcp dport { $joined } drop
  }
}
EOF
  fi
  systemctl daemon-reload
  systemctl enable --now twebproxy-firewall.service >/dev/null
  systemctl restart twebproxy-firewall.service
}

install_manager_copy() {
  local self="${BASH_SOURCE[0]}"
  if [[ -f "$self" ]]; then
    install -d -o root -g root -m 0700 "$PROJECT_DIR" "$LOG_DIR" "$LOG_MANAGER_DIR" "$LOG_RUNTIME_DIR" "$LOG_BUNDLE_DIR" "$LOG_FULL_DIR"
    install -o root -g root -m 0755 "$self" "$MANAGER_BIN"
    install -o root -g root -m 0755 "$self" "$PROJECT_MANAGER_COPY"
  fi
}

valid_manager_version() {
  [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

version_is_newer() {
  local candidate="$1" current="$2"
  valid_manager_version "$candidate" && valid_manager_version "$current" || return 1
  [[ "$candidate" != "$current" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$current" "$candidate" | sort -V | tail -n1)" == "$candidate" ]]
}

manager_update_cache_fresh() {
  [[ -f "$UPDATE_CACHE_FILE" ]] || return 1
  local now mtime
  now="$(date +%s)"
  mtime="$(stat -c %Y "$UPDATE_CACHE_FILE" 2>/dev/null || printf '0')"
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  (( now - mtime < MANAGER_UPDATE_CACHE_TTL ))
}

write_manager_update_cache() {
  local version="$1" ref="$2" source="$3"
  [[ ${EUID:-$(id -u)} -eq 0 ]] || return 0
  install -d -o root -g root -m 0700 "$PROJECT_DIR"
  {
    printf 'REMOTE_MANAGER_VERSION=%q\n' "$version"
    printf 'REMOTE_MANAGER_REF=%q\n' "$ref"
    printf 'REMOTE_MANAGER_SOURCE=%q\n' "$source"
    printf 'CHECKED_AT=%q\n' "$(date -Is)"
  } > "$UPDATE_CACHE_FILE"
  chmod 0600 "$UPDATE_CACHE_FILE"
}

load_manager_update_cache() {
  manager_update_cache_fresh || return 1
  unset REMOTE_MANAGER_VERSION REMOTE_MANAGER_REF REMOTE_MANAGER_SOURCE CHECKED_AT
  # shellcheck disable=SC1090
  source "$UPDATE_CACHE_FILE"
  valid_manager_version "${REMOTE_MANAGER_VERSION:-}" || return 1
  [[ -n "${REMOTE_MANAGER_REF:-}" && -n "${REMOTE_MANAGER_SOURCE:-}" ]] || return 1
}

fetch_manager_update_info() {
  local allow_cache="${1:-yes}" json tag version branch
  local best_version="" best_ref="" best_source=""
  unset REMOTE_MANAGER_VERSION REMOTE_MANAGER_REF REMOTE_MANAGER_SOURCE

  if [[ "$allow_cache" == "yes" ]] && load_manager_update_cache; then
    return 0
  fi
  command -v curl >/dev/null 2>&1 || return 1

  # Evaluate both the latest stable Release and VERSION on the repository branch.
  # If main is ahead of the latest GitHub Release, the newer repository version
  # is still visible; when versions are equal, the immutable release tag wins.
  json="$(curl -fsSL --connect-timeout 3 --max-time 8 --retry 1 \
    --proto '=https' --tlsv1.2 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: twebproxy-manager-update-check' \
    "$MANAGER_API_URL/releases/latest" 2>/dev/null || true)"
  if [[ -n "$json" ]]; then
    tag="$(grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$json" | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]+)"/\1/')"
    version="${tag#v}"
    if valid_manager_version "$version"; then
      best_version="$version"
      best_ref="$tag"
      best_source="release"
    fi
  fi

  for branch in "$MANAGER_DEFAULT_BRANCH" master; do
    version="$(curl -fsSL --connect-timeout 3 --max-time 8 --retry 1 \
      --proto '=https' --tlsv1.2 \
      -H 'User-Agent: twebproxy-manager-update-check' \
      "$MANAGER_RAW_URL/$branch/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
    if valid_manager_version "$version"; then
      if [[ -z "$best_version" ]] || version_is_newer "$version" "$best_version"; then
        best_version="$version"
        best_ref="$branch"
        best_source="branch"
      fi
      break
    fi
  done

  [[ -n "$best_version" ]] || return 1
  REMOTE_MANAGER_VERSION="$best_version"
  REMOTE_MANAGER_REF="$best_ref"
  REMOTE_MANAGER_SOURCE="$best_source"
  write_manager_update_cache "$best_version" "$best_ref" "$best_source"
  return 0
}

manager_check_update_impl() {
  local allow_cache="${1:-yes}"
  if ! fetch_manager_update_info "$allow_cache"; then
    warn "Не удалось проверить обновление manager на $MANAGER_REPO_URL"
    return 2
  fi

  echo "Manager:  local=$MANAGER_VERSION remote=$REMOTE_MANAGER_VERSION source=$REMOTE_MANAGER_SOURCE ref=$REMOTE_MANAGER_REF"
  if version_is_newer "$REMOTE_MANAGER_VERSION" "$MANAGER_VERSION"; then
    warn "Доступна новая версия TWebProxy Manager: $REMOTE_MANAGER_VERSION"
    echo "Обновить: sudo twebproxy manager-update"
    return 10
  fi
  if version_is_newer "$MANAGER_VERSION" "$REMOTE_MANAGER_VERSION"; then
    log "Локальная версия $MANAGER_VERSION новее опубликованной $REMOTE_MANAGER_VERSION."
    return 0
  fi
  ok "TWebProxy Manager $MANAGER_VERSION — актуальная версия."
  return 0
}

manager_check_update_cmd() {
  banner
  local rc=0
  if manager_check_update_impl no; then
    return 0
  else
    rc=$?
  fi
  # Availability of GitHub is not a proxy/runtime failure. The implementation
  # already printed the reason, so keep the administrative command non-fatal.
  [[ $rc -eq 10 || $rc -eq 2 ]] && return 0
  return "$rc"
}

set_global_manager_version() {
  local new_version="$1" upstream=unknown mtcommit="$MTPROXY_COMMIT"
  [[ -f "$GLOBAL_ENV" ]] || return 0
  upstream="$( (unset TPROXY_UPSTREAM_COMMIT; source "$GLOBAL_ENV"; printf '%s' "${TPROXY_UPSTREAM_COMMIT:-unknown}") )"
  mtcommit="$( (unset MTPROXY_COMMIT; source "$GLOBAL_ENV"; printf '%s' "${MTPROXY_COMMIT:-$mtcommit}") )"
  {
    printf 'MANAGER_VERSION=%q\n' "$new_version"
    printf 'TPROXY_UPSTREAM_COMMIT=%q\n' "$upstream"
    printf 'MTPROXY_COMMIT=%q\n' "$mtcommit"
  } > "$GLOBAL_ENV"
  chmod 0600 "$GLOBAL_ENV"
}

manager_update_cmd() {
  need_root; banner
  local force=0 candidate checksums expected actual embedded ref script_url checksum_url
  [[ "${1:-}" == "--force" ]] && force=1

  fetch_manager_update_info no || die "Не удалось получить информацию об обновлении с $MANAGER_REPO_URL"
  if (( ! force )) && ! version_is_newer "$REMOTE_MANAGER_VERSION" "$MANAGER_VERSION"; then
    if [[ "$REMOTE_MANAGER_VERSION" == "$MANAGER_VERSION" ]]; then
      ok "TWebProxy Manager $MANAGER_VERSION уже актуален."
      return 0
    fi
    die "Опубликованная версия $REMOTE_MANAGER_VERSION не новее локальной $MANAGER_VERSION. Для принудительной установки: manager-update --force"
  fi

  ref="$REMOTE_MANAGER_REF"
  script_url="$MANAGER_RAW_URL/$ref/twebproxy-manager.sh"
  checksum_url="$MANAGER_RAW_URL/$ref/SHA256SUMS"
  candidate="$(mktemp /tmp/twebproxy-manager.XXXXXX.sh)"
  checksums="$(mktemp /tmp/twebproxy-manager.XXXXXX.sha256)"
  trap 'rm -f "$candidate" "$checksums"' RETURN

  log "Скачиваю TWebProxy Manager $REMOTE_MANAGER_VERSION ($REMOTE_MANAGER_SOURCE/$ref)..."
  curl -fL --connect-timeout 5 --max-time 30 --retry 2 \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    -H 'User-Agent: twebproxy-manager-updater' \
    -o "$candidate" "$script_url"
  curl -fL --connect-timeout 5 --max-time 20 --retry 2 \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    -H 'User-Agent: twebproxy-manager-updater' \
    -o "$checksums" "$checksum_url" \
    || die "В $ref нет SHA256SUMS. Автообновление manager остановлено: release должен публиковать checksum."

  expected="$(awk '$2 == "twebproxy-manager.sh" {print $1; exit}' "$checksums")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "SHA256SUMS не содержит корректный hash для twebproxy-manager.sh"
  actual="$(sha256sum "$candidate" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "SHA-256 manager candidate не совпал с SHA256SUMS"

  bash -n "$candidate" || die "Скачанный manager не проходит bash -n"
  embedded="$(sed -nE 's/^MANAGER_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$candidate" | head -n1)"
  [[ "$embedded" == "$REMOTE_MANAGER_VERSION" ]] || die "VERSION mismatch: metadata=$REMOTE_MANAGER_VERSION script=${embedded:-unknown}"
  chmod 0755 "$candidate"
  TWEBPROXY_NO_LOG=1 "$candidate" --help >/dev/null || die "Скачанный manager не проходит self-smoke --help"

  install -d -o root -g root -m 0700 "$PROJECT_DIR"
  local backup_bin="$PROJECT_DIR/twebproxy-manager.previous.sh" backup_project="$PROJECT_DIR/twebproxy-manager.project.previous.sh"
  [[ -f "$MANAGER_BIN" ]] && cp -a "$MANAGER_BIN" "$backup_bin"
  [[ -f "$PROJECT_MANAGER_COPY" ]] && cp -a "$PROJECT_MANAGER_COPY" "$backup_project"
  if ! install -o root -g root -m 0755 "$candidate" "$MANAGER_BIN" \
     || ! install -o root -g root -m 0755 "$candidate" "$PROJECT_MANAGER_COPY"; then
    warn "Установка manager candidate не завершилась. Восстанавливаю предыдущую копию."
    [[ -f "$backup_bin" ]] && install -o root -g root -m 0755 "$backup_bin" "$MANAGER_BIN" || true
    [[ -f "$backup_project" ]] && install -o root -g root -m 0755 "$backup_project" "$PROJECT_MANAGER_COPY" || true
    die "Manager update откатан."
  fi
  rm -f "$backup_project"
  if ! set_global_manager_version "$REMOTE_MANAGER_VERSION"; then
    warn "Manager обновлён, но не удалось обновить metadata в global.env; следующий repair исправит metadata."
  fi
  rm -f "$UPDATE_CACHE_FILE"
  trap - RETURN
  rm -f "$candidate" "$checksums"
  ok "TWebProxy Manager обновлён: $MANAGER_VERSION -> $REMOTE_MANAGER_VERSION"
  echo "Следующий запуск 'twebproxy' уже использует новую версию. Backup: $PROJECT_DIR/twebproxy-manager.previous.sh"
}

fetch_manager_update_hint_info() {
  local version
  if load_manager_update_cache; then
    return 0
  fi
  command -v curl >/dev/null 2>&1 || return 1
  # The automatic hint is deliberately cheap: one short request to VERSION.
  # Full release/main evaluation is reserved for explicit check-update.
  version="$(curl -fsSL --connect-timeout 2 --max-time 3 \
    --proto '=https' --tlsv1.2 \
    -H 'User-Agent: twebproxy-manager-update-hint' \
    "$MANAGER_RAW_URL/$MANAGER_DEFAULT_BRANCH/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
  valid_manager_version "$version" || return 1
  REMOTE_MANAGER_VERSION="$version"
  REMOTE_MANAGER_REF="$MANAGER_DEFAULT_BRANCH"
  REMOTE_MANAGER_SOURCE="branch"
  write_manager_update_cache "$version" "$MANAGER_DEFAULT_BRANCH" branch
}

manager_update_hint() {
  # At most one quick check per interactive process. GitHub outage must never
  # make every menu redraw slow or prevent normal administration.
  (( MANAGER_UPDATE_HINT_ATTEMPTED == 0 )) || return 0
  MANAGER_UPDATE_HINT_ATTEMPTED=1
  if fetch_manager_update_hint_info 2>/dev/null && version_is_newer "$REMOTE_MANAGER_VERSION" "$MANAGER_VERSION"; then
    printf "%b[update]%b Доступен TWebProxy Manager %s (сейчас %s). Команда: twebproxy manager-update\n\n" \
      "$C_YELLOW" "$C_RESET" "$REMOTE_MANAGER_VERSION" "$MANAGER_VERSION"
  fi
  return 0
}

legacy_v1_detected() {
  [[ -f "$BASE_DIR/manager.env" || -f "$SYSTEMD_DIR/twebproxy.service" || -f "$SYSTEMD_DIR/mtproxy.service" ]]
}

check_no_legacy_v1() {
  if legacy_v1_detected && [[ ! -d "$INSTANCES_DIR" ]]; then
    die "Обнаружена установка TWebProxy Manager v0.1. Перед v0.2 сделай backup и удали/мигрируй старую single-instance установку; v0.2 намеренно не перезаписывает её автоматически."
  fi
}

core_install_cmd() {
  need_root; need_systemd; check_platform; banner
  check_no_legacy_v1
  install_base_deps
  prepare_users_and_dirs
  ensure_go
  sync_tproxy_upstream
  build_tproxy_server
  build_mtproxy_pinned
  refresh_mtproxy_material
  write_runner_helpers
  write_systemd_templates
  rebuild_firewall
  write_global_env
  install_manager_copy
  ok "База TWebProxy установлена. Теперь добавь hostname через: twebproxy add"
}

ensure_core() {
  if core_installed; then return 0; fi
  warn "Базовая часть TWebProxy ещё не установлена. Установлю её сейчас."
  core_install_cmd
}

port_registered() {
  local needle="$1" f
  shopt -s nullglob
  for f in "$INSTANCES_DIR"/*/instance.env; do
    if ( unset RELAY_PORT ADMIN_PORT; source "$f"; [[ "${RELAY_PORT:-}" == "$needle" || "${ADMIN_PORT:-}" == "$needle" ]] ); then
      shopt -u nullglob; return 0
    fi
  done
  for f in "$BACKENDS_DIR"/*.env; do
    if ( unset MTPROXY_CLIENT_PORT MTPROXY_STATS_PORT; source "$f"; [[ "${MTPROXY_CLIENT_PORT:-}" == "$needle" || "${MTPROXY_STATS_PORT:-}" == "$needle" ]] ); then
      shopt -u nullglob; return 0
    fi
  done
  shopt -u nullglob
  return 1
}

port_listening() {
  local p="$1"
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$"
}

port_available() {
  local p="$1"
  is_valid_port "$p" && ! port_registered "$p" && ! port_listening "$p"
}

next_free_port() {
  local start="$1" end="${2:-65535}" p
  for ((p=start; p<=end; p++)); do
    if port_available "$p"; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

ask_internal_port() {
  local label="$1" default="$2" p
  while true; do
    p="$(ask "$label" "$default")"
    is_valid_port "$p" || { warn "Некорректный порт."; continue; }
    (( 10#$p >= 1024 )) || { warn "Внутренние сервисы работают без root; используй порт >= 1024."; continue; }
    port_available "$p" || { warn "Порт $p уже занят или зарегистрирован TWebProxy."; continue; }
    printf '%s' "$p"; return 0
  done
}

check_dns_for_host() {
  local host="$1" a public_ip
  a="$(dig +short A "$host" | head -n1 || true)"
  public_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$a" ]] || { warn "DNS A для $host пока не резолвится."; return 1; }
  log "DNS A: $host -> $a"
  if [[ -n "$public_ip" && "$a" != "$public_ip" ]]; then
    warn "A-запись ($a) не совпадает с публичным IPv4 сервера ($public_ip)."
    return 1
  fi
  return 0
}

carrier_choose() {
  local cm
  cm="$(choose 'Carrier mode:' \
    'https — консервативный baseline' \
    'https-lanes — отдельные HTTP/2 lanes' \
    'websocket — один мультиплексированный WSS' \
    'websocket-lanes — отдельный WSS на поток')"
  case "$cm" in 1) printf https;; 2) printf https-lanes;; 3) printf websocket;; 4) printf websocket-lanes;; esac
}

make_unique_placeholder() {
  local host="$1" d nonce words1 words2
  d="$(site_dir "$host")"; install -d -m 0755 "$d"
  nonce="$(openssl rand -hex 8)"
  words1=("Status" "Service" "Gateway" "Workspace" "Endpoint" "Portal" "Node")
  words2=("available" "online" "ready" "active" "running")
  local w1="${words1[RANDOM % ${#words1[@]}]}" w2="${words2[RANDOM % ${#words2[@]}]}"
  cat > "$d/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$w1</title>
<style>
html{font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f7f7f8;color:#202124}
main{max-width:720px;margin:12vh auto;padding:24px}section{background:#fff;padding:28px;border:1px solid #e5e7eb;border-radius:14px}
h1{font-size:1.8rem;margin:0 0 10px}p{line-height:1.55;color:#4b5563}small{color:#9ca3af}
</style>
</head>
<body><main><section><h1>$w1</h1><p>The service is $w2.</p><small>$nonce</small></section></main></body>
</html>
EOF
  chmod 0644 "$d/index.html"
}

prepare_site_for_instance() {
  local host="$1" d; d="$(site_dir "$host")"
  case "$SITE_MODE" in
    placeholder)
      make_unique_placeholder "$host"
      warn "Автозаглушка пригодна для теста, но для постоянной эксплуатации лучше заменить её своим настоящим сайтом."
      ;;
    directory)
      [[ -d "$SOURCE_SITE_DIR" && -r "$SOURCE_SITE_DIR/index.html" ]] || die "В $SOURCE_SITE_DIR нет читаемого index.html."
      install -d -m 0755 "$d"; rm -rf "${d:?}/"*; cp -a "$SOURCE_SITE_DIR/." "$d/"; chown -R root:root "$d"
      find "$d" -type d -exec chmod 0755 {} +; find "$d" -type f -exec chmod 0644 {} +
      ;;
    upstream)
      [[ "$SITE_UPSTREAM" =~ ^http://(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]):[1-9][0-9]{0,4}$ ]] || die "public_upstream должен быть numeric loopback URL."
      ;;
    *) die "Неизвестный SITE_MODE=$SITE_MODE" ;;
  esac
}

write_instance_config() {
  local host="$1" d source_line
  load_instance "$host"
  d="$(instance_dir "$host")"
  case "$SITE_MODE" in
    placeholder|directory) source_line="\"public_dir\": \"$(site_dir "$host")\"," ;;
    upstream) source_line="\"public_upstream\": \"$SITE_UPSTREAM\"," ;;
    *) die "Неизвестный SITE_MODE=$SITE_MODE" ;;
  esac
  cat > "$d/config.json" <<EOF
{
  "public_hostname": "$HOSTNAME",
  "listen": "127.0.0.1:$RELAY_PORT",
  "admin_listen": "127.0.0.1:$ADMIN_PORT",
  $source_line
  "profiles_file": "/run/credentials/twebproxy@$host.service/profiles.json",
  "enable_pprof": false,
  "limits": {
    "max_header_bytes": 16384,
    "max_body_bytes": 2097152,
    "max_frame_payload": 1048576,
    "carrier_batch_bytes": 2097152,
    "max_streams_per_session": 128,
    "max_closed_stream_ids": 4096,
    "max_pending_per_session": 33554432,
    "max_pending_global": 536870912,
    "max_pending_items_per_session": 16384,
    "max_pending_items_global": 262144,
    "max_sessions_per_ip": 0,
    "max_sessions_global": 128,
    "max_streams_global": 4096,
    "max_backend_dials_in_flight": 256,
    "new_sessions_per_minute": 600,
    "new_sessions_burst": 128,
    "new_streams_per_minute": 6000,
    "new_streams_burst": 512,
    "max_bootstraps_per_ip": 0,
    "max_bootstraps_global": 512,
    "new_bootstraps_per_minute": 1200,
    "new_bootstraps_burst": 256,
    "max_profiles": 32
  },
  "timeouts": {
    "backend_dial": "5s",
    "long_poll": "25s",
    "reconnect_grace": "2m",
    "bootstrap_lifetime": "2m",
    "read_header": "10s",
    "idle": "75s",
    "shutdown": "15s"
  }
}
EOF
  # The service receives config.json via systemd LoadCredential, so the source
  # can remain root-only and no root-owned state directory needs to be traversable
  # by the tproxy account.
  chown root:root "$d/config.json"; chmod 0600 "$d/config.json"
}

rebuild_profiles_json() {
  local host="$1" d f arr='[]' name secret carrier backend
  d="$(profile_dir "$host")"
  [[ -d "$d" ]] || die "Нет каталога профилей у $host"
  shopt -s nullglob
  local files=("$d"/*.env)
  shopt -u nullglob
  ((${#files[@]} > 0)) || die "У $host должен оставаться хотя бы один профиль."
  for f in "${files[@]}"; do
    unset PROFILE_NAME SECRET CARRIER_MODE BACKEND_PORT STATS_PORT WORKERS MAX_CONNECTIONS PROFILE_CREATED_AT || true
    # shellcheck disable=SC1090
    source "$f"
    name="$PROFILE_NAME"; secret="$SECRET"; carrier="$CARRIER_MODE"; backend="127.0.0.1:$BACKEND_PORT"
    arr="$(jq -c --argjson a "$arr" --arg n "$name" --arg s "$secret" --arg b "$backend" --arg c "$carrier" '$a + [{name:$n,secret:$s,backend:$b,carrier_mode:$c}]' <<<null)"
  done
  jq -n --argjson profiles "$arr" '{profiles:$profiles}' > "$(profiles_json "$host")"
  chown root:root "$(profiles_json "$host")"; chmod 0400 "$(profiles_json "$host")"
}

validate_instance() {
  local host="$1"
  "$TPROXY_BIN" -config "$(instance_dir "$host")/config.json" -profiles-file "$(profiles_json "$host")" -check >/dev/null
}

wait_profile_backend_ready() {
  local host="$1" profile="$2" id unit i
  id="$(backend_id "$host" "$profile")"
  unit="twebproxy-mtproxy@$id.service"
  load_profile "$host" "$profile"
  for i in {1..15}; do
    if systemctl is-active --quiet "$unit" \
      && ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${BACKEND_PORT}$"; then
      return 0
    fi
    sleep 1
  done
  systemctl --no-pager --full status "$unit" || true
  journalctl -u "$unit" -n 100 --no-pager || true
  die "MTProxy backend $host/$profile не стал ready."
}

start_profile_backend() {
  local host="$1" profile="$2" id; id="$(backend_id "$host" "$profile")"
  systemctl reset-failed "twebproxy-mtproxy@$id.service" >/dev/null 2>&1 || true
  systemctl enable --now "twebproxy-mtproxy@$id.service" >/dev/null
  systemctl restart "twebproxy-mtproxy@$id.service"
  wait_profile_backend_ready "$host" "$profile"
}

stop_profile_backend() {
  local host="$1" profile="$2" id; id="$(backend_id "$host" "$profile")"
  systemctl disable --now "twebproxy-mtproxy@$id.service" >/dev/null 2>&1 || true
}

start_all_backends() {
  local host="$1" p
  while read -r p; do [[ -n "$p" ]] && start_profile_backend "$host" "$p"; done < <(list_profiles_array "$host")
}

restart_relay_wait_ready() {
  local host="$1" admin="" ready="" i
  load_instance "$host"; admin="$ADMIN_PORT"
  systemctl reset-failed "twebproxy@$host.service" >/dev/null 2>&1 || true
  systemctl enable --now "twebproxy@$host.service" >/dev/null
  systemctl restart "twebproxy@$host.service"
  for i in {1..25}; do
    if curl -fsS --max-time 2 "http://127.0.0.1:$admin/readyz" >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
  done
  if [[ -z "$ready" ]]; then
    systemctl --no-pager --full status "twebproxy@$host.service" || true
    journalctl -u "twebproxy@$host.service" -n 80 --no-pager || true
    die "Relay $host не стал ready."
  fi
}

managed_frontend_family() {
  local h mode f caddy_seen=0 nginx_seen=0
  while read -r h; do
    [[ -n "$h" ]] || continue
    f="$(instance_env "$h")"; [[ -f "$f" ]] || continue
    mode="$( (unset TLS_MODE; source "$f"; printf '%s' "${TLS_MODE:-manual}") )"
    case "$mode" in caddy) caddy_seen=1;; nginx-*) nginx_seen=1;; esac
  done < <(list_hosts_array)
  if (( caddy_seen && nginx_seen )); then printf mixed
  elif (( caddy_seen )); then printf caddy
  elif (( nginx_seen )); then printf nginx
  fi
}

check_frontend_compatibility() {
  local requested="$1" family existing
  case "$requested" in caddy) family=caddy;; nginx-*) family=nginx;; manual) return 0;; *) return 1;; esac
  existing="$(managed_frontend_family)"
  [[ -z "$existing" || "$existing" == "$family" ]] || die "TWebProxy уже использует managed $existing на 80/443. Для нового hostname выбери тот же frontend либо Manual."
}

check_public_listener_owner() {
  local family="$1" p owner_line
  for p in 80 443; do
    owner_line="$(ss -H -ltnp "sport = :$p" 2>/dev/null | head -n1 || true)"
    [[ -n "$owner_line" ]] || continue
    case "$family" in
      caddy) grep -qi 'caddy' <<<"$owner_line" || die "TCP/$p уже занят не Caddy: $owner_line. Используй существующий frontend через Manual либо освободи порт." ;;
      nginx) grep -qi 'nginx' <<<"$owner_line" || die "TCP/$p уже занят не Nginx: $owner_line. Используй существующий frontend через Manual либо освободи порт." ;;
    esac
  done
}

install_caddy() {
  if ! command -v caddy >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y caddy || die "Не удалось установить Caddy. Используй Nginx или manual."
  fi
  systemctl unmask caddy 2>/dev/null || true
}

remove_caddy_block() {
  local host="$1" cf="${2:-/etc/caddy/Caddyfile}" tmp
  [[ -f "$cf" ]] || return 0
  tmp="$(mktemp)"
  awk -v b="# BEGIN TWEBPROXY $host" -v e="# END TWEBPROXY $host" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    !skip {print}
  ' "$cf" > "$tmp"
  cat "$tmp" > "$cf"; rm -f "$tmp"
}

configure_caddy_host() {
  local host="$1" relay="$2" cf=/etc/caddy/Caddyfile family candidate block backup
  family="$(managed_frontend_family)"
  [[ -z "$family" || "$family" == caddy ]] || die "Другой TWebProxy-инстанс уже использует Nginx на 80/443. Нельзя параллельно запустить managed Caddy."
  check_public_listener_owner caddy
  install_caddy
  [[ -f "$cf" ]] || touch "$cf"

  candidate="$(mktemp /tmp/twebproxy-Caddyfile.XXXXXX)"
  block="$(mktemp /tmp/twebproxy-caddy-block.XXXXXX)"
  cp -a "$cf" "$candidate"
  remove_caddy_block "$host" "$candidate"

  if grep -Eq "^[[:space:]]*${host//./\\.}([[:space:]{,]|$)" "$candidate"; then
    rm -f "$candidate" "$block"
    die "В Caddyfile уже есть $host вне управляемого блока TWebProxy."
  fi

  cat > "$block" <<EOF
# BEGIN TWEBPROXY $host
$host {
    encode zstd gzip
    reverse_proxy 127.0.0.1:$relay {
        transport http {
            response_header_timeout 40s
        }
    }
    log {
        output discard
    }
}
# END TWEBPROXY $host
EOF
  # Format only the generated block. Never rewrite unrelated user-managed sites.
  caddy fmt --overwrite "$block" >/dev/null 2>&1 || true
  printf '\n' >> "$candidate"
  cat "$block" >> "$candidate"
  rm -f "$block"

  if ! caddy validate --config "$candidate" --adapter caddyfile; then
    rm -f "$candidate"
    die "Candidate Caddyfile не прошёл validate; активный Caddyfile не изменён."
  fi

  backup="$cf.before-twebproxy.$(date +%Y%m%d%H%M%S)"
  cp -a "$cf" "$backup"
  cat "$candidate" > "$cf"
  rm -f "$candidate"

  systemctl enable --now caddy
  if ! systemctl reload caddy; then
    warn "Caddy reload не прошёл; возвращаю предыдущий Caddyfile."
    cat "$backup" > "$cf"
    caddy validate --config "$cf" --adapter caddyfile >/dev/null 2>&1 || true
    systemctl reload caddy || systemctl restart caddy || true
    die "Caddy frontend rollback выполнен после неуспешного reload."
  fi
}

nginx_common_install() {
  local family; family="$(managed_frontend_family)"
  [[ -z "$family" || "$family" == nginx ]] || die "Другой TWebProxy-инстанс уже использует Caddy на 80/443. Нельзя параллельно запустить managed Nginx."
  check_public_listener_owner nginx
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y nginx
  install -d -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
  cat > /etc/nginx/conf.d/twebproxy-map.conf <<'EOF'
map $http_upgrade $twebproxy_connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
}

nginx_domain_conflict() {
  local host="$1" own="/etc/nginx/sites-available/twebproxy-$host.conf"
  if grep -RqsE "server_name[[:space:]]+${host//./\\.}([[:space:];]|$)" /etc/nginx 2>/dev/null; then
    [[ -f "$own" ]] || die "Nginx уже содержит server_name $host вне TWebProxy."
  fi
}

write_nginx_tls_conf() {
  local host="$1" relay="$2" cert="$3" key="$4" f="/etc/nginx/sites-available/twebproxy-$host.conf"
  cat > "$f" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $host;
    location /.well-known/acme-challenge/ { root /var/lib/twebproxy/acme; }
    location / { return 301 https://\$host\$request_uri; }
    access_log off;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $host;
    ssl_certificate $cert;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    access_log off;

    location / {
        proxy_pass http://127.0.0.1:$relay;
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
  ln -sfn "$f" "/etc/nginx/sites-enabled/twebproxy-$host.conf"
}

configure_nginx_le() {
  local host="$1" relay="$2" email="$3"
  nginx_common_install; nginx_domain_conflict "$host"
  export DEBIAN_FRONTEND=noninteractive; apt-get install -y certbot
  install -d -m 0755 /var/lib/twebproxy/acme
  local f="/etc/nginx/sites-available/twebproxy-$host.conf"
  cat > "$f" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $host;
    location /.well-known/acme-challenge/ { root /var/lib/twebproxy/acme; }
    location / { return 200 "ok\n"; add_header Content-Type text/plain; }
    access_log off;
}
EOF
  ln -sfn "$f" "/etc/nginx/sites-enabled/twebproxy-$host.conf"
  nginx -t; systemctl enable --now nginx; systemctl reload nginx
  certbot certonly --webroot -w /var/lib/twebproxy/acme -d "$host" --non-interactive --agree-tos --email "$email" --keep-until-expiring
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/twebproxy-nginx-reload <<'EOF'
#!/usr/bin/env bash
set -e
if systemctl is-active --quiet nginx.service; then
  nginx -t && systemctl reload nginx.service
fi
EOF
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/twebproxy-nginx-reload
  write_nginx_tls_conf "$host" "$relay" "/etc/letsencrypt/live/$host/fullchain.pem" "/etc/letsencrypt/live/$host/privkey.pem"
  nginx -t; systemctl reload nginx
}

configure_nginx_custom() {
  local host="$1" relay="$2" cert="$3" key="$4"
  nginx_common_install; nginx_domain_conflict "$host"
  [[ -r "$cert" ]] || die "Сертификат не читается: $cert"
  [[ -r "$key" ]] || die "Ключ не читается: $key"
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || die "Некорректный PEM certificate."
  openssl pkey -in "$key" -noout >/dev/null 2>&1 || die "Некорректный PEM key."
  write_nginx_tls_conf "$host" "$relay" "$cert" "$key"
  nginx -t; systemctl enable --now nginx; systemctl reload nginx
}

configure_tls_for_instance() {
  local host="$1"; load_instance "$host"
  case "$TLS_MODE" in
    caddy) configure_caddy_host "$host" "$RELAY_PORT" ;;
    nginx-le) configure_nginx_le "$host" "$RELAY_PORT" "$ACME_EMAIL" ;;
    nginx-custom) configure_nginx_custom "$host" "$RELAY_PORT" "$NGINX_CERT" "$NGINX_KEY" ;;
    manual) warn "Manual TLS: публичный $host:443 должен проксировать ВЕСЬ hostname на 127.0.0.1:$RELAY_PORT с исходным Host." ;;
    *) die "Неизвестный TLS_MODE=$TLS_MODE" ;;
  esac
}

remove_reverse_proxy_for_instance() {
  local host="$1"; load_instance "$host"
  case "$TLS_MODE" in
    caddy)
      [[ -f /etc/caddy/Caddyfile ]] || return 0
      local backup candidate
      backup="/etc/caddy/Caddyfile.before-twebproxy-remove.$(date +%Y%m%d%H%M%S)"
      candidate="$(mktemp /tmp/twebproxy-Caddyfile-remove.XXXXXX)"
      cp -a /etc/caddy/Caddyfile "$backup"
      cp -a /etc/caddy/Caddyfile "$candidate"
      remove_caddy_block "$host" "$candidate"
      if caddy validate --config "$candidate" --adapter caddyfile >/dev/null 2>&1; then
        cat "$candidate" > /etc/caddy/Caddyfile
        if ! systemctl reload caddy; then
          warn "Caddy reload после удаления блока не прошёл; восстанавливаю backup."
          cat "$backup" > /etc/caddy/Caddyfile
          systemctl reload caddy || systemctl restart caddy || true
        fi
      else
        warn "Caddy candidate после удаления блока невалиден; активный Caddyfile оставлен без изменений."
      fi
      rm -f "$candidate"
      ;;
    nginx-*)
      rm -f "/etc/nginx/sites-enabled/twebproxy-$host.conf" "/etc/nginx/sites-available/twebproxy-$host.conf"
      nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
      ;;
  esac
}

configure_ufw() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  if yesno "UFW активен. Разрешить TCP 80 и 443?" y; then ufw allow 80/tcp; ufw allow 443/tcp; fi
}

collect_instance_settings() {
  HOSTNAME="$(ask 'Hostname WEB-proxy (без https://)' '')"; HOSTNAME="${HOSTNAME,,}"
  is_valid_hostname "$HOSTNAME" || die "Нужен lowercase ASCII/ACE hostname вида proxy.example.com"
  instance_exists "$HOSTNAME" && die "Инстанс $HOSTNAME уже существует."

  echo
  printf "%bWEB Proxy использует публичный HTTPS/443 — порт в клиенте не задаётся.%b\n" "$C_YELLOW" "$C_RESET"
  local auto rdef adef
  if yesno "Внутренние relay/admin порты подобрать автоматически?" y; then
    RELAY_PORT="$(next_free_port 18080 19999)" || die "Нет свободного relay port."
    ADMIN_PORT="$(next_free_port $((RELAY_PORT+1)) 20999)" || die "Нет свободного admin port."
  else
    rdef="$(next_free_port 18080 19999)"; RELAY_PORT="$(ask_internal_port 'Relay port (loopback)' "$rdef")"
    adef="$(next_free_port 18081 20999)"; ADMIN_PORT="$(ask_internal_port 'Admin/metrics port (loopback)' "$adef")"
  fi
  [[ "$RELAY_PORT" != "$ADMIN_PORT" ]] || die "Порты должны быть разными."

  local sm
  sm="$(choose 'Обычный сайт на hostname:' \
    'Уникальная автозаглушка (только для теста)' \
    'Скопировать мой статический сайт' \
    'Проксировать существующее web-приложение на loopback')"
  SITE_UPSTREAM=""; SOURCE_SITE_DIR=""
  case "$sm" in
    1) SITE_MODE=placeholder ;;
    2) SITE_MODE=directory; SOURCE_SITE_DIR="$(ask 'Путь к каталогу с index.html' '')" ;;
    3) SITE_MODE=upstream; SITE_UPSTREAM="$(ask 'Loopback URL' 'http://127.0.0.1:3000')" ;;
  esac

  local tm
  tm="$(choose 'SSL / reverse proxy:' \
    'Caddy — автоматический сертификат' \
    'Nginx + Let’s Encrypt' \
    'Nginx + мой certificate/key' \
    'Manual — фронт 443 уже настроен')"
  ACME_EMAIL=""; NGINX_CERT=""; NGINX_KEY=""
  case "$tm" in
    1) TLS_MODE=caddy ;;
    2) TLS_MODE=nginx-le; ACME_EMAIL="$(ask 'Email для Let’s Encrypt' '')"; [[ "$ACME_EMAIL" == *@*.* ]] || die "Некорректный email." ;;
    3) TLS_MODE=nginx-custom; NGINX_CERT="$(ask 'Путь к fullchain.pem' '')"; NGINX_KEY="$(ask 'Путь к privkey.pem' '')" ;;
    4) TLS_MODE=manual ;;
  esac
  check_frontend_compatibility "$TLS_MODE"
  CREATED_AT="$(date -Is)"
}

collect_profile_settings() {
  local host="$1" suggested="${2:-default}" auto bdef sdef
  while true; do
    PROFILE_NAME="$(ask 'Имя профиля/секрета' "$suggested")"; PROFILE_NAME="${PROFILE_NAME,,}"
    is_valid_profile_name "$PROFILE_NAME" || { warn "Имя: a-z, 0-9, _ и -, максимум 32 символа."; continue; }
    [[ ! -f "$(profile_env "$host" "$PROFILE_NAME")" ]] || { warn "Профиль уже существует."; continue; }
    break
  done

  if yesno "Сгенерировать новый 16-byte secret?" y; then SECRET="$(openssl rand -hex 16)"; else
    read -r -s -p "Secret (32 hex либо dd+32 hex): " SECRET; echo
    is_valid_secret "$SECRET" || die "Некорректный secret."
  fi
  CARRIER_MODE="$(carrier_choose)"

  if yesno "Backend/stats порты подобрать автоматически?" y; then
    BACKEND_PORT="$(next_free_port 23980 26999)" || die "Нет свободного backend port."
    STATS_PORT="$(next_free_port 28980 31999)" || die "Нет свободного stats port."
  else
    bdef="$(next_free_port 23980 26999)"; BACKEND_PORT="$(ask_internal_port 'MTProxy backend port' "$bdef")"
    sdef="$(next_free_port 28980 31999)"; STATS_PORT="$(ask_internal_port 'MTProxy stats port' "$sdef")"
  fi
  [[ "$BACKEND_PORT" != "$STATS_PORT" ]] || die "Backend и stats ports должны отличаться."

  WORKERS="$(ask 'MTProxy workers' '1')"
  MAX_CONNECTIONS="$(ask 'Max connections на worker' '4096')"
  [[ "$WORKERS" =~ ^[1-9][0-9]*$ ]] && (( WORKERS <= 256 )) || die "workers: 1..256"
  [[ "$MAX_CONNECTIONS" =~ ^[1-9][0-9]*$ ]] || die "max connections должен быть > 0"
  PROFILE_CREATED_AT="$(date -Is)"
}

add_instance_cmd() {
  need_root; need_systemd; check_platform; banner; ensure_core
  collect_instance_settings

  echo
  printf "%bПервый профиль для %s%b\n" "$C_BOLD" "$HOSTNAME" "$C_RESET"
  local host="$HOSTNAME"
  collect_profile_settings "$host" default

  echo
  cat <<EOF
План:
  Hostname:       $host
  Public:         HTTPS/443
  Relay:          127.0.0.1:$RELAY_PORT
  Admin/metrics:  127.0.0.1:$ADMIN_PORT
  TLS:            $TLS_MODE
  Site:           $SITE_MODE
  Profile:        $PROFILE_NAME
  Carrier:        $CARRIER_MODE
  MTProxy:        :$BACKEND_PORT (будет закрыт firewall снаружи)
  MTProxy stats:  :$STATS_PORT (будет закрыт firewall снаружи)
EOF
  yesno "Создать?" y || exit 0

  if [[ "$TLS_MODE" != manual ]]; then
    check_dns_for_host "$host" || yesno "DNS пока не совпадает. Продолжить?" n || exit 1
  fi

  save_instance "$host"
  prepare_site_for_instance "$host"
  save_profile "$host" "$PROFILE_NAME"
  rebuild_profiles_json "$host"
  write_instance_config "$host"
  validate_instance "$host"
  rebuild_firewall
  start_profile_backend "$host" "$PROFILE_NAME"
  restart_relay_wait_ready "$host"
  configure_tls_for_instance "$host"
  configure_ufw
  if ! audit_instance_impl "$host"; then
    die "Инстанс создан, но isolation audit для $host не пройден."
  fi
  install_manager_copy
  ok "Инстанс $host создан и прошёл isolation audit."
  show_instance_cmd "$host"
}

repair_instance_cmd() {
  need_root; need_systemd; check_platform; banner; ensure_core
  local host="${1:-}"
  [[ -n "$host" ]] || host="$(select_instance)"
  instance_exists "$host" || die "Нет $host"

  log "Проверяю и восстанавливаю runtime для $host..."
  # Recreate generated artifacts from the canonical per-instance/profile state.
  prepare_users_and_dirs
  # repair doubles as a safe manager-runtime upgrade path: regenerate helpers and
  # systemd templates from the currently running manager version before restarts.
  write_runner_helpers
  write_systemd_templates
  rebuild_profiles_json "$host"
  write_instance_config "$host"
  validate_instance "$host"
  rebuild_firewall
  systemctl daemon-reload
  start_all_backends "$host"
  restart_relay_wait_ready "$host"
  configure_tls_for_instance "$host"
  configure_ufw
  if ! audit_instance_impl "$host"; then
    die "Runtime восстановлен, но isolation audit для $host не пройден."
  fi
  write_global_env
  install_manager_copy
  ok "Инстанс $host восстановлен и прошёл readiness/isolation checks."
  show_instance_cmd "$host"
}

profile_add_cmd() {
  need_root; ensure_core; banner
  local host="${1:-}"; [[ -n "$host" ]] || host="$(select_instance)"
  instance_exists "$host" || die "Нет $host"
  local count; count="$(count_profiles "$host")"; (( count < 32 )) || die "Upstream max_profiles по текущему конфигу: 32."
  collect_profile_settings "$host" "profile$((count+1))"
  save_profile "$host" "$PROFILE_NAME"
  rebuild_profiles_json "$host"
  validate_instance "$host"
  rebuild_firewall
  start_profile_backend "$host" "$PROFILE_NAME"
  warn "Добавление профиля перезапускает relay и сбрасывает активные WEB-сессии; Telegram переподключится автоматически."
  restart_relay_wait_ready "$host"
  ok "Профиль $PROFILE_NAME добавлен."
  show_profile_cmd "$host" "$PROFILE_NAME"
}

profile_delete_cmd() {
  need_root; banner
  local host="${1:-}" profile="${2:-}"
  [[ -n "$host" ]] || host="$(select_instance)"
  [[ -n "$profile" ]] || profile="$(select_profile "$host")"
  (( $(count_profiles "$host") > 1 )) || die "Нельзя удалить последний профиль. Удали весь hostname через 'twebproxy delete'."
  load_profile "$host" "$profile"
  warn "Удалится secret $profile и его backend. Клиенты с этим secret сразу перестанут подключаться."
  yesno "Удалить профиль $profile?" n || exit 0
  stop_profile_backend "$host" "$profile"
  rm -f "$(profile_env "$host" "$profile")" "$(backend_env "$host" "$profile")"
  rebuild_profiles_json "$host"; validate_instance "$host"; rebuild_firewall; restart_relay_wait_ready "$host"
  ok "Профиль $profile удалён."
}

profile_rotate_cmd() {
  need_root; banner
  local host="${1:-}" profile="${2:-}" new_secret backend_secret f bfile
  [[ -n "$host" ]] || host="$(select_instance)"
  [[ -n "$profile" ]] || profile="$(select_profile "$host")"
  load_profile "$host" "$profile"
  if yesno "Сгенерировать новый secret?" y; then new_secret="$(openssl rand -hex 16)"; else
    read -r -s -p "Новый secret: " new_secret; echo; is_valid_secret "$new_secret" || die "Некорректный secret."
  fi
  SECRET="$new_secret"
  save_profile "$host" "$profile"
  rebuild_profiles_json "$host"; validate_instance "$host"
  start_profile_backend "$host" "$profile"
  restart_relay_wait_ready "$host"
  ok "Secret $profile заменён. Старый больше не работает."
  show_profile_cmd "$host" "$profile"
}

profile_carrier_cmd() {
  need_root; banner
  local host="${1:-}" profile="${2:-}"
  [[ -n "$host" ]] || host="$(select_instance)"
  [[ -n "$profile" ]] || profile="$(select_profile "$host")"
  load_profile "$host" "$profile"
  CARRIER_MODE="$(carrier_choose)"
  save_profile "$host" "$profile"
  rebuild_profiles_json "$host"; validate_instance "$host"; restart_relay_wait_ready "$host"
  ok "Carrier профиля $profile: $CARRIER_MODE"
}

select_instance() {
  local hosts=() h n
  while read -r h; do [[ -n "$h" ]] && hosts+=("$h"); done < <(list_hosts_array)
  ((${#hosts[@]} > 0)) || die "Нет настроенных hostname."
  if ((${#hosts[@]} == 1)); then printf '%s' "${hosts[0]}"; return; fi
  n="$(choose 'Выбери hostname:' "${hosts[@]}")"; printf '%s' "${hosts[$((n-1))]}"
}

select_profile() {
  local host="$1" profiles=() p n
  while read -r p; do [[ -n "$p" ]] && profiles+=("$p"); done < <(list_profiles_array "$host")
  ((${#profiles[@]} > 0)) || die "У $host нет профилей."
  if ((${#profiles[@]} == 1)); then printf '%s' "${profiles[0]}"; return; fi
  n="$(choose 'Выбери профиль:' "${profiles[@]}")"; printf '%s' "${profiles[$((n-1))]}"
}

list_cmd() {
  need_root; banner
  local host state pcount tls relay admin
  printf "%-34s %-9s %-8s %-14s %-8s %-8s\n" "HOSTNAME" "STATE" "SECRETS" "TLS" "RELAY" "ADMIN"
  printf '%*s\n' 88 '' | tr ' ' '-'
  while read -r host; do
    [[ -n "$host" ]] || continue
    load_instance "$host"; tls="$TLS_MODE"; relay="$RELAY_PORT"; admin="$ADMIN_PORT"; pcount="$(count_profiles "$host")"
    state="$(systemctl is-active "twebproxy@$host.service" 2>/dev/null || true)"
    printf "%-34s %-9s %-8s %-14s %-8s %-8s\n" "$host" "$state" "$pcount" "$tls" "$relay" "$admin"
  done < <(list_hosts_array)
  [[ "$(count_instances)" -gt 0 ]] || echo "Нет настроенных WEB proxy."
}

profiles_list_cmd() {
  need_root
  local host="${1:-}" p state masked
  [[ -n "$host" ]] || host="$(select_instance)"
  printf "%bПрофили %s%b\n" "$C_BOLD" "$host" "$C_RESET"
  printf "%-18s %-18s %-16s %-9s %-9s %-12s\n" "PROFILE" "CARRIER" "SECRET" "BACKEND" "STATS" "STATE"
  printf '%*s\n' 90 '' | tr ' ' '-'
  while read -r p; do
    [[ -n "$p" ]] || continue
    load_profile "$host" "$p"
    masked="${SECRET:0:6}…${SECRET: -4}"
    state="$(systemctl is-active "twebproxy-mtproxy@$(backend_id "$host" "$p").service" 2>/dev/null || true)"
    printf "%-18s %-18s %-16s %-9s %-9s %-12s\n" "$p" "$CARRIER_MODE" "$masked" "$BACKEND_PORT" "$STATS_PORT" "$state"
  done < <(list_profiles_array "$host")
}

show_profile_cmd() {
  local host="${1:-}" profile="${2:-}"
  [[ -n "$host" ]] || host="$(select_instance)"; [[ -n "$profile" ]] || profile="$(select_profile "$host")"
  load_profile "$host" "$profile"
  cat <<EOF
Hostname: $host
Profile:  $profile
Carrier:  $CARRIER_MODE
Secret:   $SECRET
Link:     https://t.me/webproxy?server=$host&secret=$SECRET
TG link:  tg://webproxy?server=$host&secret=$SECRET
EOF
}

show_instance_cmd() {
  local host="${1:-}" p
  [[ -n "$host" ]] || host="$(select_instance)"
  load_instance "$host"
  cat <<EOF
Hostname:      $host
Public:        https://$host/  (Telegram WEB: 443 fixed)
Relay:         127.0.0.1:$RELAY_PORT
Admin/metrics: 127.0.0.1:$ADMIN_PORT
TLS:           $TLS_MODE
Site:          $SITE_MODE
Profiles:      $(count_profiles "$host")
EOF
  echo
  while read -r p; do [[ -n "$p" ]] && show_profile_cmd "$host" "$p" && echo; done < <(list_profiles_array "$host")
}

manual_snippet_cmd() {
  need_root
  local host="${1:-}"
  [[ -n "$host" ]] || host="$(select_instance)"
  load_instance "$host"
  cat <<EOF
# Caddy — весь hostname должен идти через relay
$host {
    encode zstd gzip
    reverse_proxy 127.0.0.1:$RELAY_PORT {
        transport http {
            response_header_timeout 40s
        }
    }
    log {
        output discard
    }
}

# Nginx — HTTPS server{}; пути сертификатов подставь свои
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $host;

    ssl_certificate     /PATH/TO/fullchain.pem;
    ssl_certificate_key /PATH/TO/privkey.pem;
    access_log off;

    location / {
        proxy_pass http://127.0.0.1:$RELAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 90s;
        proxy_send_timeout 90s;
        proxy_buffering off;
        client_max_body_size 2m;
    }
}

# Для Nginx один раз нужен map в http{}:
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

Важно: не выноси статический сайт отдельным location мимо relay и не логируй raw URI/Authorization.
Публичный Telegram WEB endpoint обязан оставаться HTTPS/443.
EOF
}

restart_cmd() {
  need_root; need_systemd; banner
  local host="${1:-}" p
  [[ -n "$host" ]] || host="$(select_instance)"
  instance_exists "$host" || die "Нет $host"
  while read -r p; do
    [[ -n "$p" ]] && start_profile_backend "$host" "$p"
  done < <(list_profiles_array "$host")
  restart_relay_wait_ready "$host"
  ok "$host перезапущен и ready."
}

status_cmd() {
  need_root; banner
  local host="${1:-}" p
  [[ -n "$host" ]] || host="$(select_instance)"; load_instance "$host"
  echo "Host: $host | TLS: $TLS_MODE"
  systemctl --no-pager --full status "twebproxy@$host.service" || true
  while read -r p; do
    [[ -n "$p" ]] || continue
    echo
    systemctl --no-pager --full status "twebproxy-mtproxy@$(backend_id "$host" "$p").service" || true
  done < <(list_profiles_array "$host")
  echo
  curl -fsS "http://127.0.0.1:$ADMIN_PORT/healthz" && echo " <- healthz" || true
  curl -fsS "http://127.0.0.1:$ADMIN_PORT/readyz" && echo " <- readyz" || true
}

stats_cmd() {
  need_root; banner
  local host="${1:-}" p relay_metrics mtstats
  [[ -n "$host" ]] || host="$(select_instance)"; load_instance "$host"
  echo "== Relay metrics: $host =="
  relay_metrics="$(curl -fsS --max-time 4 "http://127.0.0.1:$ADMIN_PORT/metrics" 2>/dev/null || true)"
  if [[ -n "$relay_metrics" ]]; then
    printf '%s\n' "$relay_metrics" | grep -Ev '^#|^$' | grep -Ei 'session|stream|backend|bootstrap|pending|byte|reject|error|limit' | head -n 80 || true
  else
    warn "Не удалось получить relay /metrics."
  fi
  echo
  echo "== MTProxy backend stats =="
  while read -r p; do
    [[ -n "$p" ]] || continue
    load_profile "$host" "$p"
    printf "\n%b[%s]%b carrier=%s backend=%s stats=%s\n" "$C_CYAN" "$p" "$C_RESET" "$CARRIER_MODE" "$BACKEND_PORT" "$STATS_PORT"
    mtstats="$(curl -fsS --max-time 3 "http://127.0.0.1:$STATS_PORT/stats" 2>/dev/null || true)"
    if [[ -n "$mtstats" ]]; then
      printf '%s\n' "$mtstats" | grep -Ei 'connection|active|traffic|byte|packet|query|target|ready|total' | head -n 80 || printf '%s\n' "$mtstats" | head -n 30
    else
      warn "Нет ответа stats у $p."
    fi
  done < <(list_profiles_array "$host")
  echo
  printf "%bПримечание:%b upstream даёт сессии/потоки и backend connection stats, но не идентифицирует реальных Telegram-пользователей.\n" "$C_DIM" "$C_RESET"
}

listener_lines_for_port() {
  local port="$1"
  ss -H -ltnp "sport = :$port" 2>/dev/null || true
}

listener_line_for_port() {
  local port="$1"
  listener_lines_for_port "$port" | head -n1 || true
}

listener_addrs_for_port() {
  local port="$1"
  listener_lines_for_port "$port" | awk '{print $4}' | sort -u
}

is_loopback_listener_addr() {
  local addr="$1" port="$2"
  [[ "$addr" == "127.0.0.1:$port" || "$addr" == "[::1]:$port" || "$addr" == "::1:$port" ]]
}

port_has_only_loopback_listeners() {
  local port="$1" addr seen=0
  while read -r addr; do
    [[ -n "$addr" ]] || continue
    seen=1
    is_loopback_listener_addr "$addr" "$port" || return 1
  done < <(listener_addrs_for_port "$port")
  (( seen == 1 ))
}

firewall_has_backend_port() {
  local port="$1" rules guard
  rules="$(nft list table inet twebproxy_backend 2>/dev/null || true)"
  [[ -n "$rules" ]] || return 1
  guard="$(grep -F 'iifname != "lo" tcp dport' <<<"$rules" || true)"
  [[ -n "$guard" ]] || return 1
  grep -Eq "(^|[^0-9])${port}([^0-9]|$)" <<<"$guard"
}

audit_instance_impl() {
  local host="$1" failures=0 warnings=0 p unit line addr
  instance_exists "$host" || { warn "AUDIT FAIL: нет instance state для $host"; return 1; }
  load_instance "$host"

  echo "== isolation audit: $host =="

  if systemctl is-active --quiet "twebproxy@$host.service"; then
    ok "relay service active"
  else
    warn "AUDIT FAIL: relay service не active"
    failures=$((failures+1))
  fi

  for spec in "relay:$RELAY_PORT" "admin:$ADMIN_PORT"; do
    local label="${spec%%:*}" port="${spec##*:}" addrs
    addrs="$(listener_addrs_for_port "$port")"
    if [[ -z "$addrs" ]]; then
      warn "AUDIT FAIL: $label port $port не слушается"
      failures=$((failures+1))
    elif port_has_only_loopback_listeners "$port"; then
      ok "$label $(paste -sd, <<<"$addrs") — loopback only"
    else
      warn "AUDIT FAIL: $label port $port имеет non-loopback listener(s): $(paste -sd, <<<"$addrs")"
      failures=$((failures+1))
    fi
  done

  if systemctl is-active --quiet twebproxy-firewall.service && nft list table inet twebproxy_backend >/dev/null 2>&1; then
    ok "backend firewall service/table active"
  else
    warn "AUDIT FAIL: backend firewall service/table отсутствует"
    failures=$((failures+1))
  fi

  if (( $(count_profiles "$host") == 0 )); then
    warn "AUDIT FAIL: у $host нет profiles/backends"
    failures=$((failures+1))
  fi

  while read -r p; do
    [[ -n "$p" ]] || continue
    load_profile "$host" "$p"
    unit="twebproxy-mtproxy@$(backend_id "$host" "$p").service"

    if systemctl is-active --quiet "$unit"; then
      ok "$p: MTProxy backend active"
    else
      warn "AUDIT FAIL: $p backend service не active"
      failures=$((failures+1))
    fi

    if systemctl cat "$unit" 2>/dev/null | grep -Eq '^RestrictAddressFamilies=.*AF_NETLINK'; then
      ok "$p: MTProxy sandbox включает AF_NETLINK"
    else
      warn "AUDIT WARN: $p unit без AF_NETLINK; запусти repair текущей версией manager"
      warnings=$((warnings+1))
    fi

    for spec in "backend:$BACKEND_PORT" "stats:$STATS_PORT"; do
      local label="${spec%%:*}" port="${spec##*:}" addrs
      addrs="$(listener_addrs_for_port "$port")"
      if [[ -z "$addrs" ]]; then
        warn "AUDIT FAIL: $p $label port $port не слушается"
        failures=$((failures+1))
        continue
      fi

      if firewall_has_backend_port "$port"; then
        ok "$p: $label port $port покрыт nftables"
      else
        warn "AUDIT FAIL: $p $label port $port не найден в backend firewall rule"
        failures=$((failures+1))
      fi

      if port_has_only_loopback_listeners "$port"; then
        ok "$p: $label listener(s) $(paste -sd, <<<"$addrs") — loopback only"
      else
        # Inspect every socket on the port. v0.2.5 looked only at the first ss row,
        # which could incorrectly report "loopback only" when another worker had
        # a wildcard socket on the same port.
        log "$p: $label listener(s) $(paste -sd, <<<"$addrs"); external isolation обеспечивается nftables"
      fi
    done

    if ! curl -fsS --max-time 3 "http://127.0.0.1:$STATS_PORT/stats" >/dev/null 2>&1; then
      warn "AUDIT WARN: $p stats endpoint не ответил на loopback"
      warnings=$((warnings+1))
    fi
  done < <(list_profiles_array "$host")

  if [[ "$TLS_MODE" != manual ]]; then
    # Strict verification: no -k. A managed frontend is not healthy if DNS, the
    # certificate chain, hostname verification or HTTPS request fails.
    if curl -fsS --max-time 10 --proto '=https' --tlsv1.2 -o /dev/null "https://$host/" >/dev/null 2>&1; then
      ok "public HTTPS + TLS verification PASS"
    else
      warn "AUDIT FAIL: public HTTPS/TLS verification failed (DNS, certificate chain, hostname or frontend)"
      failures=$((failures+1))
    fi
  fi

  if (( failures > 0 )); then
    warn "AUDIT RESULT: FAIL ($failures critical, $warnings warnings)"
    return 1
  fi
  ok "AUDIT RESULT: PASS ($warnings warnings)"
  return 0
}

audit_cmd() {
  need_root; need_systemd; banner
  local host="${1:-}"
  [[ -n "$host" ]] || host="$(select_instance)"
  audit_instance_impl "$host"
}

diagnose_cmd() {
  need_root; banner
  local host="${1:-}" p
  [[ -n "$host" ]] || host="$(select_instance)"; load_instance "$host"
  echo "== systemd =="
  systemctl is-active "twebproxy@$host.service" || true
  while read -r p; do [[ -n "$p" ]] && systemctl is-active "twebproxy-mtproxy@$(backend_id "$host" "$p").service" || true; done < <(list_profiles_array "$host")
  echo; echo "== listeners =="
  ss -lntp | grep -E ":(80|443|${RELAY_PORT}|${ADMIN_PORT})([[:space:]]|$)" || true
  while read -r p; do
    [[ -n "$p" ]] || continue; load_profile "$host" "$p"
    ss -lntp | grep -E ":(${BACKEND_PORT}|${STATS_PORT})([[:space:]]|$)" || true
  done < <(list_profiles_array "$host")
  echo; echo "== health =="
  curl -v --max-time 5 "http://127.0.0.1:$ADMIN_PORT/healthz" 2>&1 || true
  curl -v --max-time 5 "http://127.0.0.1:$ADMIN_PORT/readyz" 2>&1 || true
  echo; echo "== local public surface =="
  curl -I --max-time 5 -H "Host: $host" "http://127.0.0.1:$RELAY_PORT/" || true
  echo; echo "== DNS =="
  dig +short A "$host" || true; dig +short AAAA "$host" || true
  echo; echo "== public HTTPS =="
  curl -I --max-time 10 "https://$host/" || true
  echo; echo "== certificate =="
  timeout 10 openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates || true
  echo; echo "== backend firewall =="
  nft list table inet twebproxy_backend || true
  echo
  audit_instance_impl "$host" || true
  echo; echo "== recent logs =="
  journalctl -u "twebproxy@$host.service" --since '20 minutes ago' --no-pager -n 120 || true
  while read -r p; do [[ -n "$p" ]] && journalctl -u "twebproxy-mtproxy@$(backend_id "$host" "$p").service" --since '20 minutes ago' --no-pager -n 60 || true; done < <(list_profiles_array "$host")
}

delete_instance_cmd() {
  need_root; banner
  local host="${1:-}" p
  [[ -n "$host" ]] || host="$(select_instance)"; instance_exists "$host" || die "Нет $host"
  warn "Будет удалён hostname $host, все его secrets/backends и управляемый reverse-proxy block."
  yesno "Удалить $host?" n || exit 0
  load_instance "$host"
  systemctl disable --now "twebproxy@$host.service" >/dev/null 2>&1 || true
  while read -r p; do
    [[ -n "$p" ]] || continue
    stop_profile_backend "$host" "$p"
    rm -f "$(backend_env "$host" "$p")"
  done < <(list_profiles_array "$host")
  remove_reverse_proxy_for_instance "$host"
  rm -rf "$(instance_dir "$host")" "$(site_dir "$host")"
  rebuild_firewall
  ok "$host удалён."
}

update_cmd() {
  need_root; need_systemd; check_platform; banner; ensure_core
  install_base_deps; ensure_go; sync_tproxy_upstream latest
  local candidate backup host was_ready=0 failed=0
  candidate="$(mktemp /tmp/tproxy-candidate.XXXXXX)"; backup="$(mktemp /tmp/tproxy-old.XXXXXX)"
  if ! (umask 022; cd "$TPROXY_SRC" && "$GO_BIN" test ./...); then
    rm -f "$candidate" "$backup"
    die "Upstream test suite tproxy-server не прошёл; update отменён до замены binary."
  fi
  if ! (umask 022; cd "$TPROXY_SRC" && "$GO_BIN" build -trimpath -ldflags='-s -w' -o "$candidate" ./cmd/tproxy-server); then
    rm -f "$candidate" "$backup"
    die "Не удалось собрать candidate tproxy-server; update отменён."
  fi
  chmod 0755 "$candidate"
  while read -r host; do
    [[ -n "$host" ]] || continue
    "$candidate" -config "$(instance_dir "$host")/config.json" -profiles-file "$(profiles_json "$host")" -check >/dev/null || die "Новая версия не проходит config check для $host"
  done < <(list_hosts_array)
  cp -a "$TPROXY_BIN" "$backup"
  install -o root -g root -m 0755 "$candidate" "$TPROXY_BIN"
  rm -f "$candidate"
  while read -r host; do
    [[ -n "$host" ]] || continue
    systemctl restart "twebproxy@$host.service"
    load_instance "$host"
    if ! curl -fsS --retry 8 --retry-delay 1 --max-time 3 "http://127.0.0.1:$ADMIN_PORT/healthz" >/dev/null 2>&1; then failed=1; break; fi
  done < <(list_hosts_array)
  if (( failed )); then
    warn "Новый relay не прошёл health-check. Откатываю binary."
    install -o root -g root -m 0755 "$backup" "$TPROXY_BIN"
    while read -r host; do [[ -n "$host" ]] && systemctl restart "twebproxy@$host.service" || true; done < <(list_hosts_array)
    rm -f "$backup"; die "Update откатан."
  fi
  rm -f "$backup"
  write_global_env; install_manager_copy
  ok "Relay обновлён до $UPSTREAM_COMMIT."
}

core_uninstall_cmd() {
  need_root; banner
  (( $(count_instances) == 0 )) || die "Сначала удали все hostname через 'twebproxy delete'."
  warn "Удалится база TWebProxy, systemd templates, relay binary и официальный MTProxy build."
  yesno "Удалить core?" n || exit 0
  systemctl disable --now twebproxy-refresh-mtproxy.timer twebproxy-firewall.service >/dev/null 2>&1 || true
  if nft list table inet twebproxy_backend >/dev/null 2>&1; then nft delete table inet twebproxy_backend || true; fi
  rm -f "$SYSTEMD_DIR/twebproxy@.service" "$SYSTEMD_DIR/twebproxy-mtproxy@.service" "$SYSTEMD_DIR/twebproxy-firewall.service" "$SYSTEMD_DIR/twebproxy-refresh-mtproxy.service" "$SYSTEMD_DIR/twebproxy-refresh-mtproxy.timer"
  rm -rf "$BASE_DIR" "$LIBEXEC_DIR" "$TPROXY_SRC" "$MTPROXY_SRC"
  rm -f "$TPROXY_BIN"
  systemctl daemon-reload
  ok "Core удалён. Manager оставлен: $MANAGER_BIN"
  ok "Логи сохранены: $LOG_DIR"
}

latest_manager_log() {
  local f
  f="$(find "$LOG_MANAGER_DIR" -maxdepth 1 -type f -name '*.log' ! -path "${CURRENT_LOG:-/nonexistent}" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
  [[ -n "$f" ]] && printf '%s' "$f"
}

journal_current_unit() {
  local unit="$1" max_lines="${2:-200}" since
  since="$(systemctl show "$unit" -p ActiveEnterTimestamp --value 2>/dev/null || true)"
  if [[ -n "$since" && "$since" != "n/a" ]]; then
    journalctl -u "$unit" --since "$since" -n "$max_lines" --no-pager -o short-iso-precise || true
  else
    journalctl -u "$unit" -n "$max_lines" --no-pager -o short-iso-precise || true
  fi
}

collect_history_snapshot() {
  local mode="${1:-safe}" label="${2:-history}" ts out host p unit filter_cmd
  [[ "$mode" == "safe" || "$mode" == "full" ]] || die "history mode: safe|full"
  if [[ "$mode" == "full" ]]; then
    install -d -o root -g root -m 0700 "$LOG_FULL_DIR"
  else
    install -d -o root -g root -m 0700 "$LOG_RUNTIME_DIR"
  fi
  ts="$(date '+%Y%m%d-%H%M%S')"
  if [[ "$mode" == "full" ]]; then
    out="$LOG_FULL_DIR/${ts}-${label}-full.log"
    filter_cmd="strip_ansi_stream"
  else
    out="$LOG_RUNTIME_DIR/${ts}-${label}.log"
    filter_cmd="sanitize_log_stream"
  fi

  {
    echo "TWebProxy bounded history snapshot"
    echo "mode=$mode"
    echo "created_at=$(date -Is)"
    echo "window=24h; bounded journals only"
    echo
    echo "== manager log index (latest 30) =="
    find "$LOG_MANAGER_DIR" -maxdepth 1 -type f -name '*.log' -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %f\n' 2>/dev/null | sort -r | head -n 30 || true
    echo
    while read -r host; do
      [[ -n "$host" ]] || continue
      echo "################################################################"
      echo "HOST HISTORY: $host"
      echo "################################################################"
      echo "-- relay journal: last 24h / max 160 --"
      journalctl -u "twebproxy@$host.service" --since '24 hours ago' -n 160 --no-pager -o short-iso-precise || true
      while read -r p; do
        [[ -n "$p" ]] || continue
        unit="twebproxy-mtproxy@$(backend_id "$host" "$p").service"
        echo "-- backend journal: $p / last 24h / max 120 --"
        journalctl -u "$unit" --since '24 hours ago' -n 120 --no-pager -o short-iso-precise || true
      done < <(list_profiles_array "$host")
      echo
    done < <(list_hosts_array)
  } 2>&1 | $filter_cmd > "$out"
  chmod 0600 "$out"
  printf '%s' "$out"
}

copy_recent_files() {
  local src="$1" dst="$2" pattern="$3" limit="$4" exclude1="${5:-}" exclude2="${6:-}" f count=0
  local files=()
  [[ -d "$src" ]] || return 0
  install -d -m 0700 "$dst"
  mapfile -t files < <(find "$src" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
  for f in "${files[@]}"; do
    [[ -n "$f" ]] || continue
    [[ -n "$exclude1" && "$f" == "$exclude1" ]] && continue
    [[ -n "$exclude2" && "$f" == "$exclude2" ]] && continue
    cp -a "$f" "$dst/"
    count=$((count+1))
    (( count >= limit )) && break
  done
  return 0
}

collect_runtime_snapshot() {
  local mode="${1:-safe}" label="${2:-runtime}" ts out host p unit filter_cmd rc
  [[ "$mode" == "safe" || "$mode" == "full" ]] || die "snapshot mode: safe|full"
  if [[ "$mode" == "full" ]]; then
    install -d -o root -g root -m 0700 "$LOG_FULL_DIR"
  else
    install -d -o root -g root -m 0700 "$LOG_RUNTIME_DIR"
  fi
  ts="$(date '+%Y%m%d-%H%M%S')"
  if [[ "$mode" == "full" ]]; then
    out="$LOG_FULL_DIR/${ts}-${label}-full.log"
    filter_cmd="strip_ansi_stream"
  else
    out="$LOG_RUNTIME_DIR/${ts}-${label}.log"
    filter_cmd="sanitize_log_stream"
  fi

  {
    echo "TWebProxy runtime snapshot"
    echo "mode=$mode"
    echo "created_at=$(date -Is)"
    echo "manager_version=$MANAGER_VERSION"
    echo "manager_repo=$MANAGER_REPO_URL"
    echo "manager_path=${PROJECT_MANAGER_COPY:-unknown}"
    [[ -f "$GLOBAL_ENV" ]] && grep -E '^(MANAGER_VERSION|VERSION|TPROXY_UPSTREAM_COMMIT|MTPROXY_COMMIT)=' "$GLOBAL_ENV" || true
    echo
    echo "== system =="
    uname -a || true
    [[ -f /etc/os-release ]] && cat /etc/os-release || true
    command -v systemd >/dev/null 2>&1 && systemd --version | head -n3 || true
    command -v go >/dev/null 2>&1 && go version || true
    echo
    echo "== time / hostname =="
    date -Is || true
    hostnamectl 2>/dev/null || hostname || true
    echo
    echo "== network addresses/routes =="
    ip -br addr 2>/dev/null || true
    ip route show table all 2>/dev/null || true
    ip -6 route show table all 2>/dev/null || true
    echo
    echo "== listeners =="
    ss -lntup 2>/dev/null || ss -lntp || true
    echo
    echo "== firewall =="
    nft list table inet twebproxy_backend || true
    command -v ufw >/dev/null 2>&1 && ufw status verbose || true
    echo
    echo "== binaries / source =="
    [[ -x "$TPROXY_BIN" ]] && { ls -l "$TPROXY_BIN"; sha256sum "$TPROXY_BIN"; } || true
    [[ -x "$MTPROXY_BIN" ]] && { ls -l "$MTPROXY_BIN"; sha256sum "$MTPROXY_BIN"; } || true
    [[ -e "$MTPROXY_SRC/objs/bin/mtproto-proxy" ]] && { echo "-- MTProxy build artifact (source tree) --"; ls -l "$MTPROXY_SRC/objs/bin/mtproto-proxy"; } || true
    stat "$MTPROXY_DATA_DIR" "$MTPROXY_DATA_DIR/proxy-secret" "$MTPROXY_DATA_DIR/proxy-multi.conf" 2>/dev/null || true
    [[ -d "$TPROXY_SRC/.git" ]] && { git -C "$TPROXY_SRC" status --short --branch; git -C "$TPROXY_SRC" rev-parse HEAD; } || true
    [[ -d "$MTPROXY_SRC/.git" ]] && { git -C "$MTPROXY_SRC" status --short --branch; git -C "$MTPROXY_SRC" rev-parse HEAD; } || true
    echo
    echo "== systemd templates =="
    systemctl cat twebproxy@.service 2>/dev/null || true
    systemctl cat twebproxy-mtproxy@.service 2>/dev/null || true
    systemctl cat twebproxy-firewall.service 2>/dev/null || true
    systemctl cat twebproxy-refresh-mtproxy.service 2>/dev/null || true
    systemctl cat twebproxy-refresh-mtproxy.timer 2>/dev/null || true
    echo

    while read -r host; do
      [[ -n "$host" ]] || continue
      echo "################################################################"
      echo "HOST: $host"
      echo "################################################################"
      echo "-- DNS --"
      getent ahosts "$host" 2>/dev/null || true
      command -v dig >/dev/null 2>&1 && { dig +short A "$host"; dig +short AAAA "$host"; } || true
      echo "-- isolation audit --"
      audit_instance_impl "$host" || true
      echo "-- relay status --"
      systemctl --no-pager --full status "twebproxy@$host.service" || true
      echo "-- relay properties --"
      systemctl show "twebproxy@$host.service" -p Id -p LoadState -p ActiveState -p SubState -p MainPID -p ExecMainStatus -p FragmentPath -p DropInPaths -p User -p Group -p LimitNOFILE -p Restart || true
      echo "-- relay journal (current activation / max 220) --"
      journal_current_unit "twebproxy@$host.service" 220
      if instance_exists "$host"; then
        load_instance "$host"
        echo "-- health --"
        curl -vfsS --max-time 5 "http://127.0.0.1:$ADMIN_PORT/healthz" 2>&1 || true; echo
        curl -vfsS --max-time 5 "http://127.0.0.1:$ADMIN_PORT/readyz" 2>&1 || true; echo
        echo "-- external HTTPS strict verification --"
        if curl -fsS --max-time 10 --proto '=https' --tlsv1.2 -o /dev/null "https://$host/"; then
          echo "STRICT_TLS=PASS"
        else
          rc=$?
          echo "STRICT_TLS=FAIL rc=$rc"
        fi
        echo "-- external HTTPS debug handshake (verification disabled intentionally) --"
        curl -vkI --max-time 10 "https://$host/" 2>&1 || true
        echo "-- certificate metadata --"
        timeout 10 openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null \
          | openssl x509 -noout -subject -issuer -serial -fingerprint -sha256 -dates -ext subjectAltName 2>/dev/null || true
        echo "-- instance file permissions --"
        stat "$(instance_env "$host")" "$(instance_dir "$host")/config.json" "$(profiles_json "$host")" 2>/dev/null || true
        echo "-- instance path traversal --"
        command -v namei >/dev/null 2>&1 && namei -l "$(instance_dir "$host")/config.json" "$(profiles_json "$host")" 2>/dev/null || true

        if [[ "$mode" == "full" ]]; then
          echo "-- FULL instance.env --"
          cat "$(instance_env "$host")" 2>/dev/null || true
          echo "-- FULL config.json --"
          cat "$(instance_dir "$host")/config.json" 2>/dev/null || true
          echo "-- FULL profiles.json (CONTAINS WEB SECRETS) --"
          cat "$(profiles_json "$host")" 2>/dev/null || true
        fi
      fi

      while read -r p; do
        [[ -n "$p" ]] || continue
        unit="twebproxy-mtproxy@$(backend_id "$host" "$p").service"
        echo "-- profile: $p / $unit --"
        systemctl --no-pager --full status "$unit" || true
        systemctl show "$unit" -p Id -p LoadState -p ActiveState -p SubState -p MainPID -p ExecMainStatus -p FragmentPath -p User -p Group -p LimitNOFILE -p Restart || true
        echo "-- backend journal (current activation / max 180) --"
        journal_current_unit "$unit" 180
        if [[ "$mode" == "full" ]]; then
          echo "-- FULL profile env: $p (CONTAINS WEB SECRET) --"
          cat "$(profile_env "$host" "$p")" 2>/dev/null || true
          echo "-- FULL backend env: $p (CONTAINS MTPROXY SECRET) --"
          cat "$(backend_env "$host" "$p")" 2>/dev/null || true
        fi
      done < <(list_profiles_array "$host")

      if [[ "$mode" == "full" ]]; then
        echo "-- frontend configs (public config only; TLS private key bytes are NEVER copied) --"
        if [[ -f /etc/caddy/Caddyfile ]]; then
          echo "### managed Caddy block for $host"
          awk -v b="# BEGIN TWEBPROXY $host" -v e="# END TWEBPROXY $host" '
            $0 == b {show=1}
            show {print}
            $0 == e {show=0}
          ' /etc/caddy/Caddyfile || true
        fi
        [[ -f "/etc/nginx/sites-enabled/twebproxy-$host.conf" ]] && { echo "### /etc/nginx/sites-enabled/twebproxy-$host.conf"; cat "/etc/nginx/sites-enabled/twebproxy-$host.conf"; } || true
        [[ -f "/etc/nginx/sites-available/twebproxy-$host.conf" ]] && { echo "### /etc/nginx/sites-available/twebproxy-$host.conf"; cat "/etc/nginx/sites-available/twebproxy-$host.conf"; } || true
        command -v nginx >/dev/null 2>&1 && { echo "### nginx -t"; nginx -t 2>&1 || true; } || true
        command -v caddy >/dev/null 2>&1 && [[ -f /etc/caddy/Caddyfile ]] && { echo "### caddy validate"; caddy validate --config /etc/caddy/Caddyfile 2>&1 || true; } || true
      fi
      echo
    done < <(list_hosts_array)
  } 2>&1 | $filter_cmd > "$out"
  chmod 0600 "$out"
  printf '%s' "$out"
}

logs_collect_cmd() {
  need_root; banner
  local mode="safe" out
  [[ "${1:-}" == "--full" ]] && mode="full"
  [[ -z "${1:-}" || "${1:-}" == "--full" ]] || die "Использование: twebproxy logs-collect [--full]"
  out="$(collect_runtime_snapshot "$mode" runtime)"
  ok "Runtime snapshot сохранён: $out"
  if [[ "$mode" == "full" ]]; then
    warn "FULL snapshot содержит WEB/MTProxy secrets. TLS/SSH private keys и root/sudo credentials не собираются."
  fi
}

write_security_notice() {
  local path="$1" mode="$2"
  cat > "$path" <<EOF
TWebProxy diagnostic bundle
Created: $(date -Is)
Manager: v$MANAGER_VERSION
Mode: $mode

This archive is intended for troubleshooting a test server.
Normal manager transcripts are redacted.
The shareable bundle contains a current-state snapshot plus bounded recent history;
full persistent history remains on the server under /opt/twebproxy-manager/logs.
$( [[ "$mode" == "full" ]] && printf '%s\n' 'FULL runtime snapshot may contain Telegram WEB Proxy and MTProxy secrets.' || printf '%s\n' 'Runtime snapshot and bundled history are redacted.' )

Never intentionally collected by TWebProxy Manager:
- root/sudo passwords;
- /etc/shadow or password databases;
- SSH private keys;
- TLS private key file contents.

The archive can still contain hostnames, public IP addresses, ports, service logs,
configuration, certificate metadata, and in FULL mode proxy secrets.
Delete the archive after troubleshooting if it is no longer needed.
EOF
  chmod 0600 "$path"
}

logs_pack_cmd() {
  need_root; banner
  local mode="safe" snap history ts bundle staging upstream_commit="unknown"
  [[ "${1:-}" == "--full" ]] && mode="full"
  [[ -z "${1:-}" || "${1:-}" == "--full" ]] || die "Использование: twebproxy logs-pack [--full]"
  snap="$(collect_runtime_snapshot "$mode" current)"
  history="$(collect_history_snapshot "$mode" history)"
  log "Current runtime snapshot: $snap"
  log "Bounded history snapshot: $history"
  ts="$(date '+%Y%m%d-%H%M%S')"
  if [[ "$mode" == "full" ]]; then
    bundle="$LOG_BUNDLE_DIR/twebproxy-FULL-report-${ts}.tar.gz"
  else
    bundle="$LOG_BUNDLE_DIR/twebproxy-logs-${ts}.tar.gz"
  fi

  staging="$(mktemp -d /tmp/twebproxy-bundle.XXXXXX)"
  install -d -m 0700 \
    "$staging/current" \
    "$staging/history" \
    "$staging/history/manager" \
    "$staging/history/runtime"

  cp -a "$snap" "$staging/current/runtime.log"
  cp -a "$history" "$staging/history/service-history.log"
  if [[ -n "${CURRENT_LOG:-}" && -f "$CURRENT_LOG" ]]; then
    cp -a "$CURRENT_LOG" "$staging/current/manager.log"
  fi

  # Keep reports compact and useful: persistent /opt logs retain everything, while
  # the shareable bundle carries recent context plus an activation-bounded current state.
  copy_recent_files "$LOG_MANAGER_DIR" "$staging/history/manager" '*.log' 12 "${CURRENT_LOG:-}"
  copy_recent_files "$LOG_RUNTIME_DIR" "$staging/history/runtime" '*.log' 6 "$snap" "$history"
  if [[ "$mode" == "full" ]]; then
    install -d -m 0700 "$staging/history/full"
    copy_recent_files "$LOG_FULL_DIR" "$staging/history/full" '*.log' 4 "$snap" "$history"
  fi

  write_security_notice "$staging/SECURITY-NOTICE.txt" "$mode"
  if [[ -f "$GLOBAL_ENV" ]]; then
    upstream_commit="$( (unset TPROXY_UPSTREAM_COMMIT; source "$GLOBAL_ENV"; printf '%s' "${TPROXY_UPSTREAM_COMMIT:-unknown}") )"
  fi
  {
    echo "manager_version=$MANAGER_VERSION"
    echo "manager_repo=$MANAGER_REPO_URL"
    echo "created_at=$(date -Is)"
    echo "mode=$mode"
    echo "current_snapshot=$snap"
    echo "history_snapshot=$history"
    echo "manager_log=${CURRENT_LOG:-unknown}"
    echo "tproxy_upstream_commit=$upstream_commit"
    echo "mtproxy_commit=$MTPROXY_COMMIT"
    echo "bundle_layout=current+bounded-history"
  } > "$staging/REPORT-META.txt"
  chmod 0600 "$staging/REPORT-META.txt"

  (cd "$staging" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256)
  chmod 0600 "$staging/MANIFEST.sha256"
  tar -czf "$bundle" -C "$staging" .
  chmod 0600 "$bundle"
  rm -rf "$staging"
  ok "Пакет логов готов: $bundle"
  if [[ "$mode" == "full" ]]; then
    warn "FULL TEST REPORT содержит WEB/MTProxy secrets. Приватные TLS/SSH ключи и root/sudo credentials не включаются."
  else
    echo "Обычный bundle содержит current state + bounded redacted history. WEB/MTProxy secrets заменяются на [REDACTED]."
  fi
}

report_cmd() {
  logs_pack_cmd --full
}

logs_list_cmd() {
  need_root; banner
  install -d -o root -g root -m 0700 "$LOG_DIR" "$LOG_MANAGER_DIR" "$LOG_RUNTIME_DIR" "$LOG_BUNDLE_DIR" "$LOG_FULL_DIR"
  echo "Project: $PROJECT_DIR"
  echo "Logs:    $LOG_DIR"
  echo
  echo "Последние manager logs (redacted):"
  find "$LOG_MANAGER_DIR" -maxdepth 1 -type f -name '*.log' -printf '%TY-%Tm-%Td %TH:%TM:%TS  %9s B  %f\n' 2>/dev/null | sort -r | head -n 30 || true
  echo
  echo "Runtime snapshots (redacted):"
  find "$LOG_RUNTIME_DIR" -maxdepth 1 -type f -name '*.log' -printf '%TY-%Tm-%Td %TH:%TM:%TS  %9s B  %f\n' 2>/dev/null | sort -r | head -n 20 || true
  echo
  echo "FULL snapshots (may contain proxy secrets):"
  find "$LOG_FULL_DIR" -maxdepth 1 -type f -name '*.log' -printf '%TY-%Tm-%Td %TH:%TM:%TS  %9s B  %f\n' 2>/dev/null | sort -r | head -n 20 || true
  echo
  echo "Bundles:"
  find "$LOG_BUNDLE_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%TY-%Tm-%Td %TH:%TM:%TS  %9s B  %f\n' 2>/dev/null | sort -r | head -n 20 || true
}

logs_tail_cmd() {
  need_root
  local n="${1:-200}" f
  [[ "$n" =~ ^[1-9][0-9]*$ ]] && (( n <= 5000 )) || die "Количество строк: 1..5000"
  f="$(latest_manager_log || true)"
  [[ -n "$f" && -f "$f" ]] || die "Предыдущих manager logs пока нет."
  echo "== $f =="
  tail -n "$n" "$f"
}

menu_logs() {
  while true; do
    clear 2>/dev/null || true; banner
    echo "Logs: $LOG_DIR"; echo
    local c; c="$(choose 'Логи:' \
      'Показать список логов' \
      'Показать хвост предыдущего manager log' \
      'Снять безопасный runtime snapshot' \
      'Собрать безопасный tar.gz' \
      'Собрать FULL TEST REPORT (с proxy secrets)' \
      'Назад')"
    case "$c" in
      1) logs_list_cmd; pause;;
      2) logs_tail_cmd 200; pause;;
      3) logs_collect_cmd; pause;;
      4) logs_pack_cmd; pause;;
      5) report_cmd; pause;;
      6) return;;
    esac
  done
}

menu_profiles() {
  local host; host="$(select_instance)"
  while true; do
    clear 2>/dev/null || true; banner; echo "Hostname: $host"; echo
    profiles_list_cmd "$host"; echo
    local c; c="$(choose 'Profiles:' 'Добавить secret/profile' 'Показать secret/link' 'Сменить secret' 'Сменить carrier' 'Удалить profile' 'Назад')"
    case "$c" in
      1) profile_add_cmd "$host"; pause;;
      2) show_profile_cmd "$host" "$(select_profile "$host")"; pause;;
      3) profile_rotate_cmd "$host" "$(select_profile "$host")"; pause;;
      4) profile_carrier_cmd "$host" "$(select_profile "$host")"; pause;;
      5) profile_delete_cmd "$host" "$(select_profile "$host")"; pause;;
      6) return;;
    esac
  done
}

menu() {
  need_root; need_systemd
  while true; do
    clear 2>/dev/null || true; banner
    if core_installed; then
      printf "Core: %binstalled%b | Instances: %s\n\n" "$C_GREEN" "$C_RESET" "$(count_instances)"
      manager_update_hint
      list_cmd; echo
      local c; c="$(choose 'Действие:' \
        'Добавить WEB proxy hostname' \
        'Управление secrets / profiles' \
        'Показать данные подключения' \
        'Показать Manual frontend snippet' \
        'Перезапустить hostname' \
        'Repair / доделать hostname' \
        'Статус' \
        'Статистика' \
        'Диагностика' \
        'Audit сетевой изоляции' \
        'Логи / пакет для отчёта' \
        'Проверить обновление TWebProxy Manager' \
        'Установить обновление TWebProxy Manager' \
        'Обновить relay upstream' \
        'Удалить hostname' \
        'Удалить core (только когда hostname нет)' \
        'Выход')"
      case "$c" in
        1) add_instance_cmd; pause;;
        2) menu_profiles;;
        3) show_instance_cmd; pause;;
        4) manual_snippet_cmd; pause;;
        5) restart_cmd; pause;;
        6) repair_instance_cmd; pause;;
        7) status_cmd; pause;;
        8) stats_cmd; pause;;
        9) diagnose_cmd; pause;;
        10) audit_cmd; pause;;
        11) menu_logs;;
        12) manager_check_update_cmd; pause;;
        13) manager_update_cmd; pause;;
        14) update_cmd; pause;;
        15) delete_instance_cmd; pause;;
        16) core_uninstall_cmd; pause;;
        17) exit 0;;
      esac
    else
      local c; c="$(choose 'Действие:' 'Установить TWebProxy core' 'Установить core и сразу добавить hostname' 'Выход')"
      case "$c" in 1) core_install_cmd; pause;; 2) add_instance_cmd; pause;; 3) exit 0;; esac
    fi
  done
}

usage() {
  cat <<EOF
TWebProxy Manager v$MANAGER_VERSION

Usage: twebproxy [command] [args]

Manager / Core:
  check-update                 проверить новую версию manager на GitHub
  manager-update [--force]     обновить manager с SHA-256 + bash validation
  core-install                 установить зависимости, relay и MTProxy
  update                       обновить tproxy-server upstream с config-check и rollback
  core-uninstall               удалить core (когда нет инстансов)

Instances / hostnames:
  add                          добавить новый WEB proxy hostname
  list                         список hostnames
  show [hostname]              показать hostname и все WEB links
  manual-snippet [hostname]    конфиг для существующего Caddy/Nginx
  restart [hostname]           перезапустить backends + relay и дождаться ready
  repair [hostname]            восстановить/доделать частично созданный hostname
  status [hostname]            systemd status
  stats [hostname]             relay metrics + MTProxy backend stats
  diagnose [hostname]          полная диагностика
  audit [hostname]             проверка loopback/backend firewall isolation
  delete [hostname]            удалить hostname

Logs:
  logs                         список логов и путь к папке проекта
  logs-tail [lines]            хвост предыдущего manager transcript (по умолчанию 200)
  logs-collect [--full]        snapshot systemd/journal/runtime; --full добавляет configs/secrets
  logs-pack [--full]           current state + bounded history в tar.gz; --full включает proxy secrets
  report                       FULL TEST REPORT для тестового сервера (alias logs-pack --full)

Profiles / secrets:
  profile-list [hostname]                      список profiles
  profile-add [hostname]                       добавить secret/profile
  profile-show [hostname] [profile]            показать secret и ссылку
  profile-rotate [hostname] [profile]          сменить secret
  profile-carrier [hostname] [profile]         сменить carrier mode
  profile-delete [hostname] [profile]          удалить profile

Interactive:
  menu                         TUI-меню

Важно: у Telegram WEB Proxy публичный HTTPS-порт фиксирован на 443.
Менеджер позволяет выбирать внутренние relay/admin/backend/stats порты.
Логи проекта: /opt/twebproxy-manager/logs. Shareable bundle содержит current state + ограниченную recent history. Обычные transcripts/snapshots редактируют secrets; report/--full сохраняет proxy secrets для тестовой диагностики, но никогда не собирает root/sudo passwords, SSH/TLS private key bytes или /etc/shadow.
EOF
}

cmd="${1:-menu}"; shift || true
setup_logging "$cmd"
case "$cmd" in
  check-update) manager_check_update_cmd ;;
  manager-update) manager_update_cmd "${1:-}" ;;
  core-install) core_install_cmd ;;
  add) add_instance_cmd ;;
  list) list_cmd ;;
  show) show_instance_cmd "${1:-}" ;;
  manual-snippet) manual_snippet_cmd "${1:-}" ;;
  restart) restart_cmd "${1:-}" ;;
  repair) repair_instance_cmd "${1:-}" ;;
  status) status_cmd "${1:-}" ;;
  stats) stats_cmd "${1:-}" ;;
  diagnose) diagnose_cmd "${1:-}" ;;
  audit) audit_cmd "${1:-}" ;;
  logs) logs_list_cmd ;;
  logs-tail) logs_tail_cmd "${1:-200}" ;;
  logs-collect) logs_collect_cmd "${1:-}" ;;
  logs-pack) logs_pack_cmd "${1:-}" ;;
  report) report_cmd ;;
  delete) delete_instance_cmd "${1:-}" ;;
  profile-list) profiles_list_cmd "${1:-}" ;;
  profile-add) profile_add_cmd "${1:-}" ;;
  profile-show) show_profile_cmd "${1:-}" "${2:-}" ;;
  profile-rotate) profile_rotate_cmd "${1:-}" "${2:-}" ;;
  profile-carrier) profile_carrier_cmd "${1:-}" "${2:-}" ;;
  profile-delete) profile_delete_cmd "${1:-}" "${2:-}" ;;
  update) update_cmd ;;
  core-uninstall) core_uninstall_cmd ;;
  menu) menu ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
