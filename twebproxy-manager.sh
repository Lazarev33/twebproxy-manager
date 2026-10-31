#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# TWebProxy Manager v0.2.26-beta (TUI smart defaults development)
# Multi-instance / multi-secret manager for telegramdesktop/tproxy-server.
# Target: Debian 12+ / Ubuntu 22.04+, x86_64, systemd.

APP="twebproxy"
MANAGER_VERSION="0.2.26"
MANAGER_RELEASE_VERSION="0.2.26-beta"
TPROXY_REPO="https://github.com/telegramdesktop/tproxy-server.git"
TPROXY_BRANCH="master"
# First real E2E baseline validated on 2026-08-23. Fresh core installs use this
# exact relay revision; `twebproxy update` is the explicit opt-in path to newer master.
TPROXY_INSTALL_COMMIT="2873a08806d6e4d84830b9b5c4b0ec0f46af91f8"
MTPROXY_REPO="https://github.com/TelegramMessenger/MTProxy.git"
# Pinned by the upstream tproxy-server deployment docs at the time v0.2.0 was built.
MTPROXY_COMMIT="f36d8af769ffaeac36978d38c2c0f6d1104c2137"

# Manager release/update source (docs/UPDATES.md). Only the latest published,
# non-draft, non-prerelease GitHub Release is an update candidate; development
# branches and their VERSION files never are.
MANAGER_REPO_SLUG="Lazarev33/twebproxy-manager"
MANAGER_REPO_URL="https://github.com/$MANAGER_REPO_SLUG"
MANAGER_API_URL="https://api.github.com/repos/$MANAGER_REPO_SLUG"
MANAGER_RAW_URL="https://raw.githubusercontent.com/$MANAGER_REPO_SLUG"
MANAGER_UPDATE_CACHE_TTL=21600
# manager-update installs a release only when its signed release manifest
# verifies against one of these pinned Ed25519 public keys (base64 DER
# SubjectPublicKeyInfo, one per entry) or, while no key is pinned, when the
# operator passes the expected SHA-256 obtained from an independent channel
# (--sha256). A SHA256SUMS file from the same source is never authentication.
# The project has no release-signing key yet, so none is pinned and automatic
# updates fail closed.
MANAGER_UPDATE_TRUSTED_KEYS=()
MANAGER_RELEASE_MANIFEST="twebproxy-manager-release.json"
MANAGER_RELEASE_FORMAT="twebproxy.manager-release.v1"
MANAGER_ARTIFACT_MAX_BYTES=8388608

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
FW_GUARD_TABLE="twebproxy_guard"
# Remote networks an MTProxy backend may exchange packets with (v0.2.24,
# P1-EXPOSURE-01): loopback (the local relay) and Telegram's published DC
# ranges (https://core.telegram.org/resources/cidr.txt, 2026-10-31), which
# contain every proxy_for address of getProxyConfig. PID 1 enforces this per
# backend cgroup (IPAddressDeny=any + IPAddressAllow=), independent of nftables.
TELEGRAM_DC_CIDRS="91.108.56.0/22 91.108.4.0/22 91.108.8.0/22 91.108.16.0/22 91.108.12.0/22 149.154.160.0/20 91.105.192.0/23 91.108.20.0/22 185.76.151.0/24 2001:b28:f23d::/48 2001:b28:f23f::/48 2001:67c:4e8::/48 2001:b28:f23c::/48 2a0a:f280::/32"
PROC_GROUP="twebproxy-procview"
PROC_POLICY_FILE="$BASE_DIR/proc-policy"
PROC_FSTAB_MARK="# twebproxy-proc-hardening"
FW_NFT_DROPIN="twebproxy-reassert.conf"
LANGUAGE_FILE="${TWEBPROXY_LANGUAGE_FILE:-$BASE_DIR/ui-language}"
# Frontend / TLS locations: Caddy, Nginx, Let's Encrypt and the ACME HTTP-01 webroot.
CADDY_DIR="/etc/caddy"
CADDYFILE="$CADDY_DIR/Caddyfile"
NGINX_DIR="/etc/nginx"
LE_DIR="/etc/letsencrypt"
ACME_WEBROOT="/var/lib/twebproxy/acme"
FRONTEND_INTERRUPTED=0

# Stage X-DPI remains opt-in. STOCK creates no DPI state, service, binary or
# nftables table. Enabled state is keyed by the resolved public IPv4 address
# because packet matching cannot safely distinguish hostnames sharing :443.
DPI_STATE_FORMAT="twebproxy.dpi.scope.v1"
DPI_DIR="$BASE_DIR/dpi"
DPI_STATE_DIR="$DPI_DIR/scopes"
DPI_NFT_FILE="$DPI_DIR/firewall.nft"
DPI_NFT_TABLE="twebproxy_dpi"
DPI_NFT_BIN="/usr/sbin/nft"
DPI_NFQWS_BIN="$LIBEXEC_DIR/twebproxy-nfqws"
DPI_NFQWS_SUM_FILE="$LIBEXEC_DIR/twebproxy-nfqws.sha256"
DPI_DOC_DIR="/usr/share/doc/twebproxy"
DPI_NFQWS_SHA256="f34615964d7321650197cd69d3f7cbfdaabe8118b5a0d57c6e41dccdff658999"
DPI_NFQWS_VERSION="v72.13"
DPI_NFQWS_COMMIT="87e058624c72863db53bdaf7fb6f16576dddb6ab"
DPI_NFQWS_RELEASE_ARCHIVE_URL="https://github.com/bol-van/zapret/releases/download/v72.13/zapret-v72.13.tar.gz"
DPI_NFQWS_RELEASE_BINARY_MEMBER="zapret-v72.13/binaries/linux-x86_64/nfqws"
DPI_NFQWS_RELEASE_LICENSE_MEMBER="zapret-v72.13/docs/LICENSE.txt"
DPI_NFQWS_LICENSE_SHA256="dcf5abd3e5d876c1065982871c0cec7368c0e61fc795c541798729516bb6b54f"
DPI_NFQWS_RELEASE_MAX_BYTES=16777216
DPI_NFQWS_BINARY_BYTES=125760
DPI_NFQWS_LICENSE_BYTES=1069
DPI_NFQUEUE_NUM=217
DPI_NFQWS_MARK="0x40000000"
DPI_FIREWALL_UNIT="twebproxy-dpi-firewall.service"
DPI_NFQWS_UNIT="twebproxy-dpi-nfqws.service"

# Installed manager project and persistent/shareable logs.
PROJECT_DIR="/opt/twebproxy-manager"
PROJECT_MANAGER_COPY="$PROJECT_DIR/twebproxy-manager.sh"
LOG_DIR="$PROJECT_DIR/logs"
LOG_MANAGER_DIR="$LOG_DIR/manager"
LOG_RUNTIME_DIR="$LOG_DIR/runtime"
LOG_BUNDLE_DIR="$LOG_DIR/bundles"
LOG_FULL_DIR="$LOG_DIR/full"
UPDATE_CACHE_FILE="$PROJECT_DIR/update-check.env"
UPDATE_BACKUP_FORMAT="twebproxy.update-backup.v1"
UPDATE_BACKUP_PARENT="/var/lib/twebproxy"
UPDATE_BACKUP_ROOT="$UPDATE_BACKUP_PARENT/update-backups"
UPDATE_RESTORE_HELPER="$LIBEXEC_DIR/restore-update-backup"
UPDATE_LOCK_FILE="/run/lock/twebproxy-manager-update.lock"
# Bounded wait (seconds) for an update lock held by another update or rollback.
UPDATE_LOCK_WAIT_SECONDS="${TWEBPROXY_UPDATE_LOCK_WAIT:-30}"
UPDATE_BACKUP_RETENTION=4
CURRENT_LOG=""
MANAGER_UPDATE_HINT_ATTEMPTED=0
OUTPUT_MODE="human"
OUTPUT_NO_COLOR=0
UI_LANGUAGE="ru"
TUI_ACTIVE=0
TUI_SETUP_KIND=""
# Upper bound (seconds) for one read-only diagnostic probe (systemctl, nft,
# journalctl, dig, ...); see diag_run.
DIAG_TIMEOUT="${TWEBPROXY_DIAG_TIMEOUT:-10}"
LOGS_STAGING=""; LOGS_PARTIAL=""

# Stage X-FixUI localization catalog. Human presentation resolves all labels
# through this single catalog; typed JSON/raw identifiers remain stable English.
declare -A UI_EN=() UI_RU=()

ui_i18n_init() {
  ((${#UI_EN[@]} > 0)) && return 0
  local key en ru
  while IFS=$'\t' read -r key en ru; do
    [[ -n "$key" ]] || continue
    UI_EN["$key"]="$en"; UI_RU["$key"]="$ru"
  done <<'UI_I18N'
product_subtitle	Telegram WEB Proxy Manager	Менеджер Telegram WEB Proxy
language	Language	Язык
english	English	English
russian	Russian	Русский
select_language	Select language / Выберите язык	Select language / Выберите язык
choice	Choice	Выбор
foreign_nodes	Foreign Nodes / Bridge	Зарубежные узлы / Мост
foreign_add	Add Foreign Node	Добавить зарубежный узел
foreign_operation_failed	Bridge operation did not complete (code %s). See the details above; inspect node status before retrying.	Операция с мостом не завершена (код %s). Подробности приведены выше; перед повтором проверьте состояние узла.
smart_advanced	Advanced / manual settings	Расширенные / ручные настройки
smart_quick	Standard setup (recommended)	Стандартная настройка (рекомендуется)
smart_failure	Operation did not complete (code %s). Details are above; use Diagnostics before retrying.	Операция не завершена (код %s). Подробности выше; перед повтором откройте диагностику.
smart_cancelled	Cancelled; no further action was taken.	Отменено; дальнейшие действия не выполнялись.
smart_apply	Apply this plan?	Применить этот план?
smart_impact	Affected: %s. Connections may be interrupted. Canonical state is retained; use Diagnostics/Repair if recovery is needed. Automatic rollback applies only to the existing transactional steps.	Затронуты: %s. Соединения могут прерваться. Каноническое состояние сохраняется; при сбое используйте диагностику/восстановление. Автооткат действует только для существующих транзакционных шагов.
smart_auto_plan	Automatic: free internal ports (rechecked under lock), HTTPS carrier, generated secret, one worker, 4096 connections, STOCK; bundled site or preserved existing files. No secret is included in this preview.	Автоматически: свободные внутренние порты (повторная проверка под блокировкой), HTTPS carrier, новый секрет, один worker, 4096 соединений, STOCK; встроенный сайт или сохранённые существующие файлы. Секрет в плане не показывается.
smart_install_impact	Install/reuse verified dependencies, enforce procfs/backend isolation, configure the selected frontend and start the new profile. Existing frontend sites are preserved. Partial failures require Diagnostics/Repair; full installation rollback is not promised.	Установка/повторное использование проверенных зависимостей, защита procfs/backend, настройка выбранного веб-сервера и запуск нового профиля. Существующие сайты сохраняются. При частичном сбое нужна диагностика/восстановление; полный откат установки не обещается.
smart_frontend_blocked	Standard TLS cannot safely use the existing listeners/configuration. Nothing was changed. Use Advanced setup with the existing frontend.	Стандартный TLS нельзя безопасно совместить с текущими слушателями/конфигурацией. Изменений нет. Используйте расширенную настройку с существующим веб-сервером.
smart_probe_missing	Cannot inspect the environment safely: required command %s is unavailable. Use core installation or install the inspection tool, then retry.	Нельзя безопасно проверить окружение: отсутствует команда %s. Установите основу или инструмент проверки и повторите.
smart_dns_blocked	DNS ownership could not be confirmed. Point the public A record to this server, check DNS/network access and retry. No installation was started.	Принадлежность DNS не подтверждена. Направьте публичную A-запись на этот сервер, проверьте DNS/доступ к сети и повторите. Установка не начата.
smart_contact_missing	Existing Nginx has no reusable managed ACME contact. Use Advanced setup to supply the required contact/certificate.	Для существующего Nginx нет управляемого ACME-контакта. В расширенной настройке укажите контакт или сертификат.
smart_profile_preset	Profile configuration	Настройка профиля
smart_profile_plan	Profile %s: carrier %s; workers=%s, connections=%s. Ports are checked under lock. Relay will restart; existing profiles remain. No secret is shown.	Профиль %s: carrier %s; workers=%s, connections=%s. Порты проверяются под блокировкой. Relay перезапустится; существующие профили сохраняются. Секрет не показывается.
smart_rotate_preset	New access key	Новый ключ доступа
smart_rotate_auto	Generate securely (recommended)	Сгенерировать безопасно (рекомендуется)
smart_rotate_manual	Enter my own secret (advanced)	Ввести свой секрет (расширенная настройка)
smart_rotate_warning	The old key will stop working. Backend/relay may restart and clients must import the new link. Continue?	Старый ключ перестанет работать. Backend/relay могут перезапуститься; клиентам понадобится новая ссылка. Продолжить?
smart_unchanged	Already selected; nothing changed.	Уже выбран этот вариант; изменений нет.
smart_carrier_change	Change carrier %s to %s? Relay will restart; clients may need a new link.	Сменить carrier %s на %s? Relay перезапустится; клиентам может понадобиться новая ссылка.
smart_bridge_active	A managed node exists. Use status, diagnostics, repair or removal; Add is unavailable.	Управляемый узел уже есть. Доступны статус, диагностика, восстановление и удаление; добавление недоступно.
smart_bridge_pending	An interrupted/unknown node state exists. Identity is retained. Inspect status and use repair; Add is blocked.	Есть прерванное/неизвестное состояние узла. Идентичность сохранена. Проверьте статус и выполните восстановление; добавление заблокировано.
smart_dpi_guided	Guided compatibility test	Проверка совместимости по шагам
smart_dpi_stock	Return to STOCK (no traffic modification)	Вернуть STOCK (без изменения трафика)
smart_dpi_limits	The server cannot identify client-side DPI from these probes. Start with STOCK. Experimental choices require a real client comparison; none is an automatic recommendation.	Сервер не определяет клиентский DPI по этим проверкам. Начинайте со STOCK. Экспериментальные варианты требуют сравнения настоящим клиентом; автоматической рекомендации нет.
smart_dpi_keep	Keep current settings	Оставить текущие настройки
smart_stock_scope	Return to STOCK for %s. Stored IPv4 scopes (including old DNS addresses) are listed below.	Вернуть STOCK для %s. Ниже показаны сохранённые области IPv4, включая прежние адреса DNS.
smart_dpi_window	Try TCP window compatibility (Window 1152)	Проверить совместимость TCP-окна (Window 1152)
smart_dpi_mss	Try smaller TCP segments (MSS 88)	Проверить меньшие TCP-сегменты (MSS 88)
smart_dpi_nfqws	Try packet processing (nfqws, experimental)	Проверить обработку пакетов (nfqws, экспериментально)
smart_full_report	The full report can contain proxy secrets. Keep it private. Create it?	Полный отчёт может содержать секреты прокси. Храните его закрыто. Создать?
smart_core_confirm	Install the core and its dependencies, firewall and procfs protection? Existing services must be preserved.	Установить основу, зависимости, защиту firewall и procfs? Существующие службы должны сохраниться.
smart_limits_one	One worker / 4096 connections (standard)	Один процесс / 4096 подключений (стандарт)
smart_limits_two	Two workers / 4096 connections each	Два процесса / по 4096 подключений
smart_carrier_title	Client transport (check client support before changing)	Транспорт клиента (перед изменением проверьте поддержку)
smart_carrier_https	https — standard (recommended)	https — стандартный (рекомендуется)
smart_carrier_lanes	https-lanes — separate HTTP/2 streams	https-lanes — отдельные потоки HTTP/2
smart_carrier_ws	websocket — WSS; client validation required	websocket — WSS; нужна проверка клиента
smart_carrier_ws_lanes	websocket-lanes — separate WSS streams; client validation required	websocket-lanes — отдельные WSS-потоки; нужна проверка клиента
smart_target	Selected target: %s / %s	Выбранный объект: %s / %s
smart_quick_plan	Public HTTPS for %s; frontend %s; bundled/preserved static website; profile default.	Публичный HTTPS для %s; веб-сервер %s; встроенный/сохранённый сайт; профиль default.
smart_profile_name_blocked	Automatic profile names are reserved by existing/pending records. Use Advanced for another name or inspect/repair the retained state.	Автоматические имена заняты существующими/остаточными записями. Выберите другое имя в расширенной настройке или проверьте/восстановите сохранённое состояние.
main_menu	Main menu	Главное меню
instances	Proxies / Instances	Прокси / Инстансы
profiles	Profiles	Профили
status_stats	Status & Statistics	Статус и статистика
maintenance	Maintenance	Обслуживание
diagnostics_logs	Diagnostics & Logs	Диагностика и логи
settings	Settings	Настройки
exit	Exit	Выход
back	Back	Назад
add_instance	Add hostname	Добавить hostname
show_connection	Show connection details	Показать данные подключения
manual_snippet	Show manual frontend snippet	Показать конфигурацию внешнего интерфейса для ручной настройки
restart_instance	Restart hostname	Перезапустить hostname
repair_instance	Repair hostname	Восстановить hostname
delete_instance	Delete hostname	Удалить hostname
uninstall_core	Uninstall core (no hostnames only)	Удалить core (только без hostname)
add_profile	Add secret/profile	Добавить secret/profile
show_profile	Show secret/link	Показать secret/link
rotate_profile	Rotate secret	Сменить secret
carrier_profile	Change carrier	Сменить carrier
delete_profile	Delete profile	Удалить профиль
compact_status	Compact status	Краткий статус
compact_statistics	Compact statistics	Краткая статистика
detailed_status	Detailed status (advanced)	Подробный статус (расширенный)
raw_statistics	Raw live statistics (advanced)	Необработанная актуальная статистика (расширенный режим)
tls_certificates	TLS / Certificates	TLS / Сертификаты
update_recovery	Update & Rollback	Обновление и откат
manager_check_update	Check Manager update	Проверить обновление TWebProxy Manager
manager_install_update	Install Manager update	Установить обновление TWebProxy Manager
backup_list	List local update backups	Показать локальные резервные копии обновлений
rollback_latest	Rollback to latest verified backup	Откатить к последней проверенной резервной копии
relay_update	Update relay upstream	Обновить исходный код relay
cert_details	Detailed certificate status	Подробный статус сертификата
cert_dry_run	Check renewal without issuance (--dry-run)	Проверить продление без выпуска сертификата (--dry-run)
cert_renew	Renew certificate when due	Продлить сертификат по сроку
cert_force	Force certificate reissue (Nginx LE)	Принудительно перевыпустить (Nginx LE)
full_diagnose	Full legacy diagnostics	Полная расширенная диагностика
isolation_audit	Network isolation and TLS audit	Аудит сетевой изоляции и TLS
typed_json	Typed audit JSON	Типизированный аудит JSON
typed_raw	Typed audit raw TSV	Типизированный аудит raw TSV
logs_reports	Logs and report bundles	Логи и пакеты отчёта
list_logs	List logs	Показать список логов
tail_log	Tail previous Manager log	Показать конец предыдущего журнала TWebProxy Manager
runtime_snapshot	Create safe runtime snapshot	Снять безопасный снимок текущего состояния
safe_bundle	Build safe tar.gz bundle	Собрать безопасный архив tar.gz
full_report	Build FULL TEST REPORT (contains proxy secrets)	Собрать полный тестовый отчёт (содержит proxy secrets)
change_language	Change language	Сменить язык
enable_color	Enable color for this session	Включить цвет в этой сессии
disable_color	Disable color for this session	Отключить цвет в этой сессии
system	System	Система
installed	Installed	Установлено
not_installed	Not installed	Не установлено
overall	Overall	Итог
hostnames	Instances	Инстансы
hostname	Hostname	Hostname
checks	Checks	Проверки
healthy	Healthy	Исправно
attention	Attention required	Требуется внимание
no_instances	No configured WEB Proxy instances.	Нет настроенных WEB Proxy-инстансов.
instances_section	Instances	Инстансы
operational_summary	Operational summary	Операционная сводка
operational_overview_label	Operational overview	Операционная сводка
live_sources	Live verified sources	Проверенные актуальные источники
unavailable_design	Unavailable by design	Недоступно по архитектуре
raw_diagnostics_hint	Detailed evidence is available in Diagnostics.	Подробные данные доступны в разделе «Диагностика».
stats_scope_note	Only verified live sources are shown; no history is fabricated.	Показаны только проверенные актуальные данные; отсутствующая история не выдумывается.
source_relay	Relay metrics	Показатели relay
source_profiles	Profile sources	Источники профилей
live_values	Live values	Актуальные значения
relay_sessions	Relay sessions	Сессии relay
relay_streams	Relay streams	Потоки relay
relay_bytes_total	Relay bytes total	Всего байтов relay
backend_connections	Backend connections	Соединения backend
metric_unavailable	Not reported by the live source	Не передаётся актуальным источником
verbose_relay_metrics	Relay metrics	Показатели relay
verbose_backend_stats	MTProxy backend statistics	Статистика backend MTProxy
verbose_stats_note	The upstream services expose sessions, streams and backend connection statistics, but cannot identify unique Telegram users.	Исходные службы предоставляют число сессий, потоков и соединений backend, но не позволяют определить отдельных пользователей Telegram.
history	History	История
unavailable	Unavailable	Недоступно
available	Available	Доступно
terminal_width	Terminal width	Ширина терминала
color	Color	Цвет
enabled_session	Enabled for this session	Включён в этой сессии
disabled_session	Disabled for this session	Отключён в этой сессии
machine_output	Machine output	Машинный вывод
machine_output_value	--json / --raw stay non-interactive and non-localized	--json / --raw остаются неинтерактивными и нелокализованными
language_saved	Language saved	Язык сохранён
press_enter	Press Enter to continue...	Нажмите Enter для продолжения...
enter_number	Enter a number.	Введите номер.
unknown_option	No such option.	Такого пункта нет.
select_hostname	Select hostname	Выберите hostname
select_profile	Select profile	Выберите профиль
no_hostnames	No configured hostnames.	Нет настроенных hostname.
no_profiles	No profiles for %s.	У %s нет профилей.
secret_warning	The next screen reveals the secret and connection links.	Следующий экран раскрывает secret и ссылки подключения.
status_title	TWebProxy Status	Статус TWebProxy
statistics_title	TWebProxy Statistics	Статистика TWebProxy
state	State	Состояние
online	Online	Работает
offline	Offline	Не работает
profile_sources_value	%s of %s available	доступно %s из %s
settings_note	Language is persistent; color affects only this process.	Язык сохраняется; цвет действует только в этом процессе.
network_compatibility	Network compatibility	Совместимость сети
dpi_title	Network compatibility / Anti-DPI	Совместимость сети / Anti-DPI
dpi_status	Compatibility status	Состояние совместимости
dpi_methods	Available methods	Доступные методы
dpi_enable	Set compatibility method	Выбрать метод совместимости
dpi_disable	Return to STOCK	Вернуть STOCK
dpi_mode	Mode	Режим
dpi_scope	IPv4 scope	Область IPv4
dpi_ipv6	IPv6 behavior	Поведение IPv6
dpi_ipv6_stock	Unchanged (STOCK)	Без изменений (STOCK)
dpi_stock_note	STOCK is the default and installs no DPI runtime artifacts.	STOCK используется по умолчанию и не устанавливает компоненты DPI.
dpi_scope_warning	This method affects every HTTPS flow sourced from %s:443, not only %s.	Этот метод влияет на весь исходящий HTTPS-трафик с %s:443, а не только на %s.
dpi_confirm_scope	I understand the IPv4-wide scope and want to continue	Я понимаю область действия для всего IPv4 и хочу продолжить
dpi_tui_scope	Hostname: %s; public IPv4: %s	Hostname: %s; публичный IPv4: %s
dpi_tui_cancelled	No changes applied.	Изменения не применены.
dpi_tui_failed	Compatibility mode activation failed; no success is reported.	Не удалось применить режим совместимости; операция не объявлена успешной.
dpi_shared_hosts	Configured hostnames sharing this IPv4	Настроенные hostname с этим IPv4
dpi_dedicated_unknown	Dedicated-address ownership cannot be proven automatically	Невозможно автоматически подтвердить выделенность адреса
dpi_applied	Compatibility mode %s is active for %s (%s).	Режим совместимости %s активен для %s (%s).
dpi_disabled	Compatibility mode for %s returned to STOCK.	Режим совместимости для %s возвращён в STOCK.
dpi_no_state	No opt-in compatibility modes are active.	Дополнительные режимы совместимости не активны.
dpi_nfqws_provenance	nfqws %s, pinned commit %s	nfqws %s, закреплённый commit %s
dpi_invalid_mode	Unknown compatibility mode: %s	Неизвестный режим совместимости: %s
dpi_resolution_failed	%s must resolve to exactly one public IPv4 address before a compatibility mode can be changed.	Перед изменением режима %s должен разрешаться ровно в один публичный IPv4-адрес.
dpi_ack_required	Address-wide confirmation is required. Re-run with --accept-shared-scope.	Требуется подтверждение области действия для всего адреса. Повторите с --accept-shared-scope.
dpi_transaction_failed	Compatibility change failed; the previous exact state was restored.	Не удалось изменить режим совместимости; предыдущее точное состояние восстановлено.
dpi_transaction_failed_stage	Could not apply %s (stage: %s); the previous state was restored.	Не удалось применить %s (этап: %s); предыдущее состояние восстановлено.
dpi_transaction_failed_at_stage	Compatibility change failed at stage: %s; the previous exact state was restored.	Не удалось изменить режим совместимости на этапе: %s; предыдущее точное состояние восстановлено.
dpi_scope_not_local	The resolved public IPv4 %s for %s is not configured on any local interface. Packets leaving this host do not carry that address, so an address-scoped compatibility rule could never match it. This usually means the public address is provided by external 1:1 NAT (common on EC2/Lightsail, GCE, Azure). Compatibility modes were not activated. Locally configured IPv4 addresses: %s	Разрешённый публичный IPv4 %s для %s не настроен ни на одном локальном интерфейсе. Пакеты, покидающие этот хост, не содержат этот адрес, поэтому правило совместимости, привязанное к адресу, никогда не совпадёт. Обычно это означает, что публичный адрес выдаётся внешним 1:1 NAT (типично для EC2/Lightsail, GCE, Azure). Режимы совместимости не активированы. Локально настроенные адреса IPv4: %s
dpi_scope_probe_unavailable	The set of locally configured IPv4 addresses could not be determined, so it is not possible to confirm that scope %s can match outgoing packets. Compatibility modes were not activated. Install iproute2 (or provide hostname -I) and retry.	Не удалось определить набор локально настроенных адресов IPv4, поэтому невозможно подтвердить, что область %s может совпасть с исходящими пакетами. Режимы совместимости не активированы. Установите iproute2 (или обеспечьте hostname -I) и повторите попытку.
firewall_backend_state_invalid	Backend state file %s is incomplete or invalid. The firewall isolation ruleset was not rebuilt, so the existing ruleset stays in force. Repair or remove that backend and retry.	Файл состояния backend %s неполон или некорректен. Правила изоляции межсетевого экрана не пересобраны, поэтому продолжает действовать существующий набор правил. Восстановите или удалите этот backend и повторите попытку.
field_title	TWebProxy Field Diagnostics	Полевая диагностика TWebProxy
field_diagnostics	Field diagnostics	Полевой отчёт
field_host	Host	Host
field_dpi	DPI	DPI
field_ipv4	IPv4	IPv4
field_initial_captured	Initial state captured.	Исходное состояние зафиксировано.
field_reproduce	Reproduce the problem in Telegram now.	Воспроизведите проблему в Telegram.
field_press_enter	Press Enter when finished.	Нажмите Enter по завершении.
field_max_window	Maximum capture window: %s seconds.	Максимальное время ожидания — %s секунд.
field_window_timeout	Capture window closed on timeout.	Окно захвата закрыто по таймауту.
field_collecting	Collecting final state...	Сбор итогового состояния...
field_observation_q	What happened in Telegram?	Что произошло в Telegram?
field_obs_connected	Connected	Подключилось
field_obs_disconnected	Did not connect	Не подключилось
field_obs_unstable	Unstable / intermittent	Нестабильно / с перебоями
field_obs_not_tested	Not checked	Не проверялось
field_ready	Field report ready:	Полевой отчёт готов:
field_upload_hint	Upload this archive for analysis.	Загрузите этот архив для анализа.
field_scp_hint	Copy it with:	Скопировать командой:
field_pcap_warning	The raw PCAP contains network metadata and may contain application/TLS metadata depending on packet contents. Treat it as sensitive diagnostic evidence.	RAW PCAP содержит сетевые метаданные и, в зависимости от содержимого пакетов, может содержать метаданные приложения/TLS. Обращайтесь с ним как с чувствительными диагностическими данными.
field_trace_unavailable	tcpdump is not installed; continuing without a packet trace.	tcpdump не установлен; продолжаем без трассировки пакетов.
field_trace_failed	Packet trace could not be started; continuing without it.	Не удалось запустить трассировку пакетов; продолжаем без неё.
field_usage	Usage: twebproxy field-report HOST [--instant] [--keep-pcap]	Использование: twebproxy field-report HOST [--instant] [--keep-pcap]
field_staging_failed	Could not create a private staging directory for the field report.	Не удалось создать приватный каталог для полевого отчёта.
field_archive_failed	Could not write the field report archive.	Не удалось записать архив полевого отчёта.
field_manifest_failed	Could not generate the field report manifest.	Не удалось сформировать манифест полевого отчёта.
field_cancelled	Field report canceled; temporary data was removed and no archive was written.	Полевой отчёт отменён; временные данные удалены, архив не создан.
dpi_repair_warning	DPI state could not be reconciled; affected address scopes were returned to STOCK.	Не удалось согласовать состояние DPI; затронутые адреса возвращены в STOCK.
dpi_prune_unverifiable	Address ownership for %s could not be determined (resolver failure or ambiguous answer); the saved compatibility state was kept.	Не удалось определить принадлежность адреса %s (сбой resolver или неоднозначный ответ); сохранённое состояние совместимости оставлено без изменений.
dpi_mutation_busy	Another TWebProxy DPI operation is already in progress; nothing was changed. Retry once it finishes.	Другая операция DPI TWebProxy уже выполняется; изменения не внесены. Повторите после её завершения.
dpi_method_stock	No traffic modification; production default.	Без изменения трафика; производственный режим по умолчанию.
dpi_method_window	Set TCP receive window 1152 on outbound IPv4 SYN+ACK from port 443.	Устанавливать окно приёма TCP 1152 в исходящих IPv4 SYN+ACK с порта 443.
dpi_method_mss	Advertise TCP MSS 88 in outbound IPv4 SYN+ACK from port 443.	Объявлять TCP MSS 88 в исходящих IPv4 SYN+ACK с порта 443.
dpi_method_nfqws	Queue the first server reply packets to the pinned nfqws strategy.	Передавать первые ответные пакеты сервера закреплённой стратегии nfqws.
dpi_method_window_nfqws	Apply receive window 1152, then the pinned nfqws strategy.	Сначала применять окно приёма 1152, затем закреплённую стратегию nfqws.
dpi_method_mss_nfqws	Apply MSS 88, then the pinned nfqws strategy.	Сначала применять MSS 88, затем закреплённую стратегию nfqws.
first_install	Install TWebProxy core	Установить TWebProxy core
first_install_add	Install core and add hostname	Установить core и добавить hostname
first_action	Action	Действие
status_ok	OK	НОРМА
status_warning	WARNING	ВНИМАНИЕ
status_error	ERROR	ОШИБКА
status_disabled	DISABLED	ОТКЛЮЧЕНО
status_unknown	UNKNOWN	НЕИЗВЕСТНО
counts	OK %s; warnings %s; errors %s; disabled %s; unknown %s	норма %s; предупреждения %s; ошибки %s; отключено %s; неизвестно %s
dashboard_title	TWebProxy Manager v%s	TWebProxy Manager v%s
release_channel	Release channel	Канал выпуска
beta	beta	beta
frontend	Frontend	Внешний интерфейс
profiles_count	Profiles	Профили
profile	Profile	Профиль
public_endpoint	Public	Публичный адрес
public_endpoint_value	%s (Telegram WEB: fixed port 443)	%s (Telegram WEB: фиксированный порт 443)
relay	Relay	Relay
admin_metrics	Admin/metrics	Администрирование/метрики
site	Site	Сайт
link	Link	Ссылка
tg_link	TG link	Ссылка TG
stats	Statistics	Статистика
manual_snippet_comment	Caddy — proxy the entire hostname through the relay	Caddy — весь hostname должен идти через relay
manual_nginx_comment	Nginx — HTTPS server{}; substitute your certificate paths	Nginx — HTTPS server{}; подставьте свои пути сертификатов
manual_map_comment	Nginx requires this map once in http{}	Для Nginx один раз нужен map в http{}
manual_security_warning	Important: do not route a static site around the relay and do not log raw URI/Authorization values.	Важно: не направляйте статический сайт в обход relay и не записывайте в журнал raw URI/Authorization.
manual_endpoint_warning	The public Telegram WEB endpoint must remain on HTTPS/443.	Публичная точка подключения Telegram WEB должна оставаться на HTTPS/443.
host_state_line	%s  %s  profiles: %s  TLS: %s	%s  %s  профили: %s  TLS: %s
backend	Backend	Backend
carrier	Carrier	Carrier
ports	Ports	Порты
secret	Secret	Secret
hidden	Hidden	Скрыт
tls_actions_note	Certificate actions use the existing certificate lifecycle.	Действия с сертификатами используют существующее управление их жизненным циклом.
certificate_status	Certificate status	Состояние сертификата
tls_mode_label	TLS mode	Режим TLS
public_certificate	Public certificate	Публичный сертификат
local_certificate	Local certificate	Локальный сертификат
remaining_days	Remaining	Осталось
issuer	Issuer	Издатель
subject	Subject	Субъект
serial	Serial	Серийный номер
path	Path	Путь
days_suffix	day(s)	дн.
served_certificate	Served certificate	Выдаваемый сертификат
match	MATCH	СОВПАДАЕТ
renewal_management	Renewal management	Управление продлением
renew_caddy_native	Caddy native automatic TLS	Встроенное автоматическое управление TLS в Caddy
renew_caddy_inactive	Caddy service inactive	Служба Caddy неактивна
renew_disabled	Disabled	Отключено
renew_custom	Not managed (custom certificate)	Не управляется (пользовательский сертификат)
renew_external	External frontend	Внешний интерфейс
strict_https	Strict HTTPS	Строгая проверка HTTPS
tls_summary_certificate	TLS certificate	Сертификат TLS
mode	mode	режим
remaining	remaining	осталось
renewal	renewal	продление
audit_heading	Isolation audit: %s	Аудит изоляции: %s
diag_listeners	Listeners	Слушатели
diag_health	Health	Проверка работоспособности
diag_public_surface	Local public surface	Локальная публичная поверхность
diag_public_https	Public HTTPS	Публичный HTTPS
diag_certificate	Certificate	Сертификат
diag_backend_firewall	Backend firewall	Межсетевой экран backend
diag_recent_logs	Recent logs	Последние журналы
logs_recent_manager	Recent Manager logs (redacted)	Последние журналы TWebProxy Manager (обезличены)
logs_runtime_snapshots	Runtime snapshots (redacted)	Снимки рабочего состояния (обезличены)
logs_full_snapshots	FULL snapshots (may contain proxy secrets)	Полные снимки (могут содержать proxy secrets)
logs_bundles	Bundles	Пакеты
manager	Manager	TWebProxy Manager
manager_update	Manager update	Обновление TWebProxy Manager
verified_update_workflow	Existing SHA256SUMS-verified workflow	Существующий процесс с проверкой SHA256SUMS
local_backups	Local update backups	Локальные резервные копии обновлений
offline_helper	Offline rollback helper	Офлайн-помощник отката
helper_available	Available	Доступен
helper_unavailable	Unavailable	Недоступен
connect_telegram	Connect Telegram: links and client help	Подключить Telegram: ссылки и помощь
network_compatibility_advanced	Network compatibility / Anti-DPI (advanced)	Совместимость сети / Anti-DPI (для опытных)
first_quick_setup	Quick setup: install the core and add the first hostname (recommended)	Быстрая настройка: установить основу и добавить первый hostname (рекомендуется)
first_core_only	Install the core only	Только установить основу
prereq_title	Before you start	Перед началом
prereq_dns	A hostname with a DNS A record pointing to this server's public IPv4.	Hostname с DNS-записью A, указывающей на публичный IPv4 этого сервера.
prereq_ports	TCP 443 free for HTTPS; TCP 80 as well for automatic certificates.	Свободный TCP 443 для HTTPS; для автоматических сертификатов — ещё TCP 80.
prereq_system	Debian 12+ or Ubuntu 22.04+, x86_64, systemd, root.	Debian 12+ или Ubuntu 22.04+, x86_64, systemd, права root.
prereq_defaults	Recommended: Caddy with automatic HTTPS and the STOCK network mode (traffic unchanged).	Рекомендуется: Caddy с автоматическим HTTPS и сетевой режим STOCK (трафик не изменяется).
setup_hostname_intro	The hostname needs a DNS A record pointing to this server. Telegram WEB Proxy uses HTTPS on port 443; automatic certificates also need port 80.	Для hostname нужна DNS-запись A, указывающая на этот сервер. Telegram WEB Proxy работает по HTTPS на порту 443; для автоматических сертификатов нужен ещё порт 80.
setup_hostname_retry	Attempts left: %s.	Осталось попыток: %s.
setup_type	Setup type:	Тип настройки:
setup_quick	Quick (recommended): automatic ports, profile "default", new secret, https carrier	Быстрая (рекомендуется): порты автоматически, профиль «default», новый secret, carrier https
setup_advanced	Advanced: choose ports, profile, secret, carrier and MTProxy limits yourself	Расширенная: порты, профиль, secret, carrier и лимиты MTProxy вручную
setup_site_intro	The bundled cultural website is ready to use on your hostname, or choose your own static site/application. Existing website files are preserved.	Встроенный культурный сайт готов к работе на вашем hostname. Можно выбрать свой каталог или приложение; существующие файлы сайта сохраняются.
site_placeholder	Bundled default: Cultural Routes of Moscow Oblast	Встроенный сайт: «Культурные маршруты Подмосковья»
site_directory	My static website: copy a directory with index.html	Мой статический сайт: скопировать каталог с index.html
site_upstream	My web application on this server (loopback URL)	Моё веб-приложение на этом сервере (адрес loopback)
tls_caddy	Caddy — automatic HTTPS certificate (recommended)	Caddy — автоматический HTTPS-сертификат (рекомендуется)
tls_nginx_le	Nginx + Let's Encrypt (automatic renewal; needs port 80)	Nginx + Let's Encrypt (автоматическое продление; нужен порт 80)
tls_nginx_custom	Nginx + my certificate and key	Nginx + мой сертификат и ключ
tls_manual	Manual: my web server already serves port 443 (advanced)	Вручную: порт 443 уже обслуживает мой веб-сервер (для опытных)
setup_quick_short	quick	быстрая
setup_advanced_short	advanced	расширенная
plan_network_value	STOCK (default; traffic unchanged)	STOCK (по умолчанию; трафик не изменяется)
client_help_title	How to connect Telegram	Как подключить Telegram
client_help_step1	Open the Link on the device with Telegram, or send it to yourself in Telegram and tap it; the TG link opens Telegram directly.	Откройте «Ссылку» на устройстве с Telegram или отправьте её себе в Telegram и нажмите; «Ссылка TG» открывает Telegram напрямую.
client_help_step2	Telegram should offer to add this proxy; accept it. Nothing else (port, protocol) has to be entered: it is all in the link.	Telegram предложит добавить этот прокси — подтвердите. Больше ничего (порт, протокол) вводить не нужно: всё уже есть в ссылке.
client_help_step3	One profile is one secret: give separate users or groups their own profiles, so access can be changed or revoked individually.	Один профиль — один secret: выдавайте разным пользователям или группам отдельные профили, чтобы доступ можно было сменить или отозвать по отдельности.
client_help_support	Client support: a Telegram client with WEB Proxy support is required; this manager does not check client versions. Desktop and mobile clients are verified during pre-release testing.	Поддержка клиентов: нужен клиент Telegram с поддержкой WEB Proxy; Manager не проверяет версии клиентов. Работа на компьютере и телефоне проверяется на предрелизных испытаниях.
client_help_check	If it does not connect: open %s in a browser (the certificate must be valid), then run: twebproxy status %s; details: twebproxy diagnose %s	Если не подключается: откройте %s в браузере (сертификат должен быть действительным), затем выполните: twebproxy status %s; подробности: twebproxy diagnose %s
next_steps_title	Next steps	Что дальше
next_status	Check the state: twebproxy status %s	Проверить состояние: twebproxy status %s
next_profiles	More users or devices: twebproxy profile-add %s	Ещё пользователи или устройства: twebproxy profile-add %s
next_compat	Only if connections fail on a restrictive network: Network compatibility / Anti-DPI (advanced); see twebproxy dpi list-methods	Только если подключения не проходят в сети с ограничениями: «Совместимость сети / Anti-DPI (для опытных)»; см. twebproxy dpi list-methods
dpi_intro	STOCK (default) leaves traffic unchanged and is the recommended starting point. The other modes are experimental IPv4 workarounds for networks that interfere with HTTPS; none guarantees a bypass. A mode applies to every HTTPS connection from the server's public IPv4 on port 443, including other sites on that address.	Режим STOCK (по умолчанию) не изменяет трафик; с него и стоит начинать. Остальные режимы — экспериментальные обходные приёмы для IPv4 в сетях, которые мешают HTTPS; ни один не гарантирует обход. Режим действует на все HTTPS-соединения с публичного IPv4 сервера на порту 443, включая другие сайты на этом адресе.
dpi_choice_window	window1152 — experimental: TCP window 1152 in the server's SYN+ACK	window1152 — экспериментальный: окно TCP 1152 в SYN+ACK сервера
dpi_choice_mss	mss88 — aggressive: TCP MSS 88 in the server's SYN+ACK; high overhead	mss88 — агрессивный: TCP MSS 88 в SYN+ACK сервера; большие накладные расходы
dpi_choice_nfqws	nfqws — experimental: pinned nfqws strategy for the first reply packets	nfqws — экспериментальный: закреплённая стратегия nfqws для первых ответных пакетов
dpi_choice_window_nfqws	window1152_nfqws — experimental: window1152, then nfqws	window1152_nfqws — экспериментальный: сначала window1152, затем nfqws
dpi_choice_mss_nfqws	mss88_nfqws — most aggressive: mss88, then nfqws	mss88_nfqws — самый агрессивный: сначала mss88, затем nfqws
dpi_revert_tip	If connections get worse, return to STOCK: twebproxy dpi disable %s	Если подключения стали хуже, верните STOCK: twebproxy dpi disable %s
dpi_detail_stock	Nothing is installed or changed.	Ничего не устанавливается и не изменяется.
dpi_detail_window	Direction: server to client, outbound IPv4 SYN+ACK from :443. Overhead: low; the first data may arrive in smaller pieces. Status: experimental.	Направление: от сервера к клиенту, исходящий IPv4 SYN+ACK с :443. Накладные расходы: низкие; первые данные могут приходить мелкими частями. Статус: экспериментальный.
dpi_detail_mss	Direction: server to client, outbound IPv4 SYN+ACK from :443. Overhead: high; clients send many small TCP segments. Status: aggressive, experimental.	Направление: от сервера к клиенту, исходящий IPv4 SYN+ACK с :443. Накладные расходы: высокие; клиенты отправляют много мелких сегментов TCP. Статус: агрессивный, экспериментальный.
dpi_detail_nfqws	Direction: server to client, the first reply packets of each HTTPS connection, handled in user space by the pinned nfqws. Overhead: one extra service and CPU for every new connection. Status: experimental.	Направление: от сервера к клиенту, первые ответные пакеты каждого HTTPS-соединения; их обрабатывает закреплённый nfqws в пространстве пользователя. Накладные расходы: дополнительная служба и CPU на каждое новое соединение. Статус: экспериментальный.
dpi_detail_window_nfqws	Direction and overhead: those of window1152 and nfqws together. Status: experimental.	Направление и накладные расходы: как у window1152 и nfqws вместе. Статус: экспериментальный.
dpi_detail_mss_nfqws	Direction and overhead: those of mss88 and nfqws together, the highest of all modes. Status: most aggressive, experimental.	Направление и накладные расходы: как у mss88 и nfqws вместе, самые высокие из всех режимов. Статус: самый агрессивный, экспериментальный.
dpi_footer_scope	All modes except STOCK work on IPv4 only (IPv6 stays STOCK) and affect every HTTPS connection from the same public IPv4 on port 443, including other hostnames and services on it; enabling one needs explicit confirmation (--accept-shared-scope).	Все режимы, кроме STOCK, работают только для IPv4 (IPv6 остаётся STOCK) и затрагивают все HTTPS-соединения с того же публичного IPv4 на порту 443, включая другие hostname и службы на нём; для включения нужно явное подтверждение.
dpi_footer_guarantee	No mode guarantees getting past DPI. Start with STOCK, change one mode at a time, test with a real client, and go back with: twebproxy dpi disable HOST	Ни один режим не гарантирует обход DPI. Начинайте со STOCK, меняйте по одному режиму, проверяйте настоящим клиентом и возвращайтесь командой: twebproxy dpi disable HOST
hint_relay	Relay is not running or not ready: twebproxy repair %s (details: twebproxy diagnose %s)	Relay не запущен или не готов: twebproxy repair %s (подробности: twebproxy diagnose %s)
hint_frontend	The web server (Caddy/Nginx) is not running: twebproxy repair %s	Веб-сервер (Caddy/Nginx) не запущен: twebproxy repair %s
hint_tls	HTTPS or the certificate is not confirmed: the DNS A record must point here and ports 80/443 must be reachable; twebproxy cert-status %s	HTTPS или сертификат не подтверждены: DNS-запись A должна указывать сюда, порты 80/443 — быть доступны; twebproxy cert-status %s
hint_profile	A profile backend needs attention: twebproxy repair %s	Требуется внимание к backend профиля: twebproxy repair %s
hint_no_profile	No profile yet: twebproxy profile-add %s	Профилей пока нет: twebproxy profile-add %s
hint_firewall	Backend isolation is not confirmed: twebproxy repair %s rebuilds the firewall, then twebproxy audit %s	Изоляция backend не подтверждена: twebproxy repair %s пересоздаёт межсетевой экран, затем twebproxy audit %s
hint_generic	Details: twebproxy status %s --verbose or twebproxy diagnose %s	Подробности: twebproxy status %s --verbose или twebproxy diagnose %s
dpi_transaction_failed_stage_fallback	Could not apply %s (stage: %s); the previous state could NOT be restored and network compatibility fell back to STOCK. Check "twebproxy dpi status" and run "twebproxy repair HOSTNAME".	Не удалось применить %s (этап: %s); предыдущее состояние восстановить НЕ удалось, режим совместимости сброшен в STOCK. Проверьте «twebproxy dpi status» и выполните «twebproxy repair HOSTNAME».
dpi_kernel_rules	Kernel rules	Правила ядра
dpi_kernel_match	match the recorded mode	совпадают с записанным режимом
dpi_kernel_diverged	DO NOT match the recorded mode; run: twebproxy repair %s	НЕ совпадают с записанным режимом; выполните: twebproxy repair %s
rollback_not_performed_eof	Input closed (EOF): nothing was restored.	Ввод закрыт (EOF): ничего не восстановлено.
rollback_not_performed_declined	Cancelled: nothing was restored.	Отменено: ничего не восстановлено.
bridge_bundle_missing	Bridge bundle missing; use the complete verified distribution.	Пакет Bridge отсутствует; используйте полный проверенный дистрибутив.
bridge_launcher_mismatch	Bridge launcher digest mismatch; restore the verified distribution before retrying.	Хеш запускающего модуля Bridge не совпал; восстановите проверенный дистрибутив перед повтором.
bridge_update_busy	Manager update/restore currently running; Bridge preparation blocked. Retry after it finishes.	Уже выполняется обновление или восстановление Manager; подготовка моста заблокирована. Повторите после завершения.
bridge_restore_guard_failed	Offline restore compatibility guard installation failed; Bridge preparation stopped. Check the restore helper and retry.	Не удалось установить защиту совместимости автономного восстановления; подготовка моста остановлена. Проверьте модуль восстановления и повторите.
bridge_ports_busy	Port allocator busy; retry after the other operation finishes.	Порты выделяет другая операция; повторите после её завершения.
bridge_instance_busy	Instance mutation busy; retry after the other operation finishes.	Инстанс изменяет другая операция; повторите после её завершения.
bridge_invalid_forward	Invalid forward port; specify a TCP port from 1 to 65535.	Недопустимый порт перенаправления; укажите TCP-порт от 1 до 65535.
bridge_commit_failed	Bridge profile commit failed; inspect status before retrying.	Не удалось сохранить профиль моста; перед повтором проверьте статус.
bridge_backend_stop_failed	Previous local backend could not be stopped; inspect its service before retrying.	Не удалось остановить прежний локальный сервер; перед повтором проверьте его службу.
bridge_invalid_prior_port	Invalid prior local port; inspect the retained Bridge state.	Недопустимый прежний локальный порт; проверьте сохранённое состояние моста.
bridge_local_not_ready	Local recovery backend not ready; mapping retained. Inspect its service before retrying.	Восстанавливаемый локальный сервер не готов; сопоставление сохранено. Перед повтором проверьте его службу.
bridge_local_validation_failed	Local restore validation failed; inspect the retained configuration before retrying.	Проверка локальной конфигурации при восстановлении не пройдена; проверьте сохранённую конфигурацию перед повтором.
bridge_unknown_internal	Unknown Bridge internal operation; use a documented Manager command.	Неизвестная внутренняя операция моста; используйте документированную команду Manager.
bridge_profile_attached	Bridge MVP: detach via 'twebproxy foreign-node remove' before adding/deleting/rotating profiles.	Профиль подключён к мосту. Перед добавлением, удалением или ротацией выполните «twebproxy foreign-node remove».
bridge_link_usage	Usage: twebproxy connection-link HOST [PROFILE]	Использование: twebproxy connection-link HOST [PROFILE]
bridge_json_verbs	foreign-node --json supports status/diagnose only.	foreign-node --json поддерживает только status/diagnose.
restore_partial_hint	The executables were restored, but %s was not updated (read-only, immutable or full?). Make it writable, e.g. "chattr -i %s", then run "twebproxy repair HOSTNAME".	Исполняемые файлы восстановлены, но %s не обновлён (только для чтения, immutable или нет места?). Сделайте файл записываемым, например «chattr -i %s», затем выполните «twebproxy repair HOSTNAME».
global_env_write_failed	Could not write %s (read-only, immutable or full?); nothing in it was changed. Make it writable, e.g. "chattr -i %s", and repeat.	Не удалось записать %s (только для чтения, immutable или нет места?); файл не изменён. Сделайте его записываемым, например «chattr -i %s», и повторите.
proc_status_hidden	Process list of other users is hidden (procfs %s): MTProxy client secrets are not readable by unprivileged local accounts.	Процессы других пользователей скрыты (procfs %s): secrets клиентов MTProxy недоступны непривилегированным локальным учётным записям.
proc_status_exposed	procfs shows every process to every local user: the MTProxy client secret on its command line is readable by unprivileged accounts. Run: twebproxy proc-hardening enable	procfs показывает все процессы всем локальным пользователям: secret клиента MTProxy в командной строке доступен непривилегированным учётным записям. Выполните: twebproxy proc-hardening enable
proc_status_disabled	procfs hardening was explicitly disabled by the operator: MTProxy client secrets are readable by unprivileged local accounts.	Защита procfs явно отключена оператором: secrets клиентов MTProxy доступны непривилегированным локальным учётным записям.
proc_enabled	procfs now hides other users' processes (hidepid=invisible, exempt group %s; persistent via /etc/fstab).	procfs теперь скрывает процессы других пользователей (hidepid=invisible, группа-исключение %s; сохранено в /etc/fstab).
proc_disabled	procfs hardening disabled; processes of all users are visible again. The audit reports this as an accepted risk.	Защита procfs отключена; процессы всех пользователей снова видны. Аудит отметит это как принятый риск.
proc_failed	Could not apply the procfs policy: %s	Не удалось применить политику procfs: %s
proc_fail_closed	procfs does not hide other users' processes, so MTProxy client secrets would be readable by unprivileged local accounts. Fail-closed: %s TWebProxy MTProxy backend(s) stopped, none started. Fix procfs (twebproxy proc-hardening enable) or accept the risk explicitly (twebproxy proc-hardening disable), then run: twebproxy repair HOST	procfs не скрывает процессы других пользователей, поэтому secrets клиентов MTProxy были бы доступны непривилегированным локальным учётным записям. Fail-closed: остановлено backend MTProxy TWebProxy: %s, ни один не запущен. Исправьте procfs (twebproxy proc-hardening enable) или явно примите риск (twebproxy proc-hardening disable), затем выполните: twebproxy repair HOST
proc_fail_closed_stop_failed	procfs exposes MTProxy client secrets and these backends could not be proven stopped:%s. Stop them manually (systemctl stop UNIT).	procfs раскрывает secrets клиентов MTProxy, и эти backends не удалось гарантированно остановить:%s. Остановите их вручную (systemctl stop UNIT).
proc_disable_confirm	Disable procfs hardening? Every local account will be able to read the MTProxy client secrets.	Отключить защиту procfs? Любая локальная учётная запись сможет прочитать secrets клиентов MTProxy.
proc_disable_declined	procfs hardening left unchanged.	Защита procfs не изменена.
proc_disable_recorded	Accepted risk recorded in %s; every backend start logs it and the audit reports a WARNING.	Принятый риск записан в %s; каждый запуск backend отмечает его в журнале, аудит показывает WARNING.
proc_note_group	Monitoring tools that need to see all processes can be added to group %s.	Инструменты мониторинга, которым нужен полный список процессов, можно добавить в группу %s.
caddy_wait_cert	Waiting up to %s s for Caddy to obtain the certificate for %s...	Жду до %s с, пока Caddy получит сертификат для %s...
caddy_wait_cert_ok	Caddy serves a valid certificate for %s.	Caddy отдаёт действительный сертификат для %s.
caddy_wait_cert_timeout	Caddy has not served a valid certificate for %s within %s s; the audit below reports what it sees. Check DNS and ports 80/443, then run: twebproxy audit %s	Caddy не отдал действительный сертификат для %s за %s с; аудит ниже покажет фактическое состояние. Проверьте DNS и порты 80/443, затем выполните: twebproxy audit %s
UI_I18N
}

ui_msg() {
  local key="$1"; ui_i18n_init
  if [[ "$UI_LANGUAGE" == en ]]; then printf '%s' "${UI_EN[$key]:-$key}"
  else printf '%s' "${UI_RU[$key]:-${UI_EN[$key]:-$key}}"; fi
}

ui_msgf() { local key="$1"; shift; printf "$(ui_msg "$key")" "$@"; }

# Locale-independent UTF-8 byte test for U+0400..U+04FF.  LC_ALL=C makes the
# ranges byte ranges even when the administrator uses POSIX or a non-UTF-8
# locale; no host locale is changed.
ui_contains_cyrillic() {
  LC_ALL=C grep -qE $'[\320-\323][\200-\277]' <<< "${1:-}"
}

ui_untranslated_hex() {
  LC_ALL=C od -An -v -tx1 | tr -d ' \n'
}

# The functional core still contains historical Russian messages with a small
# amount of engineering English. Normalize only their presentation here so the
# protected operational functions remain byte-for-byte stable.
ui_naturalize_ru_legacy() {
  local text="$*"
  text="${text//Offline rollback helper/Офлайн-помощник отката}"
  text="${text//offline rollback helper/офлайн-помощник отката}"
  text="${text//isolation audit/аудит изоляции}"
  text="${text//обновление manager/обновление TWebProxy Manager}"
  text="${text//manager-копии/копии TWebProxy Manager}"
  text="${text//manager не/TWebProxy Manager не}"
  text="${text//manager logs/журналы TWebProxy Manager}"
  text="${text//Certbot renewal dry-run/Проверка продления Certbot без выпуска}"
  text="${text//Force renewal/Принудительное продление}"
  text="${text//Certificate renewal check/Проверка продления сертификата}"
  text="${text//После renewal\/reload/После продления и перезагрузки}"
  text="${text//Certbot renewal/продление Certbot}"
  text="${text//lifecycle сертификата/управление жизненным циклом сертификата}"
  text="${text//legacy-диагностика/расширенная диагностика}"
  text="${text//pre-update backup/резервная копия перед обновлением}"
  text="${text//manager backup/резервная копия TWebProxy Manager}"
  text="${text//backup ID/ID резервной копии}"
  text="${text//создания backup/создания резервной копии}"
  text="${text//проверенных backup/проверенных резервных копий}"
  text="${text//проверенный backup/проверенная резервная копия}"
  text="${text//Проверенный pre-update backup/Проверенная резервная копия перед обновлением}"
  text="${text//из backup/из резервной копии}"
  text="${text//восстанавливаю backup/восстанавливаю резервную копию}"
  text="${text//сделай backup/создай резервную копию}"
  text="${text//bounded health-check/ограниченная проверка работоспособности}"
  text="${text//health-check/проверка работоспособности}"
  text="${text//config check/проверка конфигурации}"
  text="${text//update cache/кэш обновлений}"
  text="${text//update отменён/обновление отменено}"
  text="${text//Update откатан/Обновление отменено и выполнен откат}"
  text="${text//candidate tproxy-server/кандидат tproxy-server}"
  text="${text//binary/исполняемый файл}"
  text="${text//frontend rollback/откат внешнего интерфейса}"
  text="${text//frontend через Manual/внешний интерфейс через ручной режим}"
  text="${text//frontend либо Manual/внешний интерфейс либо ручной режим}"
  text="${text//frontend/внешний интерфейс}"
  text="${text//exact rollback/точный откат}"
  text="${text//retention/очистка старых копий}"
  text="${text//runtime для/рабочее состояние для}"
  text="${text//Runtime восстановлен/Рабочее состояние восстановлено}"
  text="${text//Runtime snapshot/Снимок рабочего состояния}"
  text="${text//не стал ready/не перешёл в состояние готовности}"
  text="${text//и ready/и готов}"
  text="${text//stable Go/стабильную версию Go}"
  text="${text//Carrier mode:/Режим carrier:}"
  text="${text//TLS certificate:/Сертификат TLS:}"
  text="${text//mode=/режим=}"
  text="${text//remaining=/осталось=}"
  text="${text//renewal=/продление=}"
  text="${text//Caddy auto/автоматически через Caddy}"
  text="${text//AUDIT RESULT: FAIL/ИТОГ АУДИТА: ОШИБКА}"
  text="${text//AUDIT RESULT: PASS/ИТОГ АУДИТА: ПРОЙДЕН}"
  text="${text//AUDIT RESULT: INCOMPLETE/ИТОГ АУДИТА: НЕПОЛНЫЙ}"
  text="${text//AUDIT FAIL:/ОШИБКА АУДИТА:}"
  text="${text//AUDIT WARN:/ПРЕДУПРЕЖДЕНИЕ АУДИТА:}"
  text="${text// critical/ критических ошибок}"
  text="${text// warnings/ предупреждений}"
  text="${text//relay service active/служба relay активна}"
  text="${text//relay service не active/служба relay неактивна}"
  text="${text//backend service не active/служба backend неактивна}"
  text="${text//backend firewall service\/table active/служба и таблица межсетевого экрана backend активны}"
  text="${text//backend firewall service\/table отсутствует/служба или таблица межсетевого экрана backend отсутствует}"
  text="${text//loopback only/только loopback}"
  text="${text//non-loopback listener/слушатель вне loopback}"
  text="${text//external isolation обеспечивается nftables/внешняя изоляция обеспечивается nftables}"
  text="${text//stats endpoint не ответил на loopback/источник статистики не ответил через loopback}"
  text="${text//public HTTPS + TLS verification PASS/публичная проверка HTTPS и TLS пройдена}"
  text="${text//public HTTPS\/TLS verification failed/публичная проверка HTTPS\/TLS не пройдена}"
  text="${text//DNS, certificate chain, hostname or frontend/DNS, цепочка сертификатов, hostname или внешний интерфейс}"
  text="${text//automatic TLS manager active/автоматическое управление TLS активно}"
  text="${text//service inactive/служба неактивна}"
  text="${text//auto-renew timer inactive/таймер автоматического продления неактивен}"
  text="${text//auto-renew active/автоматическое продление активно}"
  text="${text//certificate file missing\/unreadable/файл сертификата отсутствует или не читается}"
  text="${text//certificate file missing/файл сертификата отсутствует}"
  text="${text//local\/public certificate MISMATCH/локальный и публичный сертификаты не совпадают}"
  text="${text//local\/public certificate MATCH/локальный и публичный сертификаты совпадают}"
  text="${text//public leaf certificate/открытый конечный сертификат}"
  text="${text//certificate expired/срок действия сертификата истёк}"
  text="${text//certificate expires/срок действия сертификата истекает}"
  text="${text//certificate valid/сертификат действителен}"
  text="${text//active users/активные пользователи}"
  printf '%s' "$text"
}

# Compatibility adapter for functional-core messages that predate FixUI. It is
# deliberately centralized here; new presentation code uses ui_msg keys. Every
# normal user-facing legacy flow has an information-preserving mapping. The hex
# fallback is only an auditable emergency path and is rejected by the FixUI
# acceptance fixtures.
ui_localize_legacy() {
  local text="$*" value="" value2=""
  [[ "$UI_LANGUAGE" == en ]] || { ui_naturalize_ru_legacy "$text"; return; }

  case "$text" in
    # Stage C1 profile/instance state messages.
    'Другая операция изменяет '*) value="${text#Другая операция изменяет }"; printf 'Another operation is changing %s (state lock busy); retry later.' "${value%%; повтори позже.}"; return;;
    'Другая операция выделяет порты; повтори позже.') printf 'Another operation is allocating ports (port lock busy); retry later.'; return;;
    'Не удалось применить новое состояние '*) value="${text#Не удалось применить новое состояние }"; printf 'The new state of %s could not be applied; the previous state was restored.' "${value%%; прежнее состояние восстановлено.}"; return;;
    'ОТКАТ НЕ УДАЛСЯ: проверь состояние '*) value="${text#ОТКАТ НЕ УДАЛСЯ: проверь состояние }"; value="${value%% и выполни*}"; printf "ROLLBACK FAILED: inspect the state of %s and run 'twebproxy repair %s'." "$value" "$value"; return;;
    'Повреждённая запись профиля: '*) printf 'Damaged profile record: %s' "${text#Повреждённая запись профиля: }"; return;;
    'Повреждённая запись инстанса: '*) printf 'Damaged instance record: %s' "${text#Повреждённая запись инстанса: }"; return;;
    'Небезопасный файл состояния: '*) printf 'Unsafe state file: %s' "${text#Небезопасный файл состояния: }"; return;;
    'Небезопасный каталог состояния: '*) printf 'Unsafe state directory: %s' "${text#Небезопасный каталог состояния: }"; return;;
    'Не удалось записать состояние: '*) printf 'Could not write state: %s' "${text#Не удалось записать состояние: }"; return;;
    'Не удалось получить список TCP listeners (ss); порт не считается свободным.') printf 'Could not list TCP listeners (ss); the port is not treated as free.'; return;;
    # Stage C1.1 backend stop / orphan reconciliation messages.
    'Backend '*' без профиля не остановлен или его состояние неизвестно; его env и защита firewall сохранены.') value="${text#Backend }"; printf 'Backend %s without a profile is not stopped or its state is unknown; its env file and firewall protection are kept.' "${value%% без профиля*}"; return;;
    'Backend '*' без профиля остановлен; его env удалён.') value="${text#Backend }"; printf 'Backend %s without a profile was stopped; its env file was removed.' "${value%% без профиля*}"; return;;
    'Backend '*' не остановлен или его состояние неизвестно; ничего не удалено'*) value="${text#Backend }"; value="${value%% не остановлен*}"; printf 'Backend %s is not stopped or its state is unknown; nothing was deleted and firewall protection is kept. Check it (systemctl status %s) and retry.' "$value" "$value"; return;;
    'Backends без профиля у '*) value="${text#Backends без профиля у }"; printf 'Backends without a profile of %s could not be removed safely; their env files and firewall protection are kept.' "${value%% не удалось*}"; return;;
    'Прежнее состояние '*' восстановлено, но backend профиля '*) value="${text#Прежнее состояние }"; value2="${text#*backend профиля }"; printf "The previous state of %s was restored, but the backend of profile %s is not running; run 'twebproxy repair %s'." "${value%% восстановлено*}" "${value2%% не запущен*}" "${value%% восстановлено*}"; return;;
    'У '*' уже есть backend env '*' без профиля; выполни '*) value="${text#У }"; value2="${text#*backend env }"; printf "%s already has backend env %s without a profile; run 'twebproxy repair %s'." "${value%% уже есть*}" "${value2%% без профиля*}" "${value%% уже есть*}"; return;;
    'Часть сервисов '*' могла быть остановлена; '*) value="${text#Часть сервисов }"; printf "Some services of %s may have been stopped; 'twebproxy repair %s' starts them again." "${value%% могла*}" "${value%% могла*}"; return;;
    # Stage C1.2 backend identity / ownership messages.
    'Backend '*' одновременно принадлежит профилям разных инстансов; '*) value="${text#Backend }"; printf 'Backend %s belongs to profiles of several instances at once; nothing was changed. The name conflict needs manual resolution.' "${value%% одновременно*}"; return;;
    'Backend env '*' нельзя однозначно отнести к '*) value="${text#Backend env }"; value2="${text#* нельзя однозначно отнести к }"; printf 'Backend env %s cannot be attributed to %s unambiguously: the name may belong to another instance; the file and its firewall protection are kept.' "${value%% нельзя*}" "${value2%%:*}"; return;;
    'Hostname '*' пересекается с '*' в именах backend'*) value="${text#Hostname }"; value2="${text#* пересекается с }"; printf 'Hostname %s overlaps with %s in backend names (<hostname>--<profile>); the instance was not created and nothing was changed.' "${value%% пересекается*}" "${value2%% в именах*}"; return;;
    'Имя backend '*' уже использует профиль другого инстанса; '*) value="${text#Имя backend }"; printf 'Backend name %s is already used by a profile of another instance; the profile was not created and nothing was changed.' "${value%% уже*}"; return;;
    'Для '*' есть backend env, который нельзя однозначно отнести к этому инстансу; ничего не удалено.') value="${text#Для }"; printf '%s has backend env files that cannot be attributed to this instance unambiguously; nothing was deleted.' "${value%% есть backend*}"; return;;
    # Stage C2 relay lifecycle messages.
    'Другая операция обновляет или перезапускает relay; повтори позже.') printf 'Another operation is updating or restarting the relay (relay lock busy); retry later.'; return;;
    'Не удалось перезапустить relay '*'.') value="${text#Не удалось перезапустить relay }"; printf 'Failed to restart relay %s.' "${value%.}"; return;;
    'Relay twebproxy@'*' не остановлен или его состояние неизвестно; ничего не удалено. '*) value="${text#Relay }"; value="${value%% не остановлен*}"; printf 'Relay %s is not stopped or its state is unknown; nothing was deleted. Check it (systemctl status %s) and retry.' "$value" "$value"; return;;
    'Не удалось сохранить текущий relay binary; update отменён до замены binary.') printf 'Could not save the current relay binary; the update was canceled before the binary was replaced.'; return;;
    'Не удалось записать новый relay binary; прежний binary и relays не изменены.') printf 'Could not write the new relay binary; the previous binary and the relays are unchanged.'; return;;
    'Не удалось установить tproxy-server; прежний binary не изменён.') printf 'Could not install tproxy-server; the previous binary is unchanged.'; return;;
    'Relay twebproxy@'*' не перезапустился с новым binary; восстанавливаю прежний relay binary.') value="${text#Relay }"; printf 'Relay %s did not restart with the new binary; restoring the previous relay binary.' "${value%% не перезапустился*}"; return;;
    'Relay '*' не стал ready с новым binary; восстанавливаю прежний relay binary.') value="${text#Relay }"; printf 'Relay %s did not become ready with the new binary; restoring the previous relay binary.' "${value%% не стал ready*}"; return;;
    'Relay '*' перестал работать после обновления; восстанавливаю прежний relay binary.') value="${text#Relay }"; printf 'Relay %s stopped working after the update; restoring the previous relay binary.' "${value%% перестал*}"; return;;
    'Обновление relay прервано; восстанавливаю прежний relay binary.') printf 'The relay update was interrupted; restoring the previous relay binary.'; return;;
    'Откат relay неполный: прежний binary восстановлен, но не ready: '*) value="${text#*но не ready: }"; printf "Relay rollback incomplete: the previous binary was restored, but these relays are not ready: %s. Check them and run 'twebproxy restart <hostname>'." "${value%%. Проверь*}"; return;;
    'Откат relay не удался: прежний binary не восстановлен, его копия: '*) value="${text#*его копия: }"; value2="${text#*новым binary: }"; printf 'Relay rollback failed: the previous binary was not restored; its copy: %s. Relays restarted with the new binary: %s.' "${value%%. Relays*}" "${value2%.}"; return;;
    # Stage E operations / diagnostics messages.
    'Ввод закрыт (EOF); операция отменена.') printf 'Input closed (EOF); the operation was cancelled.'; return;;
    'Ввод закрыт (EOF); ответ: нет.') printf 'Input closed (EOF); answering no.'; return;;
    'AUDIT WARN: состояние backend firewall неизвестно (systemd или nftables не ответили)') printf 'AUDIT WARN: backend firewall state is unknown (systemd or nftables did not answer)'; return;;
    'AUDIT WARN: состояние '*' неизвестно (systemd недоступен или не ответил)') value="${text#AUDIT WARN: состояние }"; printf 'AUDIT WARN: state of %s is unknown (systemd unavailable or not answering)' "${value%% неизвестно*}"; return;;
    'AUDIT WARN: публичный сертификат недоступен, совпадение с локальным не проверено') printf 'AUDIT WARN: public certificate unavailable; the match with the local certificate was not verified'; return;;
    'AUDIT RESULT: INCOMPLETE ('*) printf '%s' "$text"; return;;
    'Не удалось записать пакет логов в '*) value="${text#Не удалось записать пакет логов в }"; printf 'Could not write the log bundle in %s.' "${value%.}"; return;;
    'Сбор пакета логов прерван; временные файлы удалены.') printf 'Log bundle collection was interrupted; temporary files were removed.'; return;;
    # Stage D frontend / TLS messages.
    'Конфигурацию frontend сейчас меняет другая операция; повтори позже.') printf 'Another operation is changing the frontend configuration (frontend lock busy); retry later.'; return;;
    'Не удалось записать конфигурацию Nginx для '*) value="${text#Не удалось записать конфигурацию Nginx для }"; printf 'Could not write the Nginx configuration for %s; its previous configuration was restored.' "${value%%;*}"; return;;
    'Прервано: изменение frontend уже применено и проверено.') printf 'Interrupted: the frontend change had already been applied and verified.'; return;;
    'Прервано: изменение frontend не применено, и прежнюю конфигурацию восстановить не удалось.') printf 'Interrupted: the frontend change was not applied, and the previous configuration could not be restored.'; return;;
    'Прервано: изменение frontend не применено, прежняя конфигурация восстановлена.') printf 'Interrupted: the frontend change was not applied; the previous configuration was restored.'; return;;
    'Не удалось подготовить candidate Caddyfile в '*) value="${text#Не удалось подготовить candidate Caddyfile в }"; printf 'Could not prepare a candidate Caddyfile in %s.' "${value%.}"; return;;
    'Маркеры блока TWebProxy для '*' в Caddyfile неоднозначны; '*) value="${text#Маркеры блока TWebProxy для }"; printf 'The TWebProxy block markers for %s in the Caddyfile are ambiguous; the Caddyfile was not changed. Fix them manually.' "${value%% в Caddyfile*}"; return;;
    'Активный Caddyfile уже не проходит caddy validate; блок '*) value="${text#*; блок }"; printf 'The active Caddyfile already fails caddy validate; the block for %s was not added and the Caddyfile was not changed.' "${value%% не добавлен*}"; return;;
    'Caddy не применил новую конфигурацию '*', и прежний Caddyfile восстановить не удалось: '*) value="${text#Caddy не применил новую конфигурацию }"; printf 'Caddy did not apply the new configuration for %s, and the previous Caddyfile could not be restored: check %s (the previous version is next to it, *.twebproxy-previous).' "${value%%, и прежний*}" "$CADDYFILE"; return;;
    'Caddy не применил новую конфигурацию '*'; прежний Caddyfile восстановлен'*) value="${text#Caddy не применил новую конфигурацию }"; printf 'Caddy did not apply the new configuration for %s; the previous Caddyfile was restored and Caddy keeps its previous configuration.' "${value%%; прежний*}"; return;;
    'Блок TWebProxy для '*' не удалён из Caddyfile: '*) value="${text#Блок TWebProxy для }"; printf 'The TWebProxy block for %s was not removed from the Caddyfile: its markers are ambiguous or the Caddyfile without it is invalid; the Caddyfile was not changed.' "${value%% не удалён*}"; return;;
    'Caddy не применил Caddyfile без '*', и прежний Caddyfile восстановить не удалось: '*) value="${text#Caddy не применил Caddyfile без }"; printf 'Caddy did not apply the Caddyfile without %s, and the previous Caddyfile could not be restored: check %s (the previous version is next to it, *.twebproxy-previous).' "${value%%, и прежний*}" "$CADDYFILE"; return;;
    'Caddy не применил Caddyfile без '*'; прежний Caddyfile восстановлен.') value="${text#Caddy не применил Caddyfile без }"; printf 'Caddy did not apply the Caddyfile without %s; the previous Caddyfile was restored.' "${value%%; прежний*}"; return;;
    'Не удалось установить Nginx.') printf 'Could not install Nginx.'; return;;
    'Не удалось установить certbot.') printf 'Could not install certbot.'; return;;
    'Не удалось создать временный файл.') printf 'Could not create a temporary file.'; return;;
    'Не удалось подготовить '*'.') value="${text#Не удалось подготовить }"; printf 'Could not prepare %s.' "${value%.}"; return;;
    'Не удалось записать '*'.') value="${text#Не удалось записать }"; printf 'Could not write %s.' "${value%.}"; return;;
    'Nginx уже содержит server_name '*' вне TWebProxy: '*) value="${text#Nginx уже содержит server_name }"; printf 'Nginx already contains server_name %s outside TWebProxy: %s' "${value%% вне TWebProxy:*}" "${text##*вне TWebProxy: }"; return;;
    'Nginx отклонил конфигурацию '*) value="${text#Nginx отклонил конфигурацию }"; printf 'Nginx rejected the configuration for %s (nginx -t); its previous configuration was restored and the running Nginx was not changed.' "${value%% (nginx -t)*}"; return;;
    'Nginx не применил конфигурацию '*) value="${text#Nginx не применил конфигурацию }"; printf 'Nginx did not apply the configuration for %s (reload/start failed); its previous configuration was restored.' "${value%% (reload*}"; return;;
    'Не удалось восстановить прежнюю конфигурацию Nginx для '*) value="${text#Не удалось восстановить прежнюю конфигурацию Nginx для }"; value2="${value#*проверь }"; printf 'Could not restore the previous Nginx configuration for %s: check %s and nginx -t.' "${value%%:*}" "${value2%% и nginx -t*}"; return;;
    'Не удалось восстановить конфигурацию Nginx для '*) value="${text#Не удалось восстановить конфигурацию Nginx для }"; value2="${value#*проверь }"; printf 'Could not restore the Nginx configuration for %s: check %s and nginx -t.' "${value%%:*}" "${value2%% и nginx -t*}"; return;;
    'Файлы Nginx для '*' в неожиданном состоянии '*) value="${text#Файлы Nginx для }"; value="${value%% в неожиданном*}"; printf 'The Nginx files for %s are in an unexpected state (sites-enabled/twebproxy-%s.conf is not a link to its own file); nothing was changed.' "$value" "$value"; return;;
    'Nginx без конфигурации '*' не проходит nginx -t; '*) value="${text#Nginx без конфигурации }"; printf 'Nginx fails nginx -t without the configuration for %s; its files were restored and Nginx was not changed.' "${value%% не проходит*}"; return;;
    'Nginx не перезагрузился без конфигурации '*) value="${text#Nginx не перезагрузился без конфигурации }"; printf 'Nginx did not reload without the configuration for %s; its files were restored.' "${value%%; её*}"; return;;
    'Certbot не смог получить или продлить сертификат '*) value="${text#Certbot не смог получить или продлить сертификат }"; value2="${text##*до истечения: }"; printf 'Certbot could not obtain or renew the certificate for %s; the current certificate stays in service (days until it expires: %s).' "${value%%;*}" "${value2%).}"; return;;
    'Certbot не смог получить сертификат для '*) value="${text#Certbot не смог получить сертификат для }"; printf 'Certbot could not obtain a certificate for %s; existing certificates were not changed.' "${value%%;*}"; return;;
    'Временная HTTP-конфигурация '*' для ACME не убрана; '*) value="${text#Временная HTTP-конфигурация }"; printf 'The temporary ACME HTTP configuration for %s was not removed; check %s' "${value%% для ACME*}" "${text##*проверь }"; return;;
    'Для '*' оставлена временная HTTP-конфигурация ACME: '*) value="${text#Для }"; printf 'The temporary ACME HTTP configuration for %s was kept: the previous one referred to a missing certificate.' "${value%% оставлена*}"; return;;
    'После certbot нет пригодной пары сертификат/ключ для '*) value="${text#После certbot нет пригодной пары сертификат/ключ для }"; printf 'After certbot there is no usable certificate/key pair for %s in %s' "${value%% в *}" "${value#* в }"; return;;
    'Пути к сертификату и ключу должны быть абсолютными, без пробелов и спецсимволов: '*) printf 'The certificate and key paths must be absolute, without spaces or special characters: %s' "${text#*спецсимволов: }"; return;;
    'Ключ '*' не соответствует сертификату '*) value="${text#Ключ }"; value2="${text#* не соответствует сертификату }"; printf 'Key %s does not match certificate %s.' "${value%% не соответствует*}" "${value2%.}"; return;;
    'Сертификат '*' уже истёк.') value="${text#Сертификат }"; printf 'Certificate %s has already expired.' "${value% уже истёк.}"; return;;
    'Ключ '*' доступен для чтения всем пользователям; '*) value="${text#Ключ }"; printf 'Key %s is readable by all users; restrict its permissions (chmod 600).' "${value%% доступен*}"; return;;
    'Frontend для '*' не удалён; ничего не удалено, инстанс продолжает работать.') value="${text#Frontend для }"; printf 'The frontend for %s was not removed; nothing was deleted and the instance keeps serving.' "${value%% не удалён*}"; return;;
    'Frontend '*' уже отключён; '*) value="${text#Frontend }"; value="${value%% уже отключён*}"; printf "The frontend for %s is already removed; 'twebproxy repair %s' restores it." "$value" "$value"; return;;
    'Нет пригодного сертификата Let'"'"'s Encrypt для '*) value="${text#*Encrypt для }"; printf "No usable Let's Encrypt certificate for %s; run 'twebproxy repair %s'." "${value%%;*}" "${value%%;*}"; return;;
    'Certbot dry-run для '*' не прошёл; '*) value="${text#Certbot dry-run для }"; printf 'The Certbot dry run for %s failed; the active certificate was not changed.' "${value%% не прошёл*}"; return;;
    'Certbot не продлил сертификат '*) value="${text#Certbot не продлил сертификат }"; printf 'Certbot did not renew the certificate for %s; the previous certificate is kept and still used.' "${value%%;*}"; return;;
    'Сертификат '*' продлён на диске, но nginx -t не проходит; '*) value="${text#Сертификат }"; printf 'The certificate for %s was renewed on disk, but nginx -t fails; Nginx was not reloaded and still serves the previous certificate.' "${value%% продлён*}"; return;;
    'Сертификат '*' продлён на диске, но reload Nginx не удался; '*) value="${text#Сертификат }"; printf 'The certificate for %s was renewed on disk, but the Nginx reload failed; Nginx still serves the previous certificate.' "${value%% продлён*}"; return;;
    'Nginx не запущен; сертификат '*) value="${text#Nginx не запущен; сертификат }"; printf 'Nginx is not running; the certificate for %s was renewed on disk but is not in use.' "${value%% продлён*}"; return;;
    'Запусти от root:'*) printf 'Run as root:%s' "${text#*:}"; return;;
    'Нужен systemd.') printf 'systemd is required.'; return;;
    'jq нужен для --json output.') printf 'jq is required for --json output.'; return;;
    'Сейчас поддерживается x86_64 Linux.') printf 'Only x86_64 Linux is currently supported.'; return;;
    'Не найден /etc/os-release.') printf '/etc/os-release was not found.'; return;;
    'Поддерживаются Debian/Ubuntu. Обнаружено:'*) printf 'Debian/Ubuntu are supported. Detected:%s' "${text#*:}"; return;;
    'apt-get не найден.') printf 'apt-get was not found.'; return;;

    'Hostname WEB-proxy (без https://)') printf 'WEB Proxy hostname (without https://)'; return;;
    'Имя профиля/секрета') printf 'Profile/secret name'; return;;
    'Путь к каталогу с index.html') printf 'Path to the directory containing index.html'; return;;
    'Путь к fullchain.pem') printf 'Path to fullchain.pem'; return;;
    'Путь к privkey.pem') printf 'Path to privkey.pem'; return;;
    'Email для Let’s Encrypt') printf 'Email for Let’s Encrypt'; return;;
    'Новый secret:') printf 'New secret:'; return;;
    'Carrier mode:') printf 'Carrier mode:'; return;;
    'Обычный сайт на hostname:') printf 'Regular website on the hostname:'; return;;
    'Уникальная автозаглушка (только для теста)') printf 'Unique generated placeholder (testing only)'; return;;
    'Скопировать мой статический сайт') printf 'Copy my static website'; return;;
    'Проксировать существующее web-приложение на loopback') printf 'Proxy an existing loopback web application'; return;;
    'Caddy — автоматический сертификат') printf 'Caddy — automatic certificate'; return;;
    'Nginx + мой certificate/key') printf 'Nginx + my certificate/key'; return;;
    'Manual — фронт 443 уже настроен') printf 'Manual — the port 443 frontend is already configured'; return;;
    'https — консервативный baseline') printf 'https — conservative baseline'; return;;
    'https-lanes — отдельные HTTP/2 lanes') printf 'https-lanes — separate HTTP/2 lanes'; return;;
    'websocket — один мультиплексированный WSS') printf 'websocket — one multiplexed WSS connection'; return;;
    'websocket-lanes — отдельный WSS на поток') printf 'websocket-lanes — a separate WSS connection per stream'; return;;

    'Сгенерировать новый 16-byte secret?') printf 'Generate a new 16-byte secret?'; return;;
    'Сгенерировать новый secret?') printf 'Generate a new secret?'; return;;
    'Создать?') printf 'Create it?'; return;;
    'Удалить core?') printf 'Remove the core?'; return;;
    'Внутренние relay/admin порты подобрать автоматически?') printf 'Choose internal relay/admin ports automatically?'; return;;
    'Backend/stats порты подобрать автоматически?') printf 'Choose backend/statistics ports automatically?'; return;;
    'DNS пока не совпадает. Продолжить?') printf 'DNS does not match yet. Continue?'; return;;
    'UFW активен. Разрешить TCP 80 и 443?') printf 'UFW is active. Allow TCP ports 80 and 443?'; return;;
    'Восстановить самый новый проверенный manager backup?') printf 'Restore the newest verified Manager backup?'; return;;
    'Восстановить manager из '*) printf 'Restore the Manager from %s' "${text#Восстановить manager из }"; return;;
    'Удалить профиль '*) printf 'Delete profile %s' "${text#Удалить профиль }"; return;;
    'Удалить '*) printf 'Delete %s' "${text#Удалить }"; return;;

    'Некорректный порт.') printf 'Invalid port.'; return;;
    'Некорректный secret.') printf 'Invalid secret.'; return;;
    'Некорректный email.') printf 'Invalid email address.'; return;;
    'Некорректный backup ID.') printf 'Invalid backup ID.'; return;;
    'Профиль уже существует.') printf 'The profile already exists.'; return;;
    'Порты должны быть разными.') printf 'The ports must be different.'; return;;
    'Backend и stats ports должны отличаться.') printf 'Backend and statistics ports must be different.'; return;;
    'Нужен lowercase ASCII/ACE hostname вида proxy.example.com') printf 'Enter a lowercase ASCII/ACE hostname such as proxy.example.com.'; return;;
    'Имя: a-z, 0-9, _ и -, максимум 32 символа.') printf 'Use a-z, 0-9, _ or -; maximum length is 32 characters.'; return;;
    'max connections должен быть > 0') printf 'max connections must be greater than 0.'; return;;
    'Неизвестный SITE_MODE='*) printf 'Unknown SITE_MODE=%s' "${text#*=}"; return;;
    'Неизвестный TLS_MODE='*) printf 'Unknown TLS_MODE=%s' "${text#*=}"; return;;

    'Проверяю базовые зависимости...') printf 'Checking base dependencies...'; return;;
    'Ставлю актуальный stable Go с проверкой SHA-256...') printf 'Installing the current stable Go release with SHA-256 verification...'; return;;
    'Синхронизирую telegramdesktop/tproxy-server:'*) printf 'Synchronizing telegramdesktop/tproxy-server:%s' "${text#*:}"; return;;
    'Обновляю telegramdesktop/tproxy-server:'*) printf 'Updating telegramdesktop/tproxy-server:%s' "${text#*:}"; return;;
    'Тестирую и собираю WEB relay...') printf 'Testing and building the WEB relay...'; return;;
    'Relay собран.') printf 'Relay built.'; return;;
    'Собираю официальный MTProxy на закреплённом commit '*) printf 'Building official MTProxy at pinned commit %s' "${text#*commit }"; return;;
    'Получаю официальный proxy-secret и proxy-multi.conf...') printf 'Fetching official proxy-secret and proxy-multi.conf...'; return;;
    'Базовая часть TWebProxy ещё не установлена. Установлю её сейчас.') printf 'The TWebProxy core is not installed yet. Installing it now.'; return;;
    'База TWebProxy установлена.'*) printf 'TWebProxy core installed. Add a hostname with: twebproxy add'; return;;

    'Инстанс не найден:'*) printf 'Instance not found:%s' "${text#*:}"; return;;
    Инстанс\ *\ уже\ существует.) value="${text#Инстанс }"; printf 'Instance %s already exists.' "${value% уже существует.}"; return;;
    Профиль\ *\ не\ найден\ у\ *) value="${text#Профиль }"; printf 'Profile %s was not found on %s' "${value%% не найден у *}" "${value#* не найден у }"; return;;
    'Нет настроенных hostname.') printf 'No configured hostnames.'; return;;
    'Нет каталога профилей у '*) printf 'Profile directory is missing for %s' "${text#Нет каталога профилей у }"; return;;
    У\ *\ должен\ оставаться\ хотя\ бы\ один\ профиль.) value="${text#У }"; printf '%s must retain at least one profile.' "${value% должен оставаться хотя бы один профиль.}"; return;;
    'Нет свободного relay port.') printf 'No free relay port is available.'; return;;
    'Нет свободного admin port.') printf 'No free admin port is available.'; return;;
    'Нет свободного backend port.') printf 'No free backend port is available.'; return;;
    'Нет свободного stats port.') printf 'No free statistics port is available.'; return;;
    'Нет instance state для '*) printf 'No instance state exists for %s' "${text#Нет instance state для }"; return;;
    'Нет ответа stats у '*) printf 'No statistics response from %s' "${text#Нет ответа stats у }"; return;;
    'Нет '*) printf '%s does not exist.' "${text#Нет }"; return;;

    Порт\ *\ уже\ занят\ или\ зарегистрирован\ TWebProxy.) value="${text#Порт }"; printf 'Port %s is already in use or registered by TWebProxy.' "${value% уже занят или зарегистрирован TWebProxy.}"; return;;
    DNS\ A\ для\ *\ пока\ не\ резолвится.) value="${text#DNS A для }"; printf 'DNS A for %s does not resolve yet.' "${value% пока не резолвится.}"; return;;
    'DNS A:'*) printf '%s' "$text"; return;;
    A-запись\ *не\ совпадает\ с\ публичным\ IPv4\ сервера*) value="${text#A-запись (}"; value2="${value#*) не совпадает с публичным IPv4 сервера (}"; printf 'The A record (%s) does not match the server public IPv4 address (%s).' "${value%%)*}" "${value2%)*}"; return;;
    'Внутренние сервисы работают без root; используй порт >= 1024.') printf 'Internal services run without root; use a port greater than or equal to 1024.'; return;;

    MTProxy\ backend\ *\ не\ стал\ ready.) value="${text#MTProxy backend }"; printf 'MTProxy backend %s did not become ready.' "${value% не стал ready.}"; return;;
    Relay\ *\ не\ стал\ ready.) value="${text#Relay }"; printf 'Relay %s did not become ready.' "${value% не стал ready.}"; return;;
    'Проверяю и восстанавливаю runtime для '*) printf 'Checking and repairing runtime state for %s' "${text#Проверяю и восстанавливаю runtime для }"; return;;
    Инстанс\ создан,\ но\ isolation\ audit\ для\ *\ не\ пройден.) value="${text#Инстанс создан, но isolation audit для }"; printf 'The instance was created, but the isolation audit failed for %s.' "${value% не пройден.}"; return;;
    Инстанс\ *\ создан\ и\ прошёл\ isolation\ audit.) value="${text#Инстанс }"; printf 'Instance %s was created and passed the isolation audit.' "${value% создан и прошёл isolation audit.}"; return;;
    Runtime\ восстановлен,\ но\ isolation\ audit\ для\ *\ не\ пройден.) value="${text#Runtime восстановлен, но isolation audit для }"; printf 'Runtime state was repaired, but the isolation audit failed for %s.' "${value% не пройден.}"; return;;
    Инстанс\ *\ восстановлен\ и\ прошёл\ readiness/isolation\ checks.) value="${text#Инстанс }"; printf 'Instance %s was repaired and passed readiness and isolation checks.' "${value% восстановлен и прошёл readiness/isolation checks.}"; return;;
    Профиль\ *\ добавлен.) value="${text#Профиль }"; printf 'Profile %s was added.' "${value% добавлен.}"; return;;
    Профиль\ *\ удалён.) value="${text#Профиль }"; printf 'Profile %s was deleted.' "${value% удалён.}"; return;;
    Secret\ *\ заменён.\ Старый\ больше\ не\ работает.) value="${text#Secret }"; printf 'Secret %s was replaced. The old secret no longer works.' "${value% заменён. Старый больше не работает.}"; return;;
    'Carrier профиля '*) value="${text#Carrier профиля }"; printf 'Profile carrier %s' "$value"; return;;
    *' перезапущен и ready.') value="${text% перезапущен и ready.}"; printf '%s was restarted and is ready.' "$value"; return;;
    'Manager обновлён, но update cache не удалён.') printf 'The Manager was updated, but the update cache was not removed.'; return;;
    *' удалён.') value="${text% удалён.}"; printf '%s was deleted.' "$value"; return;;

    'Добавление профиля перезапускает relay и сбрасывает активные WEB-сессии; Telegram переподключится автоматически.') printf 'Adding a profile restarts the relay and drops active WEB sessions; Telegram reconnects automatically.'; return;;
    Нельзя\ удалить\ последний\ профиль.\ Удали\ весь\ hostname\ через\ *) printf "The last profile cannot be deleted. Remove the entire hostname with 'twebproxy delete'."; return;;
    Удалится\ secret\ *) value="${text#Удалится secret }"; printf 'Secret %s' "${value%% и его backend.*}"; printf ' and its backend will be deleted. Clients using this secret will disconnect immediately.'; return;;
    'Будет удалён hostname '*) value="${text#Будет удалён hostname }"; printf 'Hostname %s' "${value%%,*}"; printf ', all of its secrets/backends, and its managed reverse-proxy block will be deleted.'; return;;
    'Удалится база TWebProxy,'*) printf 'The TWebProxy core, systemd templates, relay binary, and official MTProxy build will be deleted.'; return;;
    'Core удалён. Manager оставлен:'*) printf 'Core removed. Manager retained:%s' "${text#*:}"; return;;
    'Логи сохранены:'*) printf 'Logs retained:%s' "${text#*:}"; return;;

    'Offline rollback helper отсутствует или небезопасен:'*) printf 'The offline rollback helper is missing or unsafe:%s' "${text#*:}"; return;;
    'Offline rollback helper отсутствует или небезопасен; обновление остановлено до создания backup.') printf 'The offline rollback helper is missing or unsafe; the update stopped before backup creation.'; return;;
    'Manager update уже выполняется или lock небезопасен:'*) printf 'A Manager update is already running or the lock is unsafe:%s' "${text#*:}"; return;;
    'Текущие manager-копии не образуют точное безопасное состояние; обновление остановлено до создания backup. Если прошлое обновление было прервано, восстанови проверенную копию без сети: '*) printf 'The current Manager copies do not form an exact safe state; the update stopped before backup creation. If an earlier update was interrupted, restore the verified copy offline: %s' "${text##*без сети: }"; return;;
    'Закрытый каталог обновления в '*) value="${text#Закрытый каталог обновления в }"; printf 'The private update directory in %s could not be prepared; the Manager was not changed.' "${value%% не подготовлен;*}"; return;;
    'Значение --sha256 должно состоять из 64 шестнадцатеричных символов.') printf 'The --sha256 value must be 64 hexadecimal characters.'; return;;
    'Неизвестный параметр manager-update: '*) value="${text#Неизвестный параметр manager-update: }"; printf 'Unknown manager-update option: %s. Allowed: --force, --sha256 <SHA-256>.' "${value%. Допустимо:*}"; return;;
    'Не удалось получить последний стабильный релиз TWebProxy Manager с '*) value="${text#Не удалось получить последний стабильный релиз TWebProxy Manager с }"; printf 'Could not obtain the latest stable TWebProxy Manager release from %s: no release is published, the answer is invalid, or the network is unavailable.' "${value%%: релиз не опубликован*}"; return;;
    'В этой сборке не закреплён ключ подписи релизов: manager-update установит релиз только с --sha256, полученным из независимого источника (docs/UPDATES.md).') printf 'This build pins no release-signing key: manager-update installs a release only with --sha256 obtained from an independent source (docs/UPDATES.md).'; return;;
    'Доступна версия '*', но в этой сборке не закреплён ключ подписи релизов'*) value="${text#Доступна версия }"; printf 'Version %s is available, but this build pins no release-signing key, and a SHA256SUMS file from the same source does not prove authenticity. Automatic update is disabled: pass --sha256 <SHA-256 from an independent source> or update manually (docs/UPDATES.md).' "${value%%, но в этой сборке*}"; return;;
    'Релиз '*' не публикует подписанный манифест ('*) value="${text#Релиз }"; value2="${text#*манифест (}"; printf 'Release %s does not publish the signed manifest (%s and .sig) at the expected GitHub address; the Manager was not changed.' "${value%% не публикует*}" "${value2%% и .sig)*}"; return;;
    'Подпись манифеста релиза '*) value="${text#Подпись манифеста релиза }"; printf 'The release manifest signature of %s is not confirmed by a pinned key; the Manager was not changed.' "${value%% не подтверждена*}"; return;;
    'Манифест релиза '*) value="${text#Манифест релиза }"; printf 'The release manifest of %s is invalid or does not match the release; the Manager was not changed.' "${value%% некорректен*}"; return;;
    'SHA-256 из --sha256 не совпадает с подписанным манифестом релиза '*) value="${text#SHA-256 из --sha256 не совпадает с подписанным манифестом релиза }"; printf 'The --sha256 value does not match the signed release manifest of %s; the Manager was not changed.' "${value%%; manager не изменён.}"; return;;
    'Не удалось скачать manager '*) value="${text#Не удалось скачать manager }"; value2="${value#* с }"; printf 'Could not download Manager %s from %s without a redirect; the Manager was not changed.' "${value%% с *}" "${value2%% без переадресации*}"; return;;
    'SHA-256 скачанного manager не совпадает с доверенным значением ('*) value="${text#*значением (}"; printf 'The SHA-256 of the downloaded Manager does not match the trusted value (%s); the Manager was not changed.' "${value%%)*}"; return;;
    'Скачанный manager не проходит bash -n или '*) value="${text#*соответствуют релизу }"; printf 'The downloaded Manager fails bash -n, or its MANAGER_VERSION / MANAGER_RELEASE_VERSION do not match release %s; the Manager was not changed.' "${value%%; manager не изменён.}"; return;;
    'Новая версия не установлена; '*) printf 'The new version was not installed; neither Manager copy changed (verified by SHA-256). The verified backup was retained: %s' "${text##*сохранена: }"; return;;
    'Откат не подтверждён. Восстанови TWebProxy Manager без сети: '*) value="${text#*без сети: }"; value2="${value#* restore }"; printf 'Rollback was not confirmed. Restore TWebProxy Manager offline: %s restore %s (or restore-latest; list: %s list).' "${value%% restore *}" "${value2%% (или*}" "${value%% restore *}"; return;;
    'Копии TWebProxy Manager не синхронизированы: '*) value="${text#*TWebProxy Manager (}"; printf 'TWebProxy Manager copies were not synchronised: a TWebProxy Manager update or rollback is running (%s).' "${value%)*}"; return;;
    'Доступна новая версия TWebProxy Manager:'*) printf 'A new TWebProxy Manager version is available:%s' "${text#*:}"; return;;
    Локальная\ версия\ *\ новее\ опубликованной\ *) value="${text#Локальная версия }"; printf 'Local version %s is newer than published version %s' "${value%% новее опубликованной *}" "${value#* новее опубликованной }"; return;;
    TWebProxy\ Manager\ *\ —\ актуальная\ версия.) value="${text#TWebProxy Manager }"; printf 'TWebProxy Manager %s is up to date.' "${value% — актуальная версия.}"; return;;
    TWebProxy\ Manager\ *\ уже\ актуален.) value="${text#TWebProxy Manager }"; printf 'TWebProxy Manager %s is already up to date.' "${value% уже актуален.}"; return;;
    Опубликованная\ версия\ *) value="${text#Опубликованная версия }"; value2="${value#* не новее локальной }"; printf 'Published version %s is not newer than local version %s. To force installation, run: manager-update --force' "${value%% не новее локальной *}" "${value2%%. Для принудительной*}"; return;;
    'Скачиваю TWebProxy Manager '*) printf 'Downloading %s' "${text#Скачиваю }"; return;;
    'Не удалось создать и проверить локальный pre-update backup; manager не изменён.') printf 'Failed to create and verify the local pre-update backup; the Manager was not changed.'; return;;
    'Проверенный pre-update backup:'*) printf 'Verified pre-update backup:%s' "${text#*:}"; return;;
    'Установка или bounded health-check не завершились. Выполняю один exact rollback:'*) printf 'Installation or the bounded health check did not complete. Performing one exact rollback:%s' "${text#*:}"; return;;
    'Не удалось выполнить retention проверенных backup; содержимое оставлено без изменений.') printf 'Failed to prune verified backups; their contents were left unchanged.'; return;;
    'Manager обновлён, но не удалось обновить metadata в global.env; следующий repair исправит metadata.') printf 'The Manager was updated, but global.env metadata could not be updated; the next repair will correct it.'; return;;
    'Manager обновлён, но update cache не удалён.') printf 'The Manager was updated, but the update cache was not removed.'; return;;
    'Manager обновлён, но retention проверенных backup не выполнен.') printf 'The Manager was updated, but verified-backup retention did not complete.'; return;;
    'TWebProxy Manager обновлён:'*) printf 'TWebProxy Manager updated:%s' "${text#*:}"; return;;

    'certbot не установлен.') printf 'certbot is not installed.'; return;;
    'certbot не установлен. Запусти repair.') printf 'certbot is not installed. Run repair.'; return;;
    'Сертификат не читается:'*) printf 'Certificate is not readable:%s' "${text#*:}"; return;;
    'Ключ не читается:'*) printf 'Key is not readable:%s' "${text#*:}"; return;;
    'Некорректный PEM certificate.') printf 'Invalid PEM certificate.'; return;;
    'Некорректный PEM key.') printf 'Invalid PEM key.'; return;;
    Проверяю\ необходимость\ продления\ Let*) value="${text#* для }"; printf "Checking whether Let's Encrypt renewal is due for %s" "$value"; return;;
    'Certbot renewal dry-run PASS; рабочий сертификат не заменялся.') printf 'Certbot renewal dry run passed; the active certificate was not replaced.'; return;;
    Force\ renewal\ может\ приблизить\ rate\ limit\ Let*) printf "Forced renewal may bring the Let's Encrypt rate limit closer."; return;;
    'Certificate renewal check завершён; strict HTTPS PASS.') printf 'Certificate renewal check completed; strict HTTPS passed.'; return;;
    'После renewal/reload публичная TLS-проверка не прошла.') printf 'Public TLS verification failed after renewal and reload.'; return;;
    'Caddy управляет выпуском и продлением сертификата автоматически;'*) printf 'Caddy manages certificate issuance and renewal automatically; manual Certbot renewal is not required.'; return;;
    'TLS mode nginx-custom:'*) printf 'TLS mode nginx-custom: the Manager cannot reissue a custom certificate. Replace the certificate and key through the CA, then run repair.'; return;;
    'TLS mode manual:'*) printf 'TLS mode manual: certificate lifecycle is managed by the external frontend.'; return;;
    'Не удалось получить публичный leaf certificate с '*) printf 'Failed to obtain the public leaf certificate from %s' "${text#Не удалось получить публичный leaf certificate с }"; return;;
    'Local Let'*' certificate не найден:'*) printf "Local Let's Encrypt certificate was not found:%s" "${text#*:}"; return;;

    'AUDIT RESULT: FAIL ('*) printf '%s' "$text"; return;;
    'AUDIT RESULT: PASS ('*) printf '%s' "$text"; return;;
    'AUDIT FAIL: нет instance state для '*) printf 'AUDIT FAIL: no instance state exists for %s' "${text#AUDIT FAIL: нет instance state для }"; return;;
    'AUDIT FAIL: relay service не active') printf 'AUDIT FAIL: relay service is not active'; return;;
    *': MTProxy sandbox включает AF_NETLINK') printf '%s: MTProxy sandbox allows AF_NETLINK' "${text%%: MTProxy sandbox включает AF_NETLINK}"; return;;
    'AUDIT FAIL: backend firewall service/table отсутствует') printf 'AUDIT FAIL: backend firewall service/table is missing'; return;;
    AUDIT\ FAIL:\ у\ *\ нет\ profiles/backends) value="${text#AUDIT FAIL: у }"; printf 'AUDIT FAIL: %s has no profiles/backends' "${value% нет profiles/backends}"; return;;
    AUDIT\ FAIL:\ *\ backend\ service\ не\ active) value="${text#AUDIT FAIL: }"; printf 'AUDIT FAIL: %s backend service is not active' "${value% backend service не active}"; return;;
    AUDIT\ WARN:\ *\ unit\ без\ AF_NETLINK*) value="${text#AUDIT WARN: }"; printf 'AUDIT WARN: %s unit does not allow AF_NETLINK; run repair with the current Manager version' "${value%% unit без AF_NETLINK*}"; return;;
    *': socket filter PID 1 (IPAddressDeny=any) активен независимо от nftables') printf '%s: PID 1 socket filter (IPAddressDeny=any) is active independently of nftables' "${text%%: socket filter PID 1*}"; return;;
    AUDIT\ WARN:\ состояние\ socket\ filter\ *\ неизвестно*) value="${text#AUDIT WARN: состояние socket filter }"; printf 'AUDIT WARN: the socket filter state of %s is unknown (systemd unavailable or did not answer)' "${value%% неизвестно*}"; return;;
    AUDIT\ FAIL:\ *\ socket\ filter\ backend\ отсутствует\ или\ обходится*) value="${text#AUDIT FAIL: }"; value2="${value#* обходится }"; printf 'AUDIT FAIL: %s backend socket filter is missing or bypassed %s; run repair with the current Manager version' "${value%% socket filter backend*}" "${value2%%;*}"; return;;
    'AUDIT WARN: адреса DC вне allowlist backend (недоступны для MTProxy): '*) value="${text#*MTProxy): }"; printf 'AUDIT WARN: DC addresses outside the backend allowlist (unreachable for MTProxy): %s; update the Manager' "${value%%; обновите manager}"; return;;
    AUDIT\ FAIL:\ *\ port\ *\ не\ слушается) value="${text#AUDIT FAIL: }"; value="${value% не слушается}"; printf 'AUDIT FAIL: %s is not listening' "$value"; return;;
    AUDIT\ FAIL:\ *\ имеет\ non-loopback\ listener\(s\):*) value="${text#AUDIT FAIL: }"; printf 'AUDIT FAIL: %s' "${value/ имеет non-loopback listener(s):/ has non-loopback listener(s):}"; return;;
    AUDIT\ FAIL:\ *\ не\ найден\ в\ backend\ firewall\ rule) value="${text#AUDIT FAIL: }"; printf 'AUDIT FAIL: %s is missing from the backend firewall rule' "${value% не найден в backend firewall rule}"; return;;
    AUDIT\ WARN:\ *\ stats\ endpoint\ не\ ответил\ на\ loopback) value="${text#AUDIT WARN: }"; printf 'AUDIT WARN: %s statistics endpoint did not respond on loopback' "${value% stats endpoint не ответил на loopback}"; return;;
    'AUDIT WARN: не удалось отдельно прочитать public leaf certificate') printf 'AUDIT WARN: the public leaf certificate could not be read separately'; return;;
    *' покрыт nftables') printf '%s is covered by nftables' "${text% покрыт nftables}"; return;;
    *' обеспечивает nftables') printf '%s is isolated by nftables' "${text% обеспечивает nftables}"; return;;
    *' обеспечивается nftables') printf '%s is enforced by nftables' "${text% обеспечивается nftables}"; return;;

    'Не удалось получить relay /metrics.') printf 'Failed to obtain relay /metrics.'; return;;
    'Нет ответа stats у '*) printf 'No statistics response from %s' "${text#Нет ответа stats у }"; return;;
    'Runtime snapshot сохранён:'*) printf 'Runtime snapshot saved:%s' "${text#*:}"; return;;
    'Пакет логов готов:'*) printf 'Log bundle is ready:%s' "${text#*:}"; return;;
    'Предыдущих manager logs пока нет.') printf 'No previous Manager logs are available yet.'; return;;
    'Количество строк:'*) printf 'Line count:%s' "${text#*:}"; return;;
    'Использование:'*) printf 'Usage:%s' "${text#*:}"; return;;
    '--json и --raw взаимоисключающие.') printf '%s' '--json and --raw are mutually exclusive.'; return;;
    *' пока не поддерживает --'*) value="${text%% пока не поддерживает *}"; value2="${text##*--}"; printf '%s does not support --%s yet.' "$value" "$value2"; return;;

    'Не удалось определить stable Go.') printf 'Failed to determine the current stable Go version.'; return;;
    'Не удалось получить SHA-256 Go.') printf 'Failed to obtain the Go SHA-256 checksum.'; return;;
    'SHA-256 Go не совпал.') printf 'The Go SHA-256 checksum did not match.'; return;;
    У\ *\ неожиданный\ origin:*) value="${text#У }"; printf '%s has an unexpected origin:%s' "${value%% неожиданный origin:*}" "${text##*origin:}"; return;;
    'Validated tproxy-server commit недоступен в upstream repository.') printf 'The validated tproxy-server commit is unavailable in the upstream repository.'; return;;
    'Не удалось checkout validated tproxy-server commit.') printf 'Failed to check out the validated tproxy-server commit.'; return;;
    'Upstream test suite tproxy-server не прошёл; установка relay остановлена.') printf 'The upstream tproxy-server test suite failed; relay installation stopped.'; return;;
    'Не удалось собрать tproxy-server.') printf 'Failed to build tproxy-server.'; return;;
    'Не удалось собрать официальный MTProxy.') printf 'Failed to build official MTProxy.'; return;;
    'MTProxy не собрался.') printf 'MTProxy was not built.'; return;;
    'Official MTProxy собран и установлен:'*) printf 'Official MTProxy built and installed:%s' "${text#*:}"; return;;
    'proxy-secret подозрительно короткий.') printf 'proxy-secret is unexpectedly short.'; return;;
    'proxy-multi.conf подозрительно короткий.') printf 'proxy-multi.conf is unexpectedly short.'; return;;
    'proxy-multi.conf не прошёл проверку.') printf 'proxy-multi.conf failed validation.'; return;;

    'Max connections на worker') printf 'Maximum connections per worker'; return;;
    'Автозаглушка пригодна для теста,'*) printf 'The generated placeholder is suitable for testing, but replace it with a real website for permanent use.'; return;;
    В\ *\ нет\ читаемого\ index.html.) value="${text#В }"; printf '%s does not contain a readable index.html.' "${value% нет читаемого index.html.}"; return;;
    'public_upstream должен быть numeric loopback URL.') printf 'public_upstream must be a numeric loopback URL.'; return;;
    TWebProxy\ уже\ использует\ managed\ *) value="${text#TWebProxy уже использует managed }"; printf 'TWebProxy already uses managed %s on ports 80/443. Choose the same frontend for the new hostname, or use Manual.' "${value%% на 80/443.*}"; return;;
    TCP/*' уже занят не Caddy:'*) value="${text#TCP/}"; value2="${text#*: }"; printf 'TCP port %s is occupied by a process other than Caddy: %s. Use the existing frontend through Manual or free the port.' "${value%% уже занят не Caddy:*}" "${value2%%. Используй существующий*}"; return;;
    TCP/*' уже занят не Nginx:'*) value="${text#TCP/}"; value2="${text#*: }"; printf 'TCP port %s is occupied by a process other than Nginx: %s. Use the existing frontend through Manual or free the port.' "${value%% уже занят не Nginx:*}" "${value2%%. Используй существующий*}"; return;;
    'Не удалось установить Caddy. Используй Nginx или manual.') printf 'Failed to install Caddy. Use Nginx or Manual.'; return;;
    'Другой TWebProxy-инстанс уже использует Nginx на 80/443.'*) printf 'Another TWebProxy instance already uses Nginx on ports 80/443. Managed Caddy cannot run in parallel.'; return;;
    'Другой TWebProxy-инстанс уже использует Caddy на 80/443.'*) printf 'Another TWebProxy instance already uses Caddy on ports 80/443. Managed Nginx cannot run in parallel.'; return;;
    В\ Caddyfile\ уже\ есть\ *) value="${text#В Caddyfile уже есть }"; printf 'Caddyfile already contains %s outside the TWebProxy-managed block.' "${value% вне управляемого блока TWebProxy.}"; return;;
    'Candidate Caddyfile не прошёл validate; активный Caddyfile не изменён.') printf 'The candidate Caddyfile failed validation; the active Caddyfile was not changed.'; return;;
    'Caddy reload не прошёл; возвращаю предыдущий Caddyfile.') printf 'Caddy reload failed; restoring the previous Caddyfile.'; return;;
    'Caddy frontend rollback выполнен после неуспешного reload.') printf 'The Caddy frontend was rolled back after a failed reload.'; return;;
    Nginx\ уже\ содержит\ server_name\ *) value="${text#Nginx уже содержит server_name }"; printf 'Nginx already contains server_name %s outside TWebProxy.' "${value% вне TWebProxy.}"; return;;
    'Caddy reload после удаления блока не прошёл; восстанавливаю backup.') printf 'Caddy reload failed after block removal; restoring the backup.'; return;;
    'Caddy candidate после удаления блока невалиден; активный Caddyfile оставлен без изменений.') printf 'The Caddy candidate is invalid after block removal; the active Caddyfile was left unchanged.'; return;;
    Manual\ TLS:\ публичный\ *) value="${text#Manual TLS: публичный }"; value2="${value#* должен проксировать ВЕСЬ hostname на }"; printf 'Manual TLS: public %s must proxy the entire hostname to %s with the original Host header.' "${value%% должен проксировать ВЕСЬ hostname на *}" "${value2% с исходным Host.}"; return;;

    'Не удалось установить безопасный offline rollback helper.') printf 'Failed to install the safe offline rollback helper.'; return;;
    'Обнаружена установка TWebProxy Manager v0.1.'*) printf 'TWebProxy Manager v0.1 was detected. Before v0.2, create a backup and remove or migrate the old single-instance installation; v0.2 intentionally does not overwrite it automatically.'; return;;
    'Upstream max_profiles по текущему конфигу: 32.') printf 'The current configuration has an upstream max_profiles limit of 32.'; return;;
    'Served cert: MISMATCH — Nginx может отдавать старый/другой сертификат') printf 'Served certificate: MISMATCH — Nginx may be serving an old or different certificate.'; return;;
    'Served cert: MISMATCH — Nginx отдаёт не указанный custom certificate') printf 'Served certificate: MISMATCH — Nginx is not serving the configured custom certificate.'; return;;
    'FULL snapshot содержит WEB/MTProxy secrets.'*) printf 'The FULL snapshot contains WEB/MTProxy secrets. TLS/SSH private keys and root/sudo credentials are not collected.'; return;;
    'FULL TEST REPORT содержит WEB/MTProxy secrets.'*) printf 'The FULL TEST REPORT contains WEB/MTProxy secrets. Private TLS/SSH keys and root/sudo credentials are not included.'; return;;
    'Upstream test suite tproxy-server не прошёл; update отменён до замены binary.') printf 'The upstream tproxy-server test suite failed; the update was canceled before replacing the binary.'; return;;
    'Не удалось собрать candidate tproxy-server; update отменён.') printf 'Failed to build the candidate tproxy-server; the update was canceled.'; return;;
    'Новая версия не проходит config check для '*) printf 'The new version fails the configuration check for %s' "${text#Новая версия не проходит config check для }"; return;;
    'Новый relay не прошёл health-check. Откатываю binary.') printf 'The new relay failed its health check. Rolling back the binary.'; return;;
    'Update откатан.') printf 'The update was rolled back.'; return;;
    'Relay обновлён до '*) printf 'Relay updated to %s' "${text#Relay обновлён до }"; return;;
    Сначала\ удали\ все\ hostname\ через\ *) printf "Delete all hostnames with 'twebproxy delete' first."; return;;
  esac

  # Already-English technical output is preserved verbatim. Unknown Cyrillic
  # cannot leak into the English UI and is represented losslessly for support;
  # acceptance tests ensure normal reachable flows never take this branch.
  if ! ui_contains_cyrillic "$text"; then
    printf '%s' "$text"
  else
    printf 'UNTRANSLATED_MESSAGE_UTF8_HEX=%s' "$(printf '%s' "$text" | ui_untranslated_hex)"
  fi
}

ui_language_valid() { [[ "${1:-}" == en || "${1:-}" == ru ]]; }

ui_language_load() {
  local configured="${TWEBPROXY_UI_LANGUAGE:-}" saved=""
  if ui_language_valid "$configured"; then UI_LANGUAGE="$configured"; return 0; fi
  if [[ -f "$LANGUAGE_FILE" && ! -L "$LANGUAGE_FILE" ]]; then
    IFS= read -r saved < "$LANGUAGE_FILE" || true
    if ui_language_valid "$saved"; then UI_LANGUAGE="$saved"; return 0; fi
  fi
  # Compatibility migration: pre-FixUI installs retain Russian and never block.
  UI_LANGUAGE=ru
}

ui_language_store() {
  local value="$1" parent tmp
  ui_language_valid "$value" || return 1
  parent="$(dirname "$LANGUAGE_FILE")"
  [[ ! -L "$LANGUAGE_FILE" && ! -L "$parent" ]] || return 1
  install -d -o root -g root -m 0700 "$parent"
  tmp="$(mktemp "$parent/.ui-language.XXXXXX")" || return 1
  printf '%s\n' "$value" > "$tmp"
  chown root:root "$tmp"; chmod 0600 "$tmp"
  mv -fT "$tmp" "$LANGUAGE_FILE"
  UI_LANGUAGE="$value"
}

ui_select_language() {
  local choice
  printf '%s\n\n[1] English\n[2] Русский\n\n' "$(ui_msg select_language)"
  while true; do
    if ! read -r -p "$(ui_msg choice): " choice && [[ -z "$choice" ]]; then ui_input_closed; return 130; fi
    case "$choice" in
      1) ui_language_store en && return 0;;
      2) ui_language_store ru && return 0;;
      *) warn "$(ui_msg enter_number)";;
    esac
  done
}

ui_language_ensure_interactive_install() {
  [[ -f "$LANGUAGE_FILE" && ! -L "$LANGUAGE_FILE" ]] && return 0
  [[ -t 0 && -t 1 ]] || return 0
  ui_select_language
}

C_RESET='\033[0m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_CYAN='\033[36m'; C_BOLD='\033[1m'; C_DIM='\033[2m'

log()  { printf "%b[i]%b %s\n" "$C_BLUE" "$C_RESET" "$(ui_localize_legacy "$*")"; }
ok()   { printf "%b[+]%b %s\n" "$C_GREEN" "$C_RESET" "$(ui_localize_legacy "$*")"; }
warn() { printf "%b[!]%b %s\n" "$C_YELLOW" "$C_RESET" "$(ui_localize_legacy "$*")"; }
die()  { printf "%b[x]%b %s\n" "$C_RED" "$C_RESET" "$(ui_localize_legacy "$*")" >&2; exit 1; }

strip_ansi_stream() {
  sed -u -E -e 's/\x1B\[[0-9;]*m//g'
}

redact_sensitive_stream() {
  # Shared redaction boundary for human, JSON, raw and transcript renderers.
  # Keep the expressions contextual so certificate fingerprints and commit IDs
  # are not mistaken for WEB/MTProxy secrets.
  sed -u -E \
    -e 's/(Secret:[[:space:]]*)(dd)?[0-9A-Fa-f]{32}/\1[REDACTED]/g' \
    -e 's/([?&]secret=)(dd)?[0-9A-Fa-f]{32}/\1[REDACTED]/g' \
    -e 's/(MTPROXY_SECRET=)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/(-S[[:space:]]+)(dd)?[0-9A-Fa-f]{32}/\1[REDACTED]/g' \
    -e 's/(SECRET=)(dd)?[0-9A-Fa-f]{32}/\1[REDACTED]/g' \
    -e 's/("secret"[[:space:]]*:[[:space:]]*")(dd)?[0-9A-Fa-f]{32}(")/\1[REDACTED]\3/g' \
    -e 's#([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]:]+:[^/@[:space:]]*@#\1[REDACTED]@#g' \
    -e '/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/,/-----END [A-Z0-9 ]*PRIVATE KEY-----/c [REDACTED PRIVATE KEY]'
}

sanitize_log_stream() {
  # A separate --full report can include WEB/MTProxy secrets when they are actually useful.
  strip_ansi_stream | redact_sensitive_stream
}

redact_sensitive_value() {
  printf '%s' "$1" | redact_sensitive_stream
}

disable_colors() {
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_BOLD=''; C_DIM=''
}

enable_colors() {
  C_RESET='\033[0m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'
  C_BLUE='\033[34m'; C_CYAN='\033[36m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
}

# Shared read-only core. Collectors populate typed records and never print.
# Renderers are the only functions that turn records into human/JSON/raw output.
TCORE_SCHEMA_VERSION="twebproxy.output.v1"
TCORE_COMMAND=""
TCORE_SCOPE=""
TCORE_HOST=""
TCORE_TLS_MODE=""
TCORE_GENERATED_AT=""
TCORE_OVERALL="UNKNOWN"
TCORE_DATA_JSON='{}'
declare -a TCORE_IDS=()
declare -a TCORE_STATUSES=()
declare -a TCORE_SEVERITIES=()
declare -a TCORE_SCOPES=()
declare -a TCORE_SOURCES=()
declare -a TCORE_OBSERVED=()
declare -a TCORE_EXPECTED=()
declare -a TCORE_MESSAGES=()
declare -a TCORE_HUMAN_LEVELS=()
declare -a TCORE_HUMAN_TEXTS=()
declare -a TCORE_EVIDENCE=()

tcore_reset() {
  TCORE_COMMAND="$1"
  TCORE_SCOPE="${2:-global}"
  TCORE_HOST=""
  TCORE_TLS_MODE=""
  TCORE_GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  TCORE_OVERALL="UNKNOWN"
  TCORE_DATA_JSON='{}'
  TCORE_IDS=(); TCORE_STATUSES=(); TCORE_SEVERITIES=(); TCORE_SCOPES=()
  TCORE_SOURCES=(); TCORE_OBSERVED=(); TCORE_EXPECTED=(); TCORE_MESSAGES=()
  TCORE_HUMAN_LEVELS=(); TCORE_HUMAN_TEXTS=(); TCORE_EVIDENCE=()
}

tcore_add_check() {
  local id="$1" status="$2" severity="$3" scope="$4" source="$5"
  local observed="$6" expected="$7" message="$8" human_level="${9:-none}"
  local human_text="${10:-}" evidence="${11:-}"
  case "$status" in OK|WARNING|ERROR|DISABLED|UNKNOWN) ;; *) die "Invalid typed status: $status";; esac
  case "$severity" in info|warning|critical) ;; *) die "Invalid typed severity: $severity";; esac
  TCORE_IDS+=("$id")
  TCORE_STATUSES+=("$status")
  TCORE_SEVERITIES+=("$severity")
  TCORE_SCOPES+=("$scope")
  TCORE_SOURCES+=("$source")
  TCORE_OBSERVED+=("$(redact_sensitive_value "$observed")")
  TCORE_EXPECTED+=("$(redact_sensitive_value "$expected")")
  TCORE_MESSAGES+=("$(redact_sensitive_value "$message")")
  TCORE_HUMAN_LEVELS+=("$human_level")
  TCORE_HUMAN_TEXTS+=("$(redact_sensitive_value "$human_text")")
  TCORE_EVIDENCE+=("$(redact_sensitive_value "$evidence")")
}

tcore_finalize() {
  local status has_ok=0 has_unknown=0 has_warning=0
  TCORE_OVERALL="OK"
  for status in "${TCORE_STATUSES[@]}"; do
    case "$status" in
      ERROR) TCORE_OVERALL="ERROR"; return 0;;
      WARNING) has_warning=1;;
      UNKNOWN) has_unknown=1;;
      OK) has_ok=1;;
    esac
  done
  if (( has_warning )); then TCORE_OVERALL="WARNING"
  elif (( has_unknown && ! has_ok )); then TCORE_OVERALL="UNKNOWN"
  elif (( has_unknown )); then TCORE_OVERALL="WARNING"
  fi
}

tcore_error_count() {
  local status count=0
  for status in "${TCORE_STATUSES[@]}"; do [[ "$status" == ERROR ]] && count=$((count+1)); done
  printf '%s' "$count"
}

tcore_warning_count() {
  local status count=0
  for status in "${TCORE_STATUSES[@]}"; do [[ "$status" == WARNING ]] && count=$((count+1)); done
  printf '%s' "$count"
}

tcore_render_json() {
  command -v jq >/dev/null 2>&1 || die "jq нужен для --json output."
  local checks='[]' warnings='[]' item i
  for i in "${!TCORE_IDS[@]}"; do
    item="$(jq -cn \
      --arg id "${TCORE_IDS[$i]}" \
      --arg status "${TCORE_STATUSES[$i]}" \
      --arg severity "${TCORE_SEVERITIES[$i]}" \
      --arg scope "${TCORE_SCOPES[$i]}" \
      --arg source "${TCORE_SOURCES[$i]}" \
      --arg observed "${TCORE_OBSERVED[$i]}" \
      --arg expected "${TCORE_EXPECTED[$i]}" \
      --arg message "${TCORE_MESSAGES[$i]}" \
      '{id:$id,status:$status,severity:$severity,scope:$scope,source:$source,observed:$observed,expected:$expected,message:$message}')"
    checks="$(jq -cn --argjson checks "$checks" --argjson item "$item" '$checks + [$item]')"
    if [[ "${TCORE_STATUSES[$i]}" == WARNING || "${TCORE_STATUSES[$i]}" == UNKNOWN ]]; then
      warnings="$(jq -cn --argjson warnings "$warnings" --arg id "${TCORE_IDS[$i]}" \
        --arg scope "${TCORE_SCOPES[$i]}" --arg status "${TCORE_STATUSES[$i]}" \
        --arg message "${TCORE_MESSAGES[$i]}" \
        '$warnings + [{id:$id,scope:$scope,status:$status,message:$message}]')"
    fi
  done
  jq -cn \
    --arg schema_version "$TCORE_SCHEMA_VERSION" \
    --arg command "$TCORE_COMMAND" \
    --arg generated_at "$TCORE_GENERATED_AT" \
    --arg overall "$TCORE_OVERALL" \
    --arg hostname "$TCORE_HOST" \
    --arg tls_mode "$TCORE_TLS_MODE" \
    --arg manager_version "$MANAGER_VERSION" \
    --argjson checks "$checks" \
    --argjson warnings "$warnings" \
    --argjson extra_data "$TCORE_DATA_JSON" \
    '{schema_version:$schema_version,command:$command,generated_at:$generated_at,overall:$overall,data:({hostname:$hostname,tls_mode:$tls_mode,manager_version:$manager_version} + $extra_data),checks:$checks,warnings:$warnings}'
}

tcore_raw_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//$'\t'/\\t}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}

tcore_render_raw() {
  local i
  printf 'twebproxy.raw.v1\tcommand=%s\tscope=%s\toverall=%s\n' \
    "$(tcore_raw_escape "$TCORE_COMMAND")" "$(tcore_raw_escape "$TCORE_SCOPE")" "$TCORE_OVERALL"
  printf 'id\tstatus\tseverity\tscope\tsource\tobserved\texpected\tmessage\n'
  for i in "${!TCORE_IDS[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(tcore_raw_escape "${TCORE_IDS[$i]}")" \
      "${TCORE_STATUSES[$i]}" \
      "${TCORE_SEVERITIES[$i]}" \
      "$(tcore_raw_escape "${TCORE_SCOPES[$i]}")" \
      "$(tcore_raw_escape "${TCORE_SOURCES[$i]}")" \
      "$(tcore_raw_escape "${TCORE_OBSERVED[$i]}")" \
      "$(tcore_raw_escape "${TCORE_EXPECTED[$i]}")" \
      "$(tcore_raw_escape "${TCORE_MESSAGES[$i]}")"
  done
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
  # 130: a prompt was cancelled (EOF) or the command was interrupted; the reason
  # is already on screen, nothing failed.
  [[ "$rc" != 130 ]] || exit 130
  if [[ "$UI_LANGUAGE" == en ]]; then
    printf "\n%b[x]%b Error at line %s. Command: %s (code %s)\n" "$C_RED" "$C_RESET" "$line" "$command" "$rc" >&2
    [[ -n "${CURRENT_LOG:-}" ]] && printf "%b[i]%b Full invocation log: %s\n" "$C_BLUE" "$C_RESET" "$CURRENT_LOG" >&2
  else
    printf "\n%b[x]%b Ошибка на строке %s. Команда: %s (код %s)\n" "$C_RED" "$C_RESET" "$line" "$command" "$rc" >&2
    [[ -n "${CURRENT_LOG:-}" ]] && printf "%b[i]%b Полный лог запуска: %s\n" "$C_BLUE" "$C_RESET" "$CURRENT_LOG" >&2
  fi

  # Best-effort failure snapshot. Never let diagnostic collection hide the original error.
  if [[ ${EUID:-$(id -u)} -eq 0 && -n "${LOG_RUNTIME_DIR:-}" && "${TWEBPROXY_ERROR_SNAPSHOT:-0}" != "1" ]]; then
    export TWEBPROXY_ERROR_SNAPSHOT=1
    trap - ERR
    set +e
    snap="$(collect_runtime_snapshot safe failure 2>/dev/null)"
    if [[ -n "$snap" ]]; then
      [[ "$UI_LANGUAGE" == en ]] && printf "%b[i]%b Automatic post-error snapshot: %s\n" "$C_BLUE" "$C_RESET" "$snap" >&2 \
        || printf "%b[i]%b Автоснимок состояния после ошибки: %s\n" "$C_BLUE" "$C_RESET" "$snap" >&2
    fi
    set -e
    trap 'rc=$?; on_error "$rc" "$LINENO" "$BASH_COMMAND"' ERR
  fi
  # Returning a failure from ERR through nested function unwinding corrupts
  # Bash 5.2's variable-context stack (pop_var_context). This handler is fatal.
  exit "$rc"
}

trap 'rc=$?; on_error "$rc" "$LINENO" "$BASH_COMMAND"' ERR

banner() {
  printf "%bTWebProxy Manager v%s%b\n" "$C_BOLD" "$MANAGER_RELEASE_VERSION" "$C_RESET"
  printf '%s\n' "$(ui_msg product_subtitle)"
}

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запусти от root: sudo $0"; }
need_systemd() { command -v systemctl >/dev/null 2>&1 || die "Нужен systemd."; }

# End of input (Ctrl-D, closed or exhausted stdin) never confirms or selects
# anything: a yes/no prompt answers NO, a value or selection prompt cancels the
# command with status 130 (on_error exits quietly on it), a menu goes back. A
# last value/selection line without a newline still counts as an answer;
# security/destructive confirmations require a complete line.
ui_input_closed() { printf '\n' >&2; warn "Ввод закрыт (EOF); операция отменена." >&2; }

# A menu number: 1-4 decimal digits (leading zeros are decimal, never octal) in $2..$3.
ui_number_in_range() { # $1=input $2=min $3=max -> the number
  [[ "$1" =~ ^[0-9]{1,4}$ ]] || return 1
  local n=$((10#$1))
  (( n >= $2 && n <= $3 )) || return 1
  printf '%s' "$n"
}

ask() {
  local prompt="$1" default="${2:-}" value=""
  prompt="$(ui_localize_legacy "$prompt")"
  if [[ -n "$default" ]]; then
    if ! read -r -p "$prompt [$default]: " value && [[ -z "$value" ]]; then ui_input_closed; return 130; fi
    printf '%s' "${value:-$default}"
  else
    if ! read -r -p "$prompt: " value && [[ -z "$value" ]]; then ui_input_closed; return 130; fi
    printf '%s' "$value"
  fi
}

yesno() {
  local prompt="$1" default="${2:-y}" reply="" hint="[y/N]"
  prompt="$(ui_localize_legacy "$prompt")"
  [[ "$default" == "y" ]] && hint="[Y/n]"
  if [[ "$UI_LANGUAGE" == ru ]]; then
    hint="[д/Н]"; [[ "$default" != y ]] || hint="[Д/н]"
  fi
  if ! read -r -p "$prompt $hint: " reply; then
    printf '\n' >&2; warn "Ввод закрыт (EOF); ответ: нет." >&2; return 1
  fi
  [[ -n "$reply" || "$default" != y ]] || return 0
  case "$reply" in y|Y|yes|YES|Yes|д|Д|да|Да|ДА) return 0;; *) return 1;; esac
}

choose() {
  local prompt="$1"; shift
  local options=("$@") i choice n
  echo "$(ui_localize_legacy "$prompt")" >&2
  for i in "${!options[@]}"; do printf "  [%d] %s\n" "$((i+1))" "$(ui_localize_legacy "${options[$i]}")" >&2; done
  while true; do
    if ! read -r -p "> " choice && [[ -z "$choice" ]]; then ui_input_closed; return 130; fi
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "$(ui_msg enter_number)" >&2; continue; }
    n="$(ui_number_in_range "$choice" 1 "${#options[@]}")" || { warn "$(ui_msg unknown_option)" >&2; continue; }
    printf '%s' "$n"
    return 0
  done
}

menu_choose() {
  local prompt="$1" zero="$2"; shift 2
  local options=("$@") i choice n
  printf '%s\n' "$prompt" >&2
  for i in "${!options[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${options[$i]}" >&2; done
  printf '  [0] %s\n' "$zero" >&2
  while true; do
    if ! read -r -p "> " choice && [[ -z "$choice" ]]; then printf '\n' >&2; printf '0'; return 0; fi
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "$(ui_msg enter_number)" >&2; continue; }
    n="$(ui_number_in_range "$choice" 0 "${#options[@]}")" || { warn "$(ui_msg unknown_option)" >&2; continue; }
    printf '%s' "$n"; return 0
  done
}

tui_preset_choose() {
  local selected
  selected="$(menu_choose "$1" "$(ui_msg back)" "${@:2}")"
  [[ "$selected" != 0 ]] || return 130
  printf '%s' "$selected"
}

pause() { read -r -p "$(ui_msg press_enter)" _ || true; }

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
is_valid_carrier_mode() { [[ "$1" =~ ^(https|https-lanes|websocket|websocket-lanes)$ ]]; }

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

# ---- Stage C1: operation-local profile/instance state integrity ----
# Authoritative state: instances/<host>/instance.env and profiles.d/<p>.env.
# Derived from it: backends/<host>--<p>.env, profiles.json, config.json and the
# backend firewall. Every file is replaced through a same-directory rename,
# never rewritten in place. The rename of the profile record is the commit
# point of a profile mutation; derived files are then regenerated, so an
# interrupted operation is converged by the next mutation of that instance or
# by `repair`. No multi-file atomicity or power-loss durability is claimed.

# Records are read in a subshell and only their known fields are assigned:
# one record can neither inherit values from another nor redefine any other
# manager variable. A trailing "." keeps empty last fields countable.
state_read_record() { # $1=file, rest=field names -> one value per line, then "."
  local f="$1"; shift
  ( unset "$@"
    # shellcheck disable=SC1090
    source "$f" >/dev/null 2>&1 || exit 1
    for v in "$@"; do printf '%s\n' "${!v-}"; done
    printf '.\n' )
}

load_instance() {
  local host="$1" f out; local -a v
  f="$(instance_env "$host")"
  [[ -f "$f" ]] || die "Инстанс не найден: $host"
  out="$(state_read_record "$f" HOSTNAME RELAY_PORT ADMIN_PORT TLS_MODE SITE_MODE SITE_UPSTREAM \
    SOURCE_SITE_DIR ACME_EMAIL NGINX_CERT NGINX_KEY CREATED_AT)" || die "Повреждённая запись инстанса: $f"
  mapfile -t v <<< "$out"
  (( ${#v[@]} == 12 )) && [[ "${v[11]}" == . ]] || die "Повреждённая запись инстанса: $f"
  HOSTNAME="${v[0]}"; RELAY_PORT="${v[1]}"; ADMIN_PORT="${v[2]}"; TLS_MODE="${v[3]}"; SITE_MODE="${v[4]}"
  SITE_UPSTREAM="${v[5]}"; SOURCE_SITE_DIR="${v[6]}"; ACME_EMAIL="${v[7]}"; NGINX_CERT="${v[8]}"
  NGINX_KEY="${v[9]}"; CREATED_AT="${v[10]}"
}

# The record's CREATED_AT is kept in PROFILE_CREATED_AT, apart from the
# instance's CREATED_AT, so saving a profile preserves its own creation time.
load_profile() {
  local host="$1" profile="$2" f out; local -a v
  f="$(profile_env "$host" "$profile")"
  [[ -f "$f" ]] || die "Профиль $profile не найден у $host"
  out="$(state_read_record "$f" PROFILE_NAME SECRET CARRIER_MODE BACKEND_PORT STATS_PORT WORKERS \
    MAX_CONNECTIONS CREATED_AT)" || die "Повреждённая запись профиля: $f"
  mapfile -t v <<< "$out"
  (( ${#v[@]} == 9 )) && [[ "${v[8]}" == . ]] || die "Повреждённая запись профиля: $f"
  PROFILE_NAME="${v[0]}"; SECRET="${v[1]}"; CARRIER_MODE="${v[2]}"; BACKEND_PORT="${v[3]}"
  STATS_PORT="${v[4]}"; WORKERS="${v[5]}"; MAX_CONNECTIONS="${v[6]}"; PROFILE_CREATED_AT="${v[7]}"
}

# The loaded profile globals form a complete record named $1.
profile_record_valid() {
  [[ "$PROFILE_NAME" == "$1" ]] && is_valid_profile_name "$PROFILE_NAME" && is_valid_secret "$SECRET" &&
    is_valid_carrier_mode "$CARRIER_MODE" && is_valid_port "$BACKEND_PORT" && is_valid_port "$STATS_PORT" &&
    [[ "$BACKEND_PORT" != "$STATS_PORT" && "$WORKERS" =~ ^[1-9][0-9]*$ &&
       "$MAX_CONNECTIONS" =~ ^[1-9][0-9]*$ ]] && (( WORKERS <= 256 ))
}

# Mutations act only on a validated, existing hostname/profile, never on a path
# assembled from unchecked input, and only on a record that names itself.
require_instance() {
  is_valid_hostname "$1" || die "Нужен lowercase ASCII/ACE hostname вида proxy.example.com"
  instance_exists "$1" || die "Нет $1"
}

require_profile() { # $1=host $2=profile -> profile globals loaded and verified
  require_profile_file "$1" "$2"
  load_profile "$1" "$2"
  profile_record_valid "$2" || die "Повреждённая запись профиля: $(profile_env "$1" "$2")"
}

# Deletion targets only the path of a validated name, so a damaged record can
# still be removed (which is how an instance with one is healed).
require_profile_file() { # $1=host $2=profile
  local f
  is_valid_profile_name "$2" || die "Имя: a-z, 0-9, _ и -, максимум 32 символа."
  f="$(profile_env "$1" "$2")"
  [[ ! -L "$f" ]] || die "Небезопасный файл состояния: $f"
  [[ -f "$f" ]] || die "Профиль $2 не найден у $1"
}

# Replaces $1 (mode $2) with the stdout of "${@:3}": a same-directory temporary
# file owned by root, then rename. A failing producer, an empty result, a
# symlinked target/directory or any failed step leaves the old file untouched.
state_write_file() {
  local target="$1" mode="$2" dir tmp
  shift 2
  dir="$(dirname -- "$target")"
  [[ -d "$dir" && ! -L "$dir" ]] || { warn "Небезопасный каталог состояния: $dir" >&2; return 1; }
  [[ ! -L "$target" && ( ! -e "$target" || -f "$target" ) ]] ||
    { warn "Небезопасный файл состояния: $target" >&2; return 1; }
  tmp="$(mktemp "$dir/.${target##*/}.XXXXXX")" || return 1
  if "$@" > "$tmp" && [[ -s "$tmp" ]] && chown root:root -- "$tmp" && chmod "$mode" -- "$tmp" &&
      mv -fT -- "$tmp" "$target"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

render_instance_record() {
  printf 'HOSTNAME=%q\nRELAY_PORT=%q\nADMIN_PORT=%q\nTLS_MODE=%q\nSITE_MODE=%q\nSITE_UPSTREAM=%q\nSOURCE_SITE_DIR=%q\nACME_EMAIL=%q\nNGINX_CERT=%q\nNGINX_KEY=%q\nCREATED_AT=%q\n' \
    "$HOSTNAME" "$RELAY_PORT" "$ADMIN_PORT" "$TLS_MODE" "$SITE_MODE" "${SITE_UPSTREAM:-}" \
    "${SOURCE_SITE_DIR:-}" "${ACME_EMAIL:-}" "${NGINX_CERT:-}" "${NGINX_KEY:-}" "${CREATED_AT:-$(date -Is)}"
}

save_instance() {
  local host="$1" d; d="$(instance_dir "$host")"
  [[ "$HOSTNAME" == "$host" ]] || die "Повреждённая запись инстанса: $(instance_env "$host")"
  install -d -m 0700 "$d" "$(profile_dir "$host")" || die "Не удалось записать состояние: $d"
  state_write_file "$(instance_env "$host")" 0600 render_instance_record ||
    die "Не удалось записать состояние: $(instance_env "$host")"
}

render_profile_record() {
  printf 'PROFILE_NAME=%q\nSECRET=%q\nCARRIER_MODE=%q\nBACKEND_PORT=%q\nSTATS_PORT=%q\nWORKERS=%q\nMAX_CONNECTIONS=%q\nCREATED_AT=%q\n' \
    "$PROFILE_NAME" "$SECRET" "$CARRIER_MODE" "$BACKEND_PORT" "$STATS_PORT" "$WORKERS" \
    "$MAX_CONNECTIONS" "${PROFILE_CREATED_AT:-$(date -Is)}"
}

# Writes only the authoritative record held in the profile globals; backend
# env files and profiles.json are derived by instance_derive_state.
save_profile() {
  local host="$1" profile="$2" f; f="$(profile_env "$host" "$profile")"
  profile_record_valid "$profile" || die "Повреждённая запись профиля: $f"
  install -d -m 0700 "$(profile_dir "$host")" "$BACKENDS_DIR" || return 1
  state_write_file "$f" 0600 render_profile_record
}

# Backend env of one profile, derived from its record on disk (subshell: the
# caller's profile globals stay untouched).
render_backend_env() ( # $1=host $2=profile
  load_profile "$1" "$2"
  profile_record_valid "$2" || exit 1
  backend_secret="$SECRET"
  [[ "$backend_secret" == dd* && ${#backend_secret} -eq 34 ]] && backend_secret="${backend_secret:2}"
  printf 'MTPROXY_SECRET=%q\nMTPROXY_CLIENT_PORT=%q\nMTPROXY_STATS_PORT=%q\nMTPROXY_WORKERS=%q\nMTPROXY_MAX_CONNECTIONS=%q\n' \
    "$backend_secret" "$BACKEND_PORT" "$STATS_PORT" "$WORKERS" "$MAX_CONNECTIONS"
)

# Regenerates every backend env of $1 and its profiles.json from the profile
# records; unchanged files are not rewritten. BACKEND_PORTS_CHANGED=1 tells the
# caller that a backend env appeared or changed ports (firewall rebuild needed).
instance_derive_state() {
  local host="$1" p bfile content
  BACKEND_PORTS_CHANGED=0
  if bridge_managed "$host"; then rebuild_profiles_json "$host"; return; fi
  while read -r p; do
    [[ -n "$p" ]] || continue
    bfile="$(backend_env "$host" "$p")"
    content="$(render_backend_env "$host" "$p")" || return 1
    [[ -f "$bfile" && "$(cat -- "$bfile")" == "$content" ]] && continue
    if [[ ! -f "$bfile" ]] || [[ "$(grep -E '^MTPROXY_(CLIENT|STATS)_PORT=' "$bfile")" != \
        "$(grep -E '^MTPROXY_(CLIENT|STATS)_PORT=' <<< "$content")" ]]; then
      BACKEND_PORTS_CHANGED=1
    fi
    state_write_file "$bfile" 0600 printf '%s\n' "$content" || return 1
  done < <(list_profiles_array "$host")
  rebuild_profiles_json "$host"
}

# Commits the profile record held in the globals, derives, validates. Any
# failure before the relay accepted the state restores the previous record
# ($3, empty = none) and fails; runtime (systemd) changes are the caller's.
profile_state_commit() { # $1=host $2=profile $3=previous record
  if save_profile "$1" "$2" && instance_derive_state "$1" && validate_instance "$1"; then
    return 0
  fi
  profile_state_restore "$1" "$2" "$3"
  die "Не удалось применить новое состояние $1; прежнее состояние восстановлено."
}

# Removes a profile record and its backend env, derives, validates. On failure
# the previous record is restored and the caller (which stopped the backend)
# gets a non-zero result to bring the runtime back.
profile_state_remove() { # $1=host $2=profile $3=previous record
  if rm -f -- "$(profile_env "$1" "$2")" "$(backend_env "$1" "$2")" &&
      instance_derive_state "$1" && validate_instance "$1"; then
    return 0
  fi
  profile_state_restore "$1" "$2" "$3"
  return 1
}

profile_state_restore() { # $1=host $2=profile $3=previous record ("" = remove)
  local f; f="$(profile_env "$1" "$2")"
  if [[ -n "$3" ]]; then
    state_write_file "$f" 0600 printf '%s\n' "$3"
  else
    rm -f -- "$f" "$(backend_env "$1" "$2")"
  fi || die "ОТКАТ НЕ УДАЛСЯ: проверь состояние $1 и выполни 'twebproxy repair $1'."
  if (( $(count_profiles "$1") == 0 )); then
    rm -f -- "$(profiles_json "$1")"
  else
    instance_derive_state "$1" || die "ОТКАТ НЕ УДАЛСЯ: проверь состояние $1 и выполни 'twebproxy repair $1'."
  fi
}

# Narrow flock locks under $BASE_DIR/.locks: instance-<host> serializes the
# mutations of one instance; ports serializes port choice until persistence;
# relay serializes relay binary replacement with relay restarts/stops;
# relay-update serializes whole relay updates (upstream checkout and build);
# frontend serializes changes of the shared Caddy/Nginx configuration.
# Order: instance -> ports -> (DPI lock, backend firewall helper); the port
# lock is a leaf. instance -> relay and relay-update -> relay; ports and relay
# are never held together. instance -> frontend; frontend is a leaf. Closing
# the descriptor or process exit (die) releases them.
STATE_LOCK_WAIT_SECONDS="${TWEBPROXY_STATE_LOCK_WAIT:-120}"
INSTANCE_LOCK_FD=""; INSTANCE_LOCK_HOST=""; INSTANCE_LOCK_DEPTH=0
PORT_LOCK_FD=""; PORT_LOCK_DEPTH=0
RELAY_LOCK_FD=""; RELAY_LOCK_DEPTH=0
FRONTEND_LOCK_FD=""; FRONTEND_LOCK_DEPTH=0
# Bounded relay readiness wait (seconds, one /readyz probe per second).
RELAY_READY_WAIT_SECONDS="${TWEBPROXY_RELAY_READY_WAIT:-25}"
RELAY_UPDATE_INTERRUPTED=0

state_lock_path() { # $1=name -> STATE_LOCK_PATH (re-derived from the current BASE_DIR)
  local dir="$BASE_DIR/.locks"
  [[ ! -L "$dir" ]] || return 1
  install -d -o root -g root -m 0700 "$dir" || return 1
  STATE_LOCK_PATH="$dir/$1.lock"
  [[ ! -L "$STATE_LOCK_PATH" && ( ! -e "$STATE_LOCK_PATH" || -f "$STATE_LOCK_PATH" ) ]] || return 1
  : >> "$STATE_LOCK_PATH" && chmod 0600 "$STATE_LOCK_PATH"
}

instance_lock_acquire() { # $1=validated hostname
  if (( INSTANCE_LOCK_DEPTH > 0 )); then
    [[ "$INSTANCE_LOCK_HOST" == "$1" ]] || return 1
    INSTANCE_LOCK_DEPTH=$((INSTANCE_LOCK_DEPTH + 1)); return 0
  fi
  (( PORT_LOCK_DEPTH == 0 )) || return 1
  state_lock_path "instance-$1" || return 1
  exec {INSTANCE_LOCK_FD}>>"$STATE_LOCK_PATH" || return 1
  if ! flock -w "$STATE_LOCK_WAIT_SECONDS" "$INSTANCE_LOCK_FD"; then
    exec {INSTANCE_LOCK_FD}>&-; return 1
  fi
  INSTANCE_LOCK_HOST="$1"; INSTANCE_LOCK_DEPTH=1
}

instance_lock_release() {
  (( INSTANCE_LOCK_DEPTH > 0 )) || return 0
  INSTANCE_LOCK_DEPTH=$((INSTANCE_LOCK_DEPTH - 1))
  (( INSTANCE_LOCK_DEPTH > 0 )) || { exec {INSTANCE_LOCK_FD}>&-; INSTANCE_LOCK_HOST=""; }
}

port_lock_acquire() {
  if (( PORT_LOCK_DEPTH > 0 )); then PORT_LOCK_DEPTH=$((PORT_LOCK_DEPTH + 1)); return 0; fi
  state_lock_path ports || return 1
  exec {PORT_LOCK_FD}>>"$STATE_LOCK_PATH" || return 1
  if ! flock -w "$STATE_LOCK_WAIT_SECONDS" "$PORT_LOCK_FD"; then
    exec {PORT_LOCK_FD}>&-; return 1
  fi
  PORT_LOCK_DEPTH=1
}

port_lock_release() {
  (( PORT_LOCK_DEPTH > 0 )) || return 0
  PORT_LOCK_DEPTH=$((PORT_LOCK_DEPTH - 1))
  (( PORT_LOCK_DEPTH > 0 )) || exec {PORT_LOCK_FD}>&-
}

relay_lock_acquire() {
  if (( RELAY_LOCK_DEPTH > 0 )); then RELAY_LOCK_DEPTH=$((RELAY_LOCK_DEPTH + 1)); return 0; fi
  (( PORT_LOCK_DEPTH == 0 )) || return 1
  state_lock_path relay || return 1
  exec {RELAY_LOCK_FD}>>"$STATE_LOCK_PATH" || return 1
  if ! flock -w "$STATE_LOCK_WAIT_SECONDS" "$RELAY_LOCK_FD"; then
    exec {RELAY_LOCK_FD}>&-; return 1
  fi
  RELAY_LOCK_DEPTH=1
}

relay_lock_release() {
  (( RELAY_LOCK_DEPTH > 0 )) || return 0
  RELAY_LOCK_DEPTH=$((RELAY_LOCK_DEPTH - 1))
  (( RELAY_LOCK_DEPTH > 0 )) || exec {RELAY_LOCK_FD}>&-
}

frontend_lock_acquire() {
  if (( FRONTEND_LOCK_DEPTH > 0 )); then FRONTEND_LOCK_DEPTH=$((FRONTEND_LOCK_DEPTH + 1)); return 0; fi
  state_lock_path frontend || return 1
  exec {FRONTEND_LOCK_FD}>>"$STATE_LOCK_PATH" || return 1
  if ! flock -w "$STATE_LOCK_WAIT_SECONDS" "$FRONTEND_LOCK_FD"; then
    exec {FRONTEND_LOCK_FD}>&-; return 1
  fi
  FRONTEND_LOCK_DEPTH=1
}

frontend_lock_release() {
  (( FRONTEND_LOCK_DEPTH > 0 )) || return 0
  FRONTEND_LOCK_DEPTH=$((FRONTEND_LOCK_DEPTH - 1))
  (( FRONTEND_LOCK_DEPTH > 0 )) || exec {FRONTEND_LOCK_FD}>&-
}

# ---- Stage X-DPI: optional, IPv4-address-scoped compatibility subsystem ----

dpi_mode_valid() {
  case "${1:-}" in
    stock|window1152|mss88|nfqws|window1152_nfqws|mss88_nfqws) return 0;;
    *) return 1;;
  esac
}

dpi_mode_uses_nfqws() { [[ "${1:-}" == nfqws || "${1:-}" == *_nfqws ]]; }
dpi_mode_uses_window() { [[ "${1:-}" == window1152 || "${1:-}" == window1152_nfqws ]]; }
dpi_mode_uses_mss() { [[ "${1:-}" == mss88 || "${1:-}" == mss88_nfqws ]]; }

dpi_ipv4_valid() {
  local ip="${1:-}" a b c d canonical
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 )) || return 1
  canonical="$((10#$a)).$((10#$b)).$((10#$c)).$((10#$d))"
  [[ "$ip" == "$canonical" ]] || return 1
  (( 10#$a != 0 && 10#$a != 127 && 10#$a < 224 )) || return 1
  [[ "$ip" != 10.* && "$ip" != 192.168.* && "$ip" != 169.254.* && "$ip" != 255.255.255.255 ]] || return 1
  ! (( 10#$a == 172 && 10#$b >= 16 && 10#$b <= 31 )) || return 1
  ! (( 10#$a == 100 && 10#$b >= 64 && 10#$b <= 127 ))
}

dpi_resolve_ipv4() {
  local host="$1" ip
  local -a addresses=()
  while read -r ip; do
    dpi_ipv4_valid "$ip" || continue
    addresses+=("$ip")
  done < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
  ((${#addresses[@]} == 1)) || return 1
  printf '%s' "${addresses[0]}"
}

dpi_host_has_ipv6() { getent ahostsv6 "$1" 2>/dev/null | awk '{print $1}' | sort -u | grep -q ':'; }

# IPv4 addresses configured on this host, one per line. Returns non-zero when
# the set cannot be determined at all, which callers must treat as "unknown"
# rather than "none".
dpi_local_ipv4_addresses() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sed '/^$/d'
    return 0
  fi
  if command -v hostname >/dev/null 2>&1; then
    local out
    out="$(hostname -I 2>/dev/null || true)"
    [[ -n "$out" ]] || return 1
    printf '%s\n' $out
    return 0
  fi
  return 1
}

# DPI rules match `ip saddr <scope>` in the output hook, so the scope address has
# to be one this host actually sends from. Where the public IPv4 is supplied by
# external 1:1 NAT the guest never owns it and the rule cannot match, so this is
# a hard prerequisite rather than a hint.
#   0 = configured locally   1 = not configured locally   2 = cannot determine
dpi_scope_locally_configured() {
  local wanted="$1" addr found=1 listed=0
  while IFS= read -r addr; do
    [[ -n "$addr" ]] || continue
    listed=1
    [[ "$addr" == "$wanted" ]] && { found=0; break; }
  done < <(dpi_local_ipv4_addresses 2>/dev/null || true)
  (( listed )) || return 2
  return "$found"
}

dpi_hosts_for_ipv4() {
  local wanted="$1" host resolved
  while read -r host; do
    [[ -n "$host" ]] || continue
    resolved="$(dpi_resolve_ipv4 "$host" 2>/dev/null || true)"
    [[ "$resolved" == "$wanted" ]] && printf '%s\n' "$host"
  done < <(list_hosts_array)
  return 0
}

dpi_state_path() { printf '%s/%s.env' "${1:-$DPI_STATE_DIR}" "$2"; }

dpi_state_file_safe() {
  local file="$1" meta
  [[ -f "$file" && ! -L "$file" ]] || return 1
  meta="$(stat -c '%u:%g:%a' "$file" 2>/dev/null || true)"
  [[ "$meta" == 0:0:600 ]]
}

# Loads only the fixed non-executable key/value grammar written below. State is
# never sourced, so even a corrupted root-owned file cannot inject shell code.
dpi_load_scope_file() {
  local file="$1" key value seen_format=0 seen_ip=0 seen_mode=0
  DPI_SCOPE_FORMAT=""; DPI_SCOPE_IPV4=""; DPI_SCOPE_MODE=""; DPI_SCOPE_HOST=""
  DPI_SCOPE_CONFIRMED=""; DPI_SCOPE_UPDATED_AT=""
  dpi_state_file_safe "$file" || return 1
  while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
    case "$key" in
      FORMAT) DPI_SCOPE_FORMAT="$value"; seen_format=$((seen_format+1));;
      IPV4) DPI_SCOPE_IPV4="$value"; seen_ip=$((seen_ip+1));;
      MODE) DPI_SCOPE_MODE="$value"; seen_mode=$((seen_mode+1));;
      HOSTNAME) DPI_SCOPE_HOST="$value";;
      CONFIRMED_ADDRESS_SCOPE) DPI_SCOPE_CONFIRMED="$value";;
      UPDATED_AT) DPI_SCOPE_UPDATED_AT="$value";;
      '') ;;
      *) return 1;;
    esac
  done < "$file"
  (( seen_format == 1 && seen_ip == 1 && seen_mode == 1 )) || return 1
  [[ "$DPI_SCOPE_FORMAT" == "$DPI_STATE_FORMAT" ]] || return 1
  dpi_ipv4_valid "$DPI_SCOPE_IPV4" || return 1
  dpi_mode_valid "$DPI_SCOPE_MODE" && [[ "$DPI_SCOPE_MODE" != stock ]] || return 1
  [[ "$(basename "$file")" == "$DPI_SCOPE_IPV4.env" ]] || return 1
  [[ -z "$DPI_SCOPE_HOST" ]] || is_valid_hostname "$DPI_SCOPE_HOST" || return 1
  [[ "$DPI_SCOPE_CONFIRMED" == yes ]]
}

dpi_write_scope_state() {
  local dir="$1" ip="$2" mode="$3" host="$4" tmp target
  dpi_ipv4_valid "$ip" && dpi_mode_valid "$mode" && [[ "$mode" != stock ]] || return 1
  is_valid_hostname "$host" || return 1
  install -d -o root -g root -m 0700 "$dir" || return 1
  [[ ! -L "$dir" ]] || return 1
  target="$(dpi_state_path "$dir" "$ip")"
  [[ ! -e "$target" && ! -L "$target" ]] || dpi_state_file_safe "$target" || return 1
  tmp="$(mktemp "$dir/.scope.XXXXXX")" || return 1
  {
    printf 'FORMAT=%s\n' "$DPI_STATE_FORMAT"
    printf 'IPV4=%s\n' "$ip"
    printf 'MODE=%s\n' "$mode"
    printf 'HOSTNAME=%s\n' "$host"
    printf 'CONFIRMED_ADDRESS_SCOPE=yes\n'
    printf 'UPDATED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$tmp"
  chown root:root "$tmp" && chmod 0600 "$tmp" && mv -fT "$tmp" "$target"
}

dpi_render_rules() {
  local state_dir="$1" output="$2" file ip mode count=0 tmp
  tmp="$(mktemp "${output}.XXXXXX")" || return 1
  : > "$tmp"
  if [[ -d "$state_dir" ]]; then
    while IFS= read -r file; do
      dpi_load_scope_file "$file" || { rm -f "$tmp"; return 1; }
      count=$((count+1))
    done < <(find "$state_dir" -mindepth 1 -maxdepth 1 -print | sort)
  fi
  if (( count == 0 )); then
    mv -fT "$tmp" "$output"
    return 0
  fi
  cat > "$tmp" <<EOF
table ip $DPI_NFT_TABLE {
  chain output {
    type filter hook output priority mangle; policy accept;
EOF
  while IFS= read -r file; do
    dpi_load_scope_file "$file" || { rm -f "$tmp"; return 1; }
    ip="$DPI_SCOPE_IPV4"; mode="$DPI_SCOPE_MODE"
    if dpi_mode_uses_window "$mode"; then
      printf '    ip saddr %s tcp sport 443 tcp flags & (fin | syn | rst | ack) == (syn | ack) tcp window set 1152 counter comment "twebproxy:%s:window1152"\n' "$ip" "$ip" >> "$tmp"
    elif dpi_mode_uses_mss "$mode"; then
      printf '    ip saddr %s tcp sport 443 tcp flags & (fin | syn | rst | ack) == (syn | ack) tcp option maxseg size set 88 counter comment "twebproxy:%s:mss88"\n' "$ip" "$ip" >> "$tmp"
    fi
    if dpi_mode_uses_nfqws "$mode"; then
      # nftables rejects any statement after a terminal verdict, so the counter
      # is emitted before `queue`. `comment` is a rule attribute and stays last.
      printf '    ip saddr %s tcp sport 443 meta mark & %s == 0 ct reply packets 1-6 counter queue num %s bypass comment "twebproxy:%s:nfqws"\n' \
        "$ip" "$DPI_NFQWS_MARK" "$DPI_NFQUEUE_NUM" "$ip" >> "$tmp"
    fi
  done < <(find "$state_dir" -mindepth 1 -maxdepth 1 -print | sort)
  printf '  }\n}\n' >> "$tmp"
  chmod 0600 "$tmp"
  mv -fT "$tmp" "$output"
}

dpi_rules_need_nfqws() {
  local state_dir="$1" file
  [[ -d "$state_dir" ]] || return 1
  while IFS= read -r file; do
    dpi_load_scope_file "$file" || return 2
    dpi_mode_uses_nfqws "$DPI_SCOPE_MODE" && return 0
  done < <(find "$state_dir" -mindepth 1 -maxdepth 1 -print | sort)
  return 1
}

dpi_bundled_nfqws() {
  local source="${TWEBPROXY_DPI_NFQWS_SOURCE:-}" manager_dir
  if [[ -n "$source" ]]; then printf '%s' "$source"; return; fi
  manager_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/assets/nfqws-linux-x86_64' "$manager_dir"
}

dpi_verify_nfqws_candidate() {
  local candidate="$1" actual version_line
  [[ -f "$candidate" && ! -L "$candidate" ]] || return 1
  [[ "$(stat -c '%s' -- "$candidate" 2>/dev/null)" == "$DPI_NFQWS_BINARY_BYTES" ]] || return 1
  actual="$(sha256sum "$candidate" 2>/dev/null | awk '{print $1}')"
  [[ "$actual" == "$DPI_NFQWS_SHA256" ]] || return 1
  [[ -x "$candidate" ]] || return 1
  version_line="$(timeout 10 "$candidate" --version 2>&1 | sed -n '1p')" || return 1
  [[ "$version_line" == "github version $DPI_NFQWS_VERSION ($DPI_NFQWS_COMMIT)" ]] || return 1
  timeout 15 "$candidate" --dry-run --qnum="$DPI_NFQUEUE_NUM" --filter-l3=ipv4 \
    --dpi-desync=fake,multisplit --dpi-desync-split-pos=1 \
    --dpi-desync-fooling=badseq --dpi-desync-cutoff=d2 \
    --dpi-desync-fwmark="$DPI_NFQWS_MARK" >/dev/null 2>&1
}

DPI_NFQWS_PREPARED_SOURCE=""
DPI_NFQWS_PREPARED_LICENSE=""

dpi_download_nfqws_release() {
  local work="$1" archive="$1/zapret-release.tar.gz"
  local candidate="$1/nfqws-linux-x86_64" license="$1/nfqws-LICENSE.txt" size actual
  command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 || return 1
  curl --fail --silent --show-error --location \
    --connect-timeout 5 --max-time 90 --retry 2 --max-filesize "$DPI_NFQWS_RELEASE_MAX_BYTES" \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    -H 'User-Agent: twebproxy-manager-nfqws-provisioner' \
    -o "$archive" "$DPI_NFQWS_RELEASE_ARCHIVE_URL" || return 1
  [[ -f "$archive" && ! -L "$archive" ]] || return 1
  size="$(stat -c '%s' -- "$archive" 2>/dev/null)"
  [[ "$size" =~ ^[0-9]+$ ]] && (( size > 0 && size <= DPI_NFQWS_RELEASE_MAX_BYTES )) || return 1
  timeout 20 tar -xzOf "$archive" -- "$DPI_NFQWS_RELEASE_BINARY_MEMBER" \
    | head -c "$((DPI_NFQWS_BINARY_BYTES + 1))" > "$candidate" || return 1
  [[ "$(stat -c '%s' -- "$candidate" 2>/dev/null)" == "$DPI_NFQWS_BINARY_BYTES" ]] || return 1
  chmod 0700 "$candidate" || return 1
  # Hash verification precedes the first execution of downloaded bytes.
  dpi_verify_nfqws_candidate "$candidate" || return 1
  timeout 20 tar -xzOf "$archive" -- "$DPI_NFQWS_RELEASE_LICENSE_MEMBER" 2>/dev/null \
    | head -c "$((DPI_NFQWS_LICENSE_BYTES + 1))" > "$license" || return 1
  [[ "$(stat -c '%s' -- "$license" 2>/dev/null)" == "$DPI_NFQWS_LICENSE_BYTES" ]] || return 1
  actual="$(sha256sum "$license" 2>/dev/null | awk '{print $1}')"
  [[ "$actual" == "$DPI_NFQWS_LICENSE_SHA256" ]] || return 1
  chmod 0644 "$license" || return 1
  DPI_NFQWS_PREPARED_LICENSE="$license"
  DPI_NFQWS_PREPARED_SOURCE="$candidate"
}

dpi_prepare_nfqws_source() {
  local work="$1" source license actual
  DPI_NFQWS_PREPARED_SOURCE=""
  DPI_NFQWS_PREPARED_LICENSE=""
  source="$(dpi_bundled_nfqws)" || return 1

  # An explicit source is authoritative for tests/operators and fails closed.
  # Normal installed-manager operation falls back only when the adjacent release
  # asset is truly absent, never when an existing entry is unsafe or corrupt.
  if [[ -n "${TWEBPROXY_DPI_NFQWS_SOURCE:-}" || -e "$source" || -L "$source" ]]; then
    dpi_verify_nfqws_candidate "$source" || return 1
    DPI_NFQWS_PREPARED_SOURCE="$source"
    license="$(dirname -- "$source")/nfqws-LICENSE.txt"
    if [[ -e "$license" || -L "$license" ]]; then
      [[ -f "$license" && ! -L "$license" ]] || return 1
      actual="$(sha256sum "$license" 2>/dev/null | awk '{print $1}')"
      [[ "$actual" == "$DPI_NFQWS_LICENSE_SHA256" ]] || return 1
      DPI_NFQWS_PREPARED_LICENSE="$license"
    fi
    return 0
  fi

  dpi_download_nfqws_release "$work"
}

dpi_install_nfqws() {
  local source doc_dir work="" license="" installed_now=0
  if [[ -e "$DPI_NFQWS_BIN" || -L "$DPI_NFQWS_BIN" ]]; then
    [[ -f "$DPI_NFQWS_BIN" && ! -L "$DPI_NFQWS_BIN" ]] || return 1
    dpi_verify_nfqws_candidate "$DPI_NFQWS_BIN" || return 1
  else
    work="$(mktemp -d /tmp/twebproxy-nfqws.XXXXXX)" || return 1
    if ! dpi_prepare_nfqws_source "$work"; then
      rm -rf --one-file-system -- "$work"
      return 1
    fi
    source="$DPI_NFQWS_PREPARED_SOURCE"
    license="$DPI_NFQWS_PREPARED_LICENSE"
    if ! install -d -o root -g root -m 0755 "$LIBEXEC_DIR"; then
      rm -rf --one-file-system -- "$work"
      return 1
    fi
    if ! install -o root -g root -m 0755 "$source" "$DPI_NFQWS_BIN" \
       || ! dpi_verify_nfqws_candidate "$DPI_NFQWS_BIN"; then
      rm -f -- "$DPI_NFQWS_BIN"
      rm -rf --one-file-system -- "$work"
      return 1
    fi
    installed_now=1
    if [[ -n "$license" ]]; then
      doc_dir="$DPI_DOC_DIR"
      install -d -o root -g root -m 0755 "$doc_dir" \
        || { rm -f -- "$DPI_NFQWS_BIN"; rm -rf --one-file-system -- "$work"; return 1; }
      install -o root -g root -m 0644 "$license" "$doc_dir/nfqws-LICENSE.txt" \
        || { rm -f -- "$DPI_NFQWS_BIN"; rm -rf --one-file-system -- "$work"; return 1; }
    fi
    rm -rf --one-file-system -- "$work"
  fi
  if ! printf '%s  %s\n' "$DPI_NFQWS_SHA256" "$DPI_NFQWS_BIN" > "$DPI_NFQWS_SUM_FILE" \
     || ! chown root:root "$DPI_NFQWS_SUM_FILE" \
     || ! chmod 0644 "$DPI_NFQWS_SUM_FILE" \
     || ! dpi_verify_nfqws_candidate "$DPI_NFQWS_BIN"; then
    if (( installed_now )); then rm -f -- "$DPI_NFQWS_BIN"; fi
    rm -f -- "$DPI_NFQWS_SUM_FILE"
    return 1
  fi
}

dpi_write_firewall_runtime() {
  install -d -o root -g root -m 0755 "$LIBEXEC_DIR" || return 1
  cat > "$LIBEXEC_DIR/apply-dpi-firewall" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
NFT=$(printf '%q' "$DPI_NFT_BIN")
if "\$NFT" list table ip $DPI_NFT_TABLE >/dev/null 2>&1; then
  "\$NFT" delete table ip $DPI_NFT_TABLE
fi
if [[ -s $(printf '%q' "$DPI_NFT_FILE") ]]; then
  "\$NFT" -f $(printf '%q' "$DPI_NFT_FILE")
fi
EOF
  chmod 0755 "$LIBEXEC_DIR/apply-dpi-firewall"
  cat > "$SYSTEMD_DIR/$DPI_FIREWALL_UNIT" <<EOF
[Unit]
Description=TWebProxy optional network-compatibility nftables rules
After=nftables.service
ReloadPropagatedFrom=nftables.service
Before=$DPI_NFQWS_UNIT

[Service]
Type=oneshot
ExecStart=$LIBEXEC_DIR/apply-dpi-firewall
ExecReload=$LIBEXEC_DIR/apply-dpi-firewall
ExecStop=-$DPI_NFT_BIN delete table ip $DPI_NFT_TABLE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

dpi_write_nfqws_unit() {
  id twebproxy-dpi >/dev/null 2>&1 || useradd --system --home /nonexistent --shell /usr/sbin/nologin twebproxy-dpi || return 1
  cat > "$SYSTEMD_DIR/$DPI_NFQWS_UNIT" <<EOF
[Unit]
Description=TWebProxy pinned nfqws network-compatibility worker
Requires=$DPI_FIREWALL_UNIT
After=$DPI_FIREWALL_UNIT

[Service]
Type=simple
User=twebproxy-dpi
Group=twebproxy-dpi
ExecStartPre=/usr/bin/sha256sum --check --status $DPI_NFQWS_SUM_FILE
ExecStart=$DPI_NFQWS_BIN --qnum=$DPI_NFQUEUE_NUM --filter-l3=ipv4 --dpi-desync=fake,multisplit --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq --dpi-desync-cutoff=d2 --dpi-desync-fwmark=$DPI_NFQWS_MARK
Restart=on-failure
RestartSec=2s
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectProc=invisible
ProcSubset=pid
RestrictAddressFamilies=AF_NETLINK AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
}

dpi_apply_rules_file() {
  local rules="$1"
  [[ -x "$DPI_NFT_BIN" ]] || return 1
  if [[ -s "$rules" ]]; then "$DPI_NFT_BIN" -c -f "$rules" >/dev/null || return 1; fi
  if "$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE" >/dev/null 2>&1; then
    "$DPI_NFT_BIN" delete table ip "$DPI_NFT_TABLE" >/dev/null || return 1
  fi
  if [[ -s "$rules" ]]; then "$DPI_NFT_BIN" -f "$rules" >/dev/null || return 1; fi
  return 0
}

dpi_nfqws_runtime_parent_safe() {
  local path="$LIBEXEC_DIR" current="" component
  local -a components=()
  [[ "$path" == /* && "$path" != "/" && "$path" != */ ]] || return 1
  IFS='/' read -r -a components <<< "${path#/}"
  ((${#components[@]} > 0)) || return 1
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || return 1
    current="$current/$component"
    [[ ! -L "$current" && -d "$current" ]] || return 1
  done
}

dpi_remove_owned_nfqws_runtime_files() {
  local entry
  [[ "$DPI_NFQWS_BIN" == "$LIBEXEC_DIR/twebproxy-nfqws" ]] || return 1
  [[ "$DPI_NFQWS_SUM_FILE" == "$LIBEXEC_DIR/twebproxy-nfqws.sha256" ]] || return 1

  # A missing TWebProxy libexec directory already means there are no runtime
  # files to remove.  If it exists, reject every symlinked/ambiguous parent
  # component before unlinking only the two fixed TWebProxy-owned leaf names.
  if [[ ! -e "$LIBEXEC_DIR" && ! -L "$LIBEXEC_DIR" ]]; then return 0; fi
  dpi_nfqws_runtime_parent_safe || return 1
  for entry in "$DPI_NFQWS_BIN" "$DPI_NFQWS_SUM_FILE"; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ ! -d "$entry" || -L "$entry" ]] || return 1
    rm -f -- "$entry" || return 1
  done
}

# --- DPI stage diagnostics -------------------------------------------------
# Activation and reconciliation are a fixed sequence of named stages. Each stage
# records its name, the operation invoked and the exit status, so a failure is
# attributable instead of collapsing into one opaque "transaction failed" line.
# Detail goes to the manager transcript only; the TUI keeps its concise result.
DPI_LAST_STAGE=""
DPI_LAST_STAGE_OP=""
DPI_LAST_STAGE_RC=""
DPI_LAST_STAGE_REASON=""
# Marks the diagnostics emitted while a rollback reconciliation is running, so a
# rollback's own stages are not confused with the stages of the failed attempt.
DPI_DIAG_PHASE=""

dpi_stage_reset() { DPI_LAST_STAGE=""; DPI_LAST_STAGE_OP=""; DPI_LAST_STAGE_RC=""; DPI_LAST_STAGE_REASON=""; }

# Appends one diagnostic line to the manager transcript written by
# setup_logging. Without a transcript (TWEBPROXY_NO_LOG, non-root) the manager
# stays silent rather than adding noise to the TUI. Diagnostics carry only
# operational fields - stage, operation, exit status, reason, unit, rollback.
dpi_diag_log() {
  local target="${CURRENT_LOG:-}"
  [[ -n "$target" && -w "$target" ]] || return 0
  printf '[dpi] %s %s%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || true)" \
    "${DPI_DIAG_PHASE:+phase=$DPI_DIAG_PHASE }" "$*" \
    | sanitize_log_stream >> "$target" 2>/dev/null || true
  return 0
}

# dpi_stage_run STAGE REASON COMMAND [ARG...]
# Runs exactly one reconciliation stage and returns the command's exit status.
dpi_stage_run() {
  local stage="$1" reason="$2"; shift 2
  local rc=0 op="$*"
  DPI_LAST_STAGE="$stage"; DPI_LAST_STAGE_OP="$op"; DPI_LAST_STAGE_RC=0; DPI_LAST_STAGE_REASON=""
  # Forced-failure seam. Extends the existing TWEBPROXY_DPI_TEST_FAIL_POINT
  # variable: "stage:<name>" injects a deterministic failure at exactly one
  # named stage. The legacy point names keep working unchanged.
  if [[ "${TWEBPROXY_DPI_TEST_FAIL_POINT:-}" == "stage:$stage" ]]; then
    rc=90
  else
    "$@" || rc=$?
  fi
  if (( rc != 0 )); then
    # Re-assert: a nested helper may have recorded its own sub-stage, but the
    # stage reported to the operator is the one that was actually being run.
    DPI_LAST_STAGE="$stage"; DPI_LAST_STAGE_OP="$op"
    DPI_LAST_STAGE_RC="$rc"; DPI_LAST_STAGE_REASON="$reason"
    dpi_diag_log "stage=$stage op=$op status=$rc result=failed reason=$reason"
    return "$rc"
  fi
  dpi_diag_log "stage=$stage op=$op status=0 result=ok"
  return 0
}

# Records a stage failure raised outside dpi_stage_run.
dpi_stage_fail() {
  local stage="$1" op="$2" rc="$3" reason="$4"
  DPI_LAST_STAGE="$stage"; DPI_LAST_STAGE_OP="$op"; DPI_LAST_STAGE_RC="$rc"; DPI_LAST_STAGE_REASON="$reason"
  dpi_diag_log "stage=$stage op=$op status=$rc result=failed reason=$reason"
  return 0
}

# systemctl wrapper preserving the quiet call sites the TUI relies on.
dpi_systemctl_quiet() { systemctl "$@" >/dev/null; }

# Tears exactly one TWebProxy DPI unit down, completely and idempotently.
#
# Field fix 3: the previous code passed both unit names to a single
# `systemctl disable --now A B`. systemd resolves every named unit file up front
# and fails the whole call when one is missing - which is always the case for
# the non-nfqws modes, where the nfqws unit was never installed. `|| true`
# swallowed that failure, the firewall unit was never stopped, and its unit file
# was then deleted underneath the still-running unit, leaving the field-observed
# "Loaded: not-found / Active: active (exited)" ghost.
#
# Units are therefore stopped one at a time, while their unit file still exists,
# and the result is verified afterwards.
dpi_unit_teardown() {
  local unit="$1"
  # Only ever act on the two units TWebProxy owns; never on unrelated units.
  case "$unit" in
    "$DPI_FIREWALL_UNIT"|"$DPI_NFQWS_UNIT") ;;
    *) return 1;;
  esac
  systemctl stop "$unit" >/dev/null 2>&1 || true
  systemctl disable "$unit" >/dev/null 2>&1 || true
  rm -f -- "$SYSTEMD_DIR/$unit"
  systemctl daemon-reload >/dev/null 2>&1 || true
  # Idempotent repair of an already-orphaned unit: a unit file removed while the
  # unit was active leaves it active across the reload, so stop it again and
  # clear any lingering failed state.
  if systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
    dpi_stage_fail 'cleanup unit runtime' "systemctl stop $unit" 1 "unit still active after teardown"
    return 1
  fi
  return 0
}

# Zero active TWebProxy DPI firewall runtime state is the STOCK contract.
dpi_runtime_units_inactive() {
  local unit
  for unit in "$DPI_FIREWALL_UNIT" "$DPI_NFQWS_UNIT"; do
    if systemctl is-active --quiet "$unit" >/dev/null 2>&1; then return 1; fi
  done
  return 0
}

dpi_cleanup_nfqws_runtime() {
  local rc=0
  dpi_unit_teardown "$DPI_NFQWS_UNIT" || rc=1
  # A refused removal of the TWebProxy-owned nfqws runtime files is a cleanup
  # failure and stops here, exactly as before this pass. dpi_stage_fail only
  # records the reason - it returns 0 - so the refusal is returned explicitly.
  if ! dpi_remove_owned_nfqws_runtime_files; then
    dpi_stage_fail 'cleanup nfqws runtime' dpi_remove_owned_nfqws_runtime_files 1 \
      'owned nfqws runtime files could not be removed safely'
    return 1
  fi
  [[ ! -L "$DPI_DOC_DIR" ]] || return 1
  rm -f -- "$DPI_DOC_DIR/nfqws-LICENSE.txt" || return 1
  id twebproxy-dpi >/dev/null 2>&1 && userdel twebproxy-dpi >/dev/null 2>&1 || true
  return "$rc"
}

dpi_cleanup_stock_runtime() {
  local rc=0
  dpi_cleanup_nfqws_runtime || rc=1
  dpi_unit_teardown "$DPI_FIREWALL_UNIT" || rc=1
  dpi_apply_rules_file /dev/null || rc=1
  # Do not traverse an unexpected libexec/state parent during cleanup.
  if dpi_nfqws_runtime_parent_safe; then
    rm -f -- "$LIBEXEC_DIR/apply-dpi-firewall" || rc=1
  else rc=1; fi
  if [[ ! -L "$DPI_DIR" ]]; then rm -f -- "$DPI_NFT_FILE" || rc=1
  else rc=1; fi
  systemctl daemon-reload >/dev/null 2>&1 || rc=1
  if ! dpi_stock_postcondition_ok; then
    dpi_stage_fail 'cleanup stock runtime' dpi_cleanup_stock_runtime 1 "owned DPI runtime remains or its absence could not be verified"
    rc=1
  fi
  return "$rc"
}

dpi_verify_runtime() {
  local need_nfqws="$1" file files scopes="" live=""
  [[ -s "$DPI_NFT_FILE" ]] || return 1
  # Capture the entire producer once and check its own status before parsing.
  # JSON schema 1 is provided by supported Debian/Ubuntu nftables. No textual
  # substring matching, locale-dependent tokens or early-exit pipeline reader.
  live="$("$DPI_NFT_BIN" -j -n list table ip "$DPI_NFT_TABLE" 2>/dev/null)" || return 1
  files="$(find "$DPI_STATE_DIR" -mindepth 1 -maxdepth 1 -print | sort)" || return 1
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    dpi_load_scope_file "$file" || return 1
    scopes+="$DPI_SCOPE_IPV4"$'\t'"$DPI_SCOPE_MODE"$'\n'
  done <<< "$files"
  [[ -n "$scopes" ]] || return 1
  jq -e --arg scopes "$scopes" --arg table "$DPI_NFT_TABLE" \
    --argjson mark "$((DPI_NFQWS_MARK))" --argjson queue "$DPI_NFQUEUE_NUM" '
    def payload($p;$f): {payload:{protocol:$p,field:$f}};
    def eqm($l;$r): {match:{op:"==",left:$l,right:$r}};
    def flags: {"&":[payload("tcp";"flags"),23]};
    def base($ip): [eqm(payload("ip";"saddr");$ip),eqm(payload("tcp";"sport");443)];
    def wanted($ip;$mode):
      (if ($mode | startswith("window1152")) then
         [{kind:"window1152",expr:(base($ip)+[eqm(flags;18),
           {mangle:{key:payload("tcp";"window"),value:1152}},{counter:null}])}]
       elif ($mode | startswith("mss88")) then
         [{kind:"mss88",expr:(base($ip)+[eqm(flags;18),
           {mangle:{key:{"tcp option":{name:"maxseg",field:"size"}},value:88}},{counter:null}])}]
       else [] end) +
      (if ($mode | contains("nfqws")) then
         [{kind:"nfqws",expr:(base($ip)+[
           eqm({"&":[{meta:{key:"mark"}},$mark]};0),
           eqm({ct:{key:"packets",dir:"reply"}};{range:[1,6]}),
           {counter:null},{queue:{num:$queue,flags:["bypass"]}}])}]
       else [] end) |
      map({family:"ip",table:$table,chain:"output",comment:("twebproxy:"+$ip+":"+.kind),expr});
    def number:
      if type == "number" then .
      elif type == "string" and test("^0x[0-9a-fA-F]+$") then
        ascii_downcase | .[2:] | explode |
        reduce .[] as $d (0; . * 16 + (if $d <= 57 then $d-48 else $d-87 end))
      else error("unexpected numeric representation") end;
    def bits:
      if type == "number" then .
      elif type == "array" then map(bits) | unique | add
      elif type == "string" and test("^0x") then number
      else ({"fin":1,"syn":2,"rst":4,"psh":8,"ack":16,"urg":32,"ecn":64,"cwr":128}[.] //
            error("unknown TCP flag")) end;
    def normalized_expr:
      if has("counter") then
        if keys == ["counter"] and (.counter == null or
          ((.counter|type) == "object" and ((.counter|keys)-["packets","bytes"]|length) == 0))
        then {counter:null} else error("invalid counter") end
      elif has("queue") then
        .queue.flags |= (if type == "string" then [.] else . end | sort)
      elif .match.left["&"][0]? == payload("tcp";"flags") then
        .match.left["&"][1] |= bits | .match.right |= bits
      elif .match.left["&"][0]? == {meta:{key:"mark"}} then
        .match.left["&"][1] |= number | .match.right |= number
      else . end;
    (.nftables | type == "array") and
    all(.nftables[]; (keys == ["metainfo"] or keys == ["table"] or keys == ["chain"] or keys == ["rule"])) and
    ([.nftables[]|select(has("table"))|.table|
      select((.flags // []) == [])|{family,name}] == [{family:"ip",name:$table}]) and
    ([.nftables[]|select(has("chain"))|.chain|
      select(.dev? == null)|{family,table,name,type,hook,prio,policy}] ==
      [{family:"ip",table:$table,name:"output",type:"filter",hook:"output",prio:-150,policy:"accept"}]) and
    ([.nftables[]|select(has("rule"))|.rule|{family,table,chain,comment,expr:(.expr|map(normalized_expr))}] ==
      [$scopes|split("\n")[]|select(length>0)|split("\t")|wanted(.[0];.[1])[]])
  ' <<< "$live" >/dev/null || return 1
  if (( need_nfqws )); then
    [[ -f "$DPI_NFQWS_BIN" && ! -L "$DPI_NFQWS_BIN" ]] || return 1
    [[ "$(sha256sum "$DPI_NFQWS_BIN" | awk '{print $1}')" == "$DPI_NFQWS_SHA256" ]] || return 1
    systemctl is-active --quiet "$DPI_NFQWS_UNIT" || return 1
  fi
  return 0
}

# Extracted so the first reconciliation stage is a single callable operation.
dpi_prepare_runtime_dirs() {
  install -d -o root -g root -m 0700 "$DPI_DIR" "$DPI_STATE_DIR" || return 1
  [[ ! -L "$DPI_DIR" && ! -L "$DPI_STATE_DIR" ]] || return 1
}

# Each step is a named stage so an activation failure can be attributed exactly.
# The sequence and the operations themselves are unchanged.
dpi_reconcile_runtime() {
  local need_nfqws=0
  dpi_stage_reset
  dpi_stage_run 'prepare runtime' 'DPI state directories could not be created or are symlinked' \
    dpi_prepare_runtime_dirs || return 1
  dpi_stage_run 'render rules' 'the nftables ruleset could not be rendered from the scope state' \
    dpi_render_rules "$DPI_STATE_DIR" "$DPI_NFT_FILE" || return 1
  if [[ ! -s "$DPI_NFT_FILE" ]]; then
    dpi_stage_run 'cleanup stock runtime' 'DPI runtime state could not be fully removed' \
      dpi_cleanup_stock_runtime || return 1
    return 0
  fi
  dpi_rules_need_nfqws "$DPI_STATE_DIR" && need_nfqws=1
  dpi_stage_run 'write firewall unit' 'the firewall helper or unit file could not be written' \
    dpi_write_firewall_runtime || return 1
  if (( need_nfqws )); then
    dpi_stage_run 'install nfqws runtime' 'the pinned nfqws binary could not be installed or verified' \
      dpi_install_nfqws || return 1
    dpi_stage_run 'write nfqws unit' 'the nfqws unit file or its service account could not be created' \
      dpi_write_nfqws_unit || return 1
  fi
  dpi_stage_run 'daemon-reload' 'systemd did not reload the unit files' \
    systemctl daemon-reload || return 1
  dpi_stage_run 'enable unit' 'the firewall unit could not be enabled' \
    dpi_systemctl_quiet enable "$DPI_FIREWALL_UNIT" || return 1
  dpi_stage_run 'apply nft candidate' 'the rendered ruleset was rejected by nft' \
    dpi_apply_rules_file "$DPI_NFT_FILE" || return 1
  [[ "${TWEBPROXY_DPI_TEST_FAIL_POINT:-}" != after_firewall ]] || {
    dpi_stage_fail 'restart unit' 'systemctl restart' 1 'forced test failure point after_firewall'
    return 1
  }
  dpi_stage_run 'restart unit' 'the firewall unit could not be started' \
    dpi_systemctl_quiet restart "$DPI_FIREWALL_UNIT" || return 1
  if (( need_nfqws )); then
    [[ "${TWEBPROXY_DPI_TEST_FAIL_POINT:-}" != nfqws_start ]] || {
      dpi_stage_fail 'enable nfqws unit' 'systemctl enable --now' 1 'forced test failure point nfqws_start'
      return 1
    }
    dpi_stage_run 'enable nfqws unit' 'the nfqws worker could not be enabled or started' \
      dpi_systemctl_quiet enable --now "$DPI_NFQWS_UNIT" || return 1
  else
    # Modes without nfqws must leave no nfqws runtime behind. The teardown
    # performs its own daemon-reload.
    dpi_stage_run 'cleanup nfqws runtime' 'leftover nfqws runtime could not be removed' \
      dpi_cleanup_nfqws_runtime || return 1
  fi
  dpi_stage_run 'verify runtime' 'the live runtime does not match the committed state' \
    dpi_verify_runtime "$need_nfqws" || return 1
  return 0
}


dpi_restore_snapshot() {
  local snapshot="$1" injected="${TWEBPROXY_DPI_TEST_FAIL_POINT:-}"
  local prev_phase="${DPI_DIAG_PHASE:-}" restored=1
  rm -rf "$DPI_DIR"
  if [[ -d "$snapshot/dpi" ]]; then
    # Checked, for the same reason the publication path is: this function runs
    # with errexit suspended, and an unchecked copy left reconciliation looking
    # at an EMPTY state directory, taking its STOCK branch and returning 0 - so
    # the manager logged `rollback=restored` for a rollback that never happened
    # and the previous state was gone.
    cp -a "$snapshot/dpi" "$DPI_DIR" || restored=0
    dpi_state_dir_complete "$snapshot/dpi" "$DPI_DIR" || restored=0
  fi
  unset TWEBPROXY_DPI_TEST_FAIL_POINT
  DPI_DIAG_PHASE=rollback
  if (( restored )) && dpi_reconcile_runtime >/dev/null 2>&1; then
    DPI_DIAG_PHASE="$prev_phase"
    [[ -n "$injected" ]] && export TWEBPROXY_DPI_TEST_FAIL_POINT="$injected"
    return 0
  fi
  DPI_DIAG_PHASE="$prev_phase"
  [[ -n "$injected" ]] && export TWEBPROXY_DPI_TEST_FAIL_POINT="$injected"
  # A rollback that cannot be re-applied must fail closed. Remove only the
  # manager-owned DPI table/state; the accepted backend firewall is untouched.
  rm -rf "$DPI_DIR"
  dpi_cleanup_stock_runtime || true
  return 1
}

# Verifies that every entry of the candidate arrived in the staged copy. A
# short write or a copy that died half way leaves a directory that looks
# plausible but is not the state the operator asked for.
dpi_state_dir_complete() {
  local src="$1" dst="$2"
  [[ -d "$src" && ! -L "$src" && -d "$dst" && ! -L "$dst" ]] || return 1
  # Compare content and entry sets, not just file sizes; never dereference links.
  diff -qr --no-dereference -- "$src" "$dst" >/dev/null 2>&1
}

dpi_scope_dir_valid() {
  local dir="$1" entries file
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  entries="$(find "$dir" -mindepth 1 -maxdepth 1 -print)" || return 1
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    dpi_load_scope_file "$file" || return 1
  done <<< "$entries"
}

# Resolve only this operation's two-rename boundary, under the existing lock,
# BEFORE any next read/modify/write. Two authoritative-looking directories or
# malformed evidence are ambiguous: leave them untouched and refuse mutation.
dpi_resolve_pending_publication() {
  local retired="$DPI_DIR/.scopes.old" staging="$DPI_DIR/.scopes.new"
  [[ ! -e "$DPI_DIR" && ! -L "$DPI_DIR" ]] && return 0
  [[ -d "$DPI_DIR" && ! -L "$DPI_DIR" ]] || return 1
  if [[ -e "$DPI_STATE_DIR" || -L "$DPI_STATE_DIR" ]]; then
    dpi_scope_dir_valid "$DPI_STATE_DIR" || return 1
  fi
  if [[ -e "$retired" || -L "$retired" ]]; then
    [[ ! -e "$DPI_STATE_DIR" && ! -L "$DPI_STATE_DIR" ]] || return 1
    dpi_scope_dir_valid "$retired" || return 1
    if [[ -e "$staging" || -L "$staging" ]]; then dpi_scope_dir_valid "$staging" || return 1; fi
    mv -fT -- "$retired" "$DPI_STATE_DIR" || return 1
  fi
  if [[ -e "$staging" || -L "$staging" ]]; then
    # A live directory proves that this is an unpublished candidate.
    [[ -d "$DPI_STATE_DIR" ]] && dpi_scope_dir_valid "$staging" || return 1
    rm -rf -- "$staging" || return 1
  fi
  return 0
}

dpi_prepare_transaction_state() {
  local work="$1"
  mkdir -p "$work/snapshot" "$work/proposed" || return 1
  if [[ -e "$DPI_DIR" || -L "$DPI_DIR" ]]; then
    [[ -d "$DPI_DIR" && ! -L "$DPI_DIR" ]] || return 1
    cp -a "$DPI_DIR" "$work/snapshot/dpi" || return 1
    dpi_state_dir_complete "$DPI_DIR" "$work/snapshot/dpi" || return 1
  fi
  if [[ -e "$DPI_STATE_DIR" || -L "$DPI_STATE_DIR" ]]; then
    dpi_scope_dir_valid "$DPI_STATE_DIR" || return 1
    cp -a "$DPI_STATE_DIR/." "$work/proposed/" || return 1
    dpi_state_dir_complete "$DPI_STATE_DIR" "$work/proposed" || return 1
    dpi_scope_dir_valid "$work/proposed" || return 1
  fi
  return 0
}

# Publishes the candidate scope set as the authoritative state directory.
#
# The 0.2.9 shape was `rm -rf "$DPI_STATE_DIR"; cp -a "$proposed" "$DPI_STATE_DIR"`
# with neither command checked. This function is only ever called from a
# conditional context, where bash suspends errexit for the whole body, so a
# failing copy did not stop anything: the old state was already gone, the new
# one never arrived, and reconciliation then saw an empty state directory, took
# its STOCK branch and returned success.
#
# rename(2) refuses to replace a non-empty directory (ENOTEMPTY), so a single
# `mv candidate over $DPI_STATE_DIR` is not a publication primitive here. The
# candidate is instead materialised beside the live directory and verified
# complete before anything authoritative is touched; only then is the old
# directory renamed aside and the new one renamed into place. Every step is
# checked, and the previous state is put back if the final rename fails.
dpi_publish_state_dir() {
  local proposed="$1"
  local staging="$DPI_DIR/.scopes.new" retired="$DPI_DIR/.scopes.old"
  install -d -o root -g root -m 0700 "$DPI_DIR" || return 1
  [[ ! -L "$DPI_DIR" && ! -L "$DPI_STATE_DIR" ]] || return 1
  # The caller must have resolved interrupted publication before reading state.
  [[ ! -e "$retired" && ! -L "$retired" ]] || return 1
  rm -rf -- "$staging" || return 1

  dpi_stage_run 'publish state copy' 'the candidate DPI state could not be staged' \
    cp -a -- "$proposed" "$staging" || { rm -rf -- "$staging"; return 1; }
  dpi_stage_run 'publish state verify' 'the staged DPI state is incomplete' \
    dpi_state_dir_complete "$proposed" "$staging" || { rm -rf -- "$staging"; return 1; }

  # From here on the live directory is touched, so every failure restores it.
  if [[ -d "$DPI_STATE_DIR" ]]; then
    dpi_stage_run 'publish state retire' 'the previous DPI state could not be set aside' \
      mv -fT -- "$DPI_STATE_DIR" "$retired" || { rm -rf -- "$staging"; return 1; }
  fi
  if ! dpi_stage_run 'publish state rename' 'the staged DPI state could not be published' \
       mv -fT -- "$staging" "$DPI_STATE_DIR"; then
    rm -rf -- "$staging"
    if [[ -d "$retired" && ! -e "$DPI_STATE_DIR" ]]; then
      # Put the previous state back. If even that fails, LEAVE .scopes.old in
      # place: it is then the only copy, and deleting it here would destroy the
      # very state this branch exists to preserve.
      mv -fT -- "$retired" "$DPI_STATE_DIR" || return 1
    fi
    rm -rf -- "$retired"
    return 1
  fi
  rm -rf -- "$retired" || return 1
  return 0
}

dpi_commit_candidate_state() {
  local proposed="$1" snapshot="$2"
  dpi_stage_reset
  DPI_LAST_STAGE='commit state'
  # Checked explicitly: errexit is suspended for this whole function body.
  if ! dpi_publish_state_dir "$proposed"; then
    dpi_rollback_to_snapshot "$snapshot"
    return 1
  fi
  if [[ "${TWEBPROXY_DPI_TEST_FAIL_POINT:-}" == after_state \
     || "${TWEBPROXY_DPI_TEST_FAIL_POINT:-}" == 'stage:commit state' ]]; then
    dpi_stage_fail 'commit state' dpi_commit_candidate_state 1 'forced test failure point after the state was written'
    dpi_rollback_to_snapshot "$snapshot"
    return 1
  fi
  if ! dpi_reconcile_runtime; then
    dpi_rollback_to_snapshot "$snapshot"
    return 1
  fi
  dpi_diag_log "stage=commit state op=dpi_commit_candidate_state status=0 result=ok"
  return 0
}

# Rolls back after a failed stage and reports the outcome without losing the
# identity of the stage that actually failed - dpi_restore_snapshot reconciles
# again and would otherwise overwrite it.
dpi_rollback_to_snapshot() {
  local snapshot="$1"
  local stage="${DPI_LAST_STAGE:-unknown}" op="${DPI_LAST_STAGE_OP:-}"
  local rc="${DPI_LAST_STAGE_RC:-1}" reason="${DPI_LAST_STAGE_REASON:-}"
  local rollback=restored
  dpi_restore_snapshot "$snapshot" || rollback=failed-fell-back-to-STOCK
  DPI_LAST_ROLLBACK="$rollback"
  DPI_LAST_STAGE="$stage"; DPI_LAST_STAGE_OP="$op"
  DPI_LAST_STAGE_RC="$rc"; DPI_LAST_STAGE_REASON="$reason"
  dpi_diag_log "stage=$stage op=$op status=$rc result=failed reason=$reason rollback=$rollback"
  [[ "$rollback" == restored ]]
}

# The concise TUI line for a failed compatibility change, naming the stage that
# failed when one was recorded.
dpi_transaction_failure_message() {
  local mode="${1:-}"
  if [[ "${DPI_LAST_ROLLBACK:-restored}" != restored ]]; then
    ui_msgf dpi_transaction_failed_stage_fallback "${mode:-?}" "${DPI_LAST_STAGE:-unknown}"
  elif [[ -n "${DPI_LAST_STAGE:-}" && -n "$mode" ]]; then
    ui_msgf dpi_transaction_failed_stage "$mode" "$DPI_LAST_STAGE"
  elif [[ -n "${DPI_LAST_STAGE:-}" ]]; then
    ui_msgf dpi_transaction_failed_at_stage "$DPI_LAST_STAGE"
  else
    ui_msg dpi_transaction_failed
  fi
}

# --- DPI mutation lock -----------------------------------------------------
# Every DPI mutation is a read-modify-write: the current scope set is copied
# into a candidate, one scope is added or removed, and the candidate is then
# published as the WHOLE authoritative state. Two overlapping operations each
# publish a candidate built from a state the other has already moved on from.
# Reproduced deterministically with two real processes in
# tests/stagea/sa5-concurrent-mutation.sh: a `dpi set` for a different scope
# reported success and then vanished, and a successful disable was resurrected.
#
# Scope of this lock is deliberately narrow - the DPI mutating lifecycle only.
# Read-only paths (status, audit, list-methods) never take it, and Stage 4 keeps
# its own separate update lock on its own descriptor.
#
# It lives in $BASE_DIR, not in $DPI_DIR: rollback and uninstall both remove
# $DPI_DIR wholesale, which would delete the lock out from under its holder.
DPI_LOCK_FILE="$BASE_DIR/.dpi-mutation.lock"
DPI_LOCK_WAIT_SECONDS="${TWEBPROXY_DPI_LOCK_WAIT:-20}"
DPI_LOCK_DEPTH=0
# Fixed descriptor, distinct from the Stage 4 update lock's fd 9.
DPI_LOCK_FD=8
# Returned by dpi_with_mutation_lock when the lock could not be taken in time.
DPI_LOCK_BUSY_RC=75

dpi_mutation_lock_acquire() {
  # Depth counted, so a locked entrypoint that calls another can never deadlock
  # against itself.
  if (( DPI_LOCK_DEPTH > 0 )); then
    DPI_LOCK_DEPTH=$((DPI_LOCK_DEPTH + 1)); return 0
  fi
  local parent
  # Re-derived from the CURRENT $BASE_DIR on every acquisition rather than being
  # baked in when this file is sourced. In production BASE_DIR is a constant, so
  # this changes nothing; it is what lets a test harness that rebinds BASE_DIR
  # after sourcing keep the lock inside its own sandbox instead of creating and
  # contending on the real /etc/twebproxy lock of the machine running it.
  DPI_LOCK_FILE="$BASE_DIR/.dpi-mutation.lock"
  parent="$(dirname -- "$DPI_LOCK_FILE")"
  install -d -o root -g root -m 0700 "$parent" || return 1
  [[ ! -L "$DPI_LOCK_FILE" ]] || return 1
  exec 8>>"$DPI_LOCK_FILE" || return 1
  chown root:root "$DPI_LOCK_FILE" 2>/dev/null || true
  chmod 0600 "$DPI_LOCK_FILE" 2>/dev/null || true
  if ! flock -w "$DPI_LOCK_WAIT_SECONDS" 8; then
    exec 8>&-
    dpi_diag_log "stage=mutation lock op=flock status=1 result=failed reason=another DPI mutation held the lock for more than ${DPI_LOCK_WAIT_SECONDS}s"
    return 1
  fi
  DPI_LOCK_DEPTH=1
  return 0
}

dpi_mutation_lock_release() {
  (( DPI_LOCK_DEPTH > 0 )) || return 0
  DPI_LOCK_DEPTH=$((DPI_LOCK_DEPTH - 1))
  (( DPI_LOCK_DEPTH == 0 )) && exec 8>&-
  return 0
}

# Runs one DPI mutating operation under the lock. Returns the operation's own
# exit status, or DPI_LOCK_BUSY_RC when the lock could not be taken - callers
# decide whether that is fatal, so a best-effort repair stays best-effort.
dpi_with_mutation_lock() {
  local rc=0
  dpi_mutation_lock_acquire || return "$DPI_LOCK_BUSY_RC"
  if dpi_resolve_pending_publication; then
    "$@" || rc=$?
  else
    dpi_stage_fail 'prepare state' dpi_resolve_pending_publication 1 'ambiguous or invalid interrupted DPI publication'
    rc=1
  fi
  dpi_mutation_lock_release
  return "$rc"
}

# The lock is taken by the read-modify-write primitives themselves, not only by
# the CLI, so no caller can perform an unserialised DPI mutation by accident.
dpi_transaction_set() {
  local rc=0
  dpi_mutation_lock_acquire || return "$DPI_LOCK_BUSY_RC"
  dpi_transaction_set_locked "$@" || rc=$?
  dpi_mutation_lock_release
  return "$rc"
}

dpi_transaction_set_locked() {
  local ip="$1" mode="$2" host="$3" work snapshot proposed
  dpi_stage_reset
  # Fail closed before any state is touched: an unmatchable scope must never be
  # committed, and a previously working mode must survive the refusal.
  dpi_scope_locally_configured "$ip" || return 1
  dpi_resolve_pending_publication || return 1
  work="$(mktemp -d /tmp/twebproxy-dpi.XXXXXX)" || return 1
  snapshot="$work/snapshot"; proposed="$work/proposed"
  dpi_prepare_transaction_state "$work" || {
    dpi_stage_fail 'prepare state' dpi_prepare_transaction_state 1 'snapshot or proposed state could not be copied completely'
    rm -rf -- "$work"; return 1; }
  # Pre-commit validation stages: nothing has been changed yet, but a refusal
  # here is just as opaque to the operator as a runtime failure.
  dpi_write_scope_state "$proposed" "$ip" "$mode" "$host" || {
    dpi_stage_fail 'write scope state' dpi_write_scope_state 1 'the proposed scope state could not be written'
    rm -rf "$work"; return 1; }
  local candidate="$work/candidate.nft"
  dpi_render_rules "$proposed" "$candidate" || {
    dpi_stage_fail 'render candidate rules' dpi_render_rules 1 'the proposed ruleset could not be rendered'
    rm -rf "$work"; return 1; }
  [[ -x "$DPI_NFT_BIN" ]] && "$DPI_NFT_BIN" -c -f "$candidate" >/dev/null || {
    dpi_stage_fail 'check nft candidate' "$DPI_NFT_BIN -c -f" 1 'nft rejected the proposed ruleset'
    rm -rf "$work"; return 1; }
  if dpi_commit_candidate_state "$proposed" "$snapshot"; then rm -rf "$work"; return 0; fi
  rm -rf "$work"; return 1
}

dpi_transaction_disable_ip() {
  local rc=0
  dpi_mutation_lock_acquire || return "$DPI_LOCK_BUSY_RC"
  dpi_transaction_disable_ip_locked "$@" || rc=$?
  dpi_mutation_lock_release
  return "$rc"
}

dpi_transaction_disable_ip_locked() {
  local ip="$1" work snapshot proposed
  dpi_stage_reset
  dpi_resolve_pending_publication || return 1
  work="$(mktemp -d /tmp/twebproxy-dpi.XXXXXX)" || return 1
  snapshot="$work/snapshot"; proposed="$work/proposed"
  dpi_prepare_transaction_state "$work" || {
    dpi_stage_fail 'prepare state' dpi_prepare_transaction_state 1 'snapshot or proposed state could not be copied completely'
    rm -rf -- "$work"; return 1; }
  rm -f "$(dpi_state_path "$proposed" "$ip")" || { rm -rf -- "$work"; return 1; }
  if dpi_commit_candidate_state "$proposed" "$snapshot"; then rm -rf "$work"; return 0; fi
  rm -rf "$work"; return 1
}

dpi_mode_for_host() {
  local host="$1" ip file
  ip="$(dpi_resolve_ipv4 "$host" 2>/dev/null || true)"
  if [[ -z "$ip" && -d "$DPI_STATE_DIR" ]]; then
    while IFS= read -r file; do
      dpi_load_scope_file "$file" || continue
      [[ "$DPI_SCOPE_HOST" == "$host" ]] && { printf '%s\t%s' "$DPI_SCOPE_IPV4" "$DPI_SCOPE_MODE"; return 0; }
    done < <(find "$DPI_STATE_DIR" -mindepth 1 -maxdepth 1 -print | sort)
  fi
  [[ -n "$ip" ]] || { printf 'unresolved\tSTOCK'; return 0; }
  file="$(dpi_state_path "$DPI_STATE_DIR" "$ip")"
  if [[ -f "$file" ]] && dpi_load_scope_file "$file"; then printf '%s\t%s' "$ip" "$DPI_SCOPE_MODE"
  else printf '%s\tSTOCK' "$ip"; fi
}

dpi_list_methods_cmd() {
  banner
  printf '%-22s %s\n' stock "$(ui_msg dpi_method_stock)"
  printf '%-22s %s\n' '' "$(ui_msg dpi_detail_stock)"
  printf '%-22s %s\n' window1152 "$(ui_msg dpi_method_window)"
  printf '%-22s %s\n' '' "$(ui_msg dpi_detail_window)"
  printf '%-22s %s\n' mss88 "$(ui_msg dpi_method_mss)"
  printf '%-22s %s\n' '' "$(ui_msg dpi_detail_mss)"
  printf '%-22s %s\n' nfqws "$(ui_msg dpi_method_nfqws)"
  printf '%-22s %s\n' '' "$(ui_msg dpi_detail_nfqws)"
  printf '%-22s %s\n' window1152_nfqws "$(ui_msg dpi_method_window_nfqws)"
  printf '%-22s %s\n' '' "$(ui_msg dpi_detail_window_nfqws)"
  printf '%-22s %s\n' mss88_nfqws "$(ui_msg dpi_method_mss_nfqws)"
  printf '%-22s %s\n' '' "$(ui_msg dpi_detail_mss_nfqws)"
  printf '\n%s\n' "$(ui_msgf dpi_nfqws_provenance "$DPI_NFQWS_VERSION" "$DPI_NFQWS_COMMIT")"
  printf '\n%s\n%s\n' "$(ui_msg dpi_footer_scope)" "$(ui_msg dpi_footer_guarantee)"
}

# Read-only: does the live kernel table match the recorded scope state?
dpi_runtime_consistency() {
  local files need=0
  files="$(find "$DPI_STATE_DIR" -mindepth 1 -maxdepth 1 -print 2>/dev/null)" || files=""
  if [[ -z "$files" ]]; then
    if "$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE" >/dev/null 2>&1; then printf 'diverged'; else printf 'ok'; fi
    return 0
  fi
  grep -qsE '^MODE=.*nfqws' "$DPI_STATE_DIR"/* && need=1
  if dpi_verify_runtime "$need" >/dev/null 2>&1; then printf 'ok'; else printf 'diverged'; fi
}

dpi_status_cmd() {
  need_root
  local requested="${1:-}" host row ip mode shared ipv6 any=0
  banner; printf '%s\n' "$(ui_msg dpi_stock_note)"
  while read -r host; do
    [[ -n "$host" ]] || continue
    [[ -z "$requested" || "$host" == "$requested" ]] || continue
    row="$(dpi_mode_for_host "$host" || true)"; ip="${row%%$'\t'*}"; mode="${row#*$'\t'}"
    shared="$(dpi_hosts_for_ipv4 "$ip" 2>/dev/null | paste -sd, -)"
    dpi_host_has_ipv6 "$host" && ipv6="$(ui_msg dpi_ipv6_stock)" || ipv6="$(ui_msg unavailable)"
    printf '\n%s\n' "$host"
    tui_kv "$(ui_msg dpi_scope)" "$ip"
    tui_kv "$(ui_msg dpi_mode)" "$mode"
    if [[ "$(dpi_runtime_consistency)" == ok ]]; then
      tui_kv "$(ui_msg dpi_kernel_rules)" "$(ui_msg dpi_kernel_match)"
    else
      tui_kv "$(ui_msg dpi_kernel_rules)" "$(ui_msgf dpi_kernel_diverged "$host")"
    fi
    tui_kv "$(ui_msg dpi_ipv6)" "$ipv6"
    [[ -n "$shared" ]] && tui_kv "$(ui_msg dpi_shared_hosts)" "$shared"
    [[ "$mode" != STOCK ]] && any=1
  done < <(list_hosts_array)
  (( any )) || printf '\n%s\n' "$(ui_msg dpi_no_state)"
}

dpi_set_cmd() {
  need_root; need_systemd
  local host="${1:-}" mode="${2:-}" ack="${3:-}" ip shared
  [[ -n "$host" && -n "$mode" ]] || die "Usage: twebproxy dpi set HOST MODE [--accept-shared-scope]"
  require_instance "$host"
  dpi_mode_valid "$mode" || die "$(ui_msgf dpi_invalid_mode "$mode")"
  [[ "$mode" != stock ]] || { dpi_disable_cmd "$host"; return; }
  ip="$(dpi_resolve_ipv4 "$host" 2>/dev/null || true)"
  [[ -n "$ip" ]] || die "$(ui_msgf dpi_resolution_failed "$host")"
  # `cmd; case $?` is not errexit-safe: under `set -e` a non-zero return aborts
  # before the case is reached. `|| scope_rc=$?` keeps the probe's status while
  # exempting it from errexit, so rc 1 and 2 reach their localized messages.
  local scope_rc=0
  dpi_scope_locally_configured "$ip" || scope_rc=$?
  case "$scope_rc" in
    1) die "$(ui_msgf dpi_scope_not_local "$ip" "$host" "$(dpi_local_ipv4_addresses 2>/dev/null | paste -sd, - || true)")";;
    2) die "$(ui_msgf dpi_scope_probe_unavailable "$ip")";;
  esac
  shared="$(dpi_hosts_for_ipv4 "$ip" | paste -sd, -)"
  warn "$(ui_msgf dpi_scope_warning "$ip" "$host")"
  [[ -n "$shared" ]] && log "$(ui_msg dpi_shared_hosts): $shared"
  log "$(ui_msg dpi_dedicated_unknown)"
  if [[ "$ack" != --accept-shared-scope ]]; then
    if [[ -t 0 && -t 1 ]]; then yesno "$(ui_msg dpi_confirm_scope)" n || exit 1
    else die "$(ui_msg dpi_ack_required)"; fi
  fi
  local set_rc=0
  dpi_with_mutation_lock dpi_transaction_set "$ip" "$mode" "$host" || set_rc=$?
  if (( set_rc == 0 )); then
    ok "$(ui_msgf dpi_applied "$mode" "$host" "$ip")"
  elif (( set_rc == DPI_LOCK_BUSY_RC )); then
    die "$(ui_msg dpi_mutation_busy)"
  else
    die "$(dpi_transaction_failure_message "$mode")"
  fi
}

dpi_disable_cmd() {
  need_root; need_systemd
  local host="${1:-}" rc=0
  [[ -n "$host" ]] || die "Usage: twebproxy dpi disable HOST"
  dpi_with_mutation_lock dpi_disable_host_locked "$host" || rc=$?
  if (( rc != 0 )); then
    (( rc == DPI_LOCK_BUSY_RC )) && die "$(ui_msg dpi_mutation_busy)"
    die "$(dpi_transaction_failure_message)"
  fi
}

dpi_disable_host_locked() {
  need_root; need_systemd
  local host="${1:-}" ip file
  [[ -n "$host" ]] || die "Usage: twebproxy dpi disable HOST"
  require_instance "$host"
  ip="$(dpi_resolve_ipv4 "$host" 2>/dev/null || true)"
  # Stored state is authoritative for what this host actually owns. DNS may have
  # moved on - an address change is the usual reason a scope goes stale - so the
  # stored scope is consulted whenever the resolved address has no state of its
  # own, not only when DNS failed outright. Without this, `dpi stock HOST` after
  # an address change reported STOCK while that host's old rule stayed live.
  if [[ -z "$ip" ]] || [[ ! -f "$(dpi_state_path "$DPI_STATE_DIR" "$ip")" ]]; then
    if [[ -d "$DPI_STATE_DIR" ]]; then
      while IFS= read -r file; do
        dpi_load_scope_file "$file" || continue
        [[ "$DPI_SCOPE_HOST" == "$host" ]] && { ip="$DPI_SCOPE_IPV4"; break; }
      done < <(find "$DPI_STATE_DIR" -maxdepth 1 -type f -name '*.env' -print | sort)
    fi
  fi
  # No address from DNS and none in stored state means there is no scope this
  # host could own: it is already STOCK, and STOCK does not need a resolvable
  # name. Manager-owned runtime may still be orphaned, so reconcile it.
  local dis_rc=0
  if [[ -z "$ip" ]] || [[ ! -f "$(dpi_state_path "$DPI_STATE_DIR" "$ip")" ]]; then
    dpi_with_mutation_lock dpi_disable_reconcile_stock "$host" || dis_rc=$?
    return "$dis_rc"
  fi
  dpi_with_mutation_lock dpi_transaction_disable_ip "$ip" || dis_rc=$?
  (( dis_rc == 0 )) || {
    (( dis_rc == DPI_LOCK_BUSY_RC )) && die "$(ui_msg dpi_mutation_busy)"
    die "$(dpi_transaction_failure_message)"
  }
  ok "$(ui_msgf dpi_disabled "$host")"
}

# Is there any manager-owned DPI runtime that could still be orphaned?
# Used to keep `dpi stock` on a host that never enabled DPI from creating the
# very directories it is meant to find empty.
dpi_runtime_artifacts_present() {
  local path
  for path in "$DPI_NFQWS_BIN" "$DPI_NFQWS_SUM_FILE" "$DPI_DOC_DIR/nfqws-LICENSE.txt" \
    "$SYSTEMD_DIR/$DPI_FIREWALL_UNIT" "$SYSTEMD_DIR/$DPI_NFQWS_UNIT" \
    "$LIBEXEC_DIR/apply-dpi-firewall" "$DPI_NFT_FILE"; do
    [[ ! -e "$path" && ! -L "$path" ]] || return 0
  done
  # A bare (possibly empty) $DPI_DIR is not an artifact: reconciliation recreates
  # it, so treating its mere existence as "present" made every later `dpi stock`
  # on a DPI-free host run a full reconcile.
  [[ -L "$DPI_DIR" ]] && return 0
  [[ -s "$DPI_NFT_FILE" ]] && return 0
  [[ -d "$DPI_STATE_DIR" ]] \
    && [[ -n "$(find "$DPI_STATE_DIR" -maxdepth 1 -type f -name '*.env' -print -quit 2>/dev/null)" ]] \
    && return 0
  [[ -f "$SYSTEMD_DIR/$DPI_FIREWALL_UNIT" || -f "$SYSTEMD_DIR/$DPI_NFQWS_UNIT" ]] && return 0
  [[ -f "$LIBEXEC_DIR/apply-dpi-firewall" ]] && return 0
  dpi_runtime_units_inactive || return 0
  [[ -x "$DPI_NFT_BIN" ]] && "$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE" >/dev/null 2>&1 && return 0
  return 1
}

# With no scope state left at all, no manager-owned DPI unit may still be
# active. While other scopes remain, their runtime is expected to stay up and
# dpi_reconcile_runtime has already verified it.
dpi_stock_postcondition_ok() {
  local remaining=0 path tables
  if [[ -d "$DPI_STATE_DIR" ]]; then
    remaining="$(find "$DPI_STATE_DIR" -maxdepth 1 -type f -name '*.env' -print | wc -l)"
  fi
  (( remaining > 0 )) && return 0
  dpi_runtime_units_inactive || return 1
  for path in "$DPI_NFQWS_BIN" "$DPI_NFQWS_SUM_FILE" "$DPI_DOC_DIR/nfqws-LICENSE.txt" \
    "$SYSTEMD_DIR/$DPI_FIREWALL_UNIT" "$SYSTEMD_DIR/$DPI_NFQWS_UNIT" \
    "$LIBEXEC_DIR/apply-dpi-firewall" "$DPI_NFT_FILE"; do
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
  done
  # A failed list-table call is not proof of absence (EPERM/netlink failure).
  tables="$("$DPI_NFT_BIN" -j list tables ip 2>/dev/null)" || return 1
  jq -e --arg name "$DPI_NFT_TABLE" '
    (.nftables | type == "array") and
    all(.nftables[]; if has("metainfo") then true
      elif has("table") then (.table.family == "ip" and .table.name != $name)
      else false end)' <<< "$tables" >/dev/null
}

# `dpi disable|stock HOST` for a host that owns no scope.
#
# 0.2.9 returned success here without looking at the runtime at all, which is
# how a real VPS ended up reporting STOCK while twebproxy-dpi-firewall.service
# was still active with nothing behind it.
#
# Reconciliation is driven by the authoritative state directory, never by this
# host: other configured scopes keep their state, their rules and their running
# units, and the manager-owned runtime is torn down only when no scope remains.
# It is never an unconditional global stop/delete, and success is reported only
# after the postcondition holds.
dpi_disable_reconcile_stock() {
  local host="$1"
  if dpi_runtime_artifacts_present; then
    dpi_reconcile_runtime || die "$(dpi_transaction_failure_message)"
  fi
  dpi_stock_postcondition_ok || die "$(dpi_transaction_failure_message)"
  ok "$(ui_msgf dpi_disabled "$host")"
}

# Is a stored scope still owned by a configured hostname?
#
#   0 = proven orphan - resolution worked and no configured host maps here
#   1 = still owned by a configured host
#   2 = cannot be determined right now
#
# The distinction is the whole point. dpi_hosts_for_ipv4 answers "empty" both
# for a genuine orphan and for a resolver that could not answer at all, and the
# caller used to delete the scope either way: a transient SERVFAIL, an
# unreachable resolver or an ambiguous multi-address answer destroyed state the
# operator had deliberately configured. A failure to prove ownership is not
# proof of the opposite.
#
# With no configured instances at all the loop body never runs and the verdict
# is a proven orphan - nothing can own a scope when nothing is configured, and
# that conclusion needs no resolver.
# Every valid IPv4 the resolver returns for a host, one per line. Non-zero only
# when the resolver could not answer at all: an answer carrying several
# addresses is data, not a failure. dpi_resolve_ipv4 deliberately refuses a
# multi-address answer because activation needs exactly one address; ownership
# is a different question and must not inherit that refusal, or a single
# permanently multi-homed hostname would freeze pruning for every scope.
dpi_resolved_ipv4_set() {
  local host="$1" ip found=0
  while read -r ip; do
    dpi_ipv4_valid "$ip" || continue
    printf '%s\n' "$ip"; found=1
  done < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
  (( found ))
}

# $2 is the hostname recorded in the scope file - the host that asked for this
# scope in the first place.
dpi_scope_orphan_status() {
  local ip="$1" recorded="${2:-}" host addrs addr
  local seen=0 resolver_ok=0 recorded_unresolved=0
  while read -r host; do
    [[ -n "$host" ]] || continue
    seen=1
    if addrs="$(dpi_resolved_ipv4_set "$host")"; then
      resolver_ok=1
      # A host that resolved is a definite answer about this address, whether it
      # returned one address or several.
      while IFS= read -r addr; do
        [[ "$addr" == "$ip" ]] && return 1
      done <<< "$addrs"
    elif [[ -n "$recorded" && "$host" == "$recorded" ]]; then
      recorded_unresolved=1
    fi
  done < <(list_hosts_array)

  # Nothing is configured: nothing can own this scope, and no resolver is needed
  # to say so.
  (( seen )) || return 0
  # Not one configured host resolved - that is a resolver outage, not evidence.
  (( resolver_ok )) || return 2
  # The resolver is answering, but the host that wrote this scope is not
  # answering right now (propagation, a briefly missing record). Its own mapping
  # cannot be checked, so its intent must not be destroyed.
  (( recorded_unresolved == 0 )) || return 2
  # The resolver works, the recording host was checkable, and no configured host
  # claims this address.
  return 0
}

dpi_prune_orphan_state() {
  local file rc
  [[ -d "$DPI_STATE_DIR" ]] || return 0
  while IFS= read -r file; do
    dpi_load_scope_file "$file" || { warn "Unsafe DPI state: $file"; return 1; }
    rc=0; dpi_scope_orphan_status "$DPI_SCOPE_IPV4" "$DPI_SCOPE_HOST" || rc=$?
    case "$rc" in
      0) # One unremovable file must not abort the sweep: dpi_repair_all turns a
         # non-zero return here into `rm -rf $DPI_DIR` plus a forced STOCK for
         # EVERY scope, which is far more destructive than the leftover.
         rm -f -- "$file" || {
           warn "$(ui_msgf dpi_prune_unverifiable "$DPI_SCOPE_IPV4")"
           dpi_diag_log "stage=prune orphan state op=rm status=1 result=failed reason=orphaned scope file $file could not be removed"
         };;
      1) ;;
      *) warn "$(ui_msgf dpi_prune_unverifiable "$DPI_SCOPE_IPV4")"
         dpi_diag_log "stage=prune orphan state op=dpi_scope_orphan_status status=2 result=skipped reason=address ownership for $DPI_SCOPE_IPV4 could not be determined; state preserved";;
    esac
  done < <(find "$DPI_STATE_DIR" -maxdepth 1 -type f -name '*.env' -print | sort)
}

dpi_repair_all() {
  [[ -d "$DPI_STATE_DIR" ]] || return 0
  if ! dpi_prune_orphan_state || ! dpi_reconcile_runtime; then
    warn "$(ui_msg dpi_repair_warning)"
    dpi_diag_log "stage=${DPI_LAST_STAGE:-repair} op=dpi_repair_all status=${DPI_LAST_STAGE_RC:-1} result=failed reason=${DPI_LAST_STAGE_REASON:-repair could not reconcile DPI state} rollback=forced-to-STOCK"
    rm -rf "$DPI_DIR"
    dpi_cleanup_stock_runtime || true
    return 1
  fi
}

dpi_remove_host_state_if_orphaned() {
  local old_ip="$1" rc=0
  [[ -n "$old_ip" ]] || return 0
  # Same three-way verdict as the prune path: this address may still be owned by
  # another configured hostname, and a resolver that cannot answer must not be
  # read as "nobody owns it".
  local recorded=""
  if dpi_load_scope_file "$(dpi_state_path "$DPI_STATE_DIR" "$old_ip")" 2>/dev/null; then
    recorded="$DPI_SCOPE_HOST"
  fi
  dpi_scope_orphan_status "$old_ip" "$recorded" || rc=$?
  case "$rc" in
    0) rm -f -- "$(dpi_state_path "$DPI_STATE_DIR" "$old_ip")" \
         || dpi_diag_log "stage=prune orphan state op=rm status=1 result=failed reason=orphaned scope file for $old_ip could not be removed";;
    1) ;;
    *) warn "$(ui_msgf dpi_prune_unverifiable "$old_ip")"
       dpi_diag_log "stage=prune orphan state op=dpi_remove_host_state_if_orphaned status=2 result=skipped reason=address ownership for $old_ip could not be determined; state preserved";;
  esac
  dpi_reconcile_runtime
}

dpi_collect_host_check() {
  local host="$1" row ip mode status=DISABLED message="STOCK; no traffic modification" rules="" actual=""
  row="$(dpi_mode_for_host "$host" || true)"; ip="${row%%$'\t'*}"; mode="${row#*$'\t'}"
  if [[ "$ip" == unresolved ]]; then
    tcore_add_check "anti_dpi.mode" DISABLED info "hostname:$host" dns "STOCK@unresolved" STOCK \
      "STOCK mode; no compatibility state requires a resolved IPv4 scope" none
    return
  fi
  if [[ "$mode" != STOCK ]]; then
    status=OK; message="Opt-in compatibility mode is address-scoped; IPv6 remains STOCK"
    rules="$("$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE" 2>/dev/null || true)"
    # Errexit-safe capture (see dpi_set_cmd): a bare call would abort the whole
    # status/audit collection instead of recording the ERROR.
    local scope_rc=0
    dpi_scope_locally_configured "$ip" || scope_rc=$?
    case "$scope_rc" in
      1) status=ERROR
         message="Configured scope $ip is not on any local interface, so the rule cannot match outgoing packets (external 1:1 NAT?)";;
      2) status=ERROR
         message="Locally configured IPv4 addresses could not be determined, so scope $ip cannot be confirmed as matchable";;
    esac
    if [[ "$status" == ERROR ]]; then :
    elif [[ -z "$rules" || "$rules" != *"$ip"* ]]; then
      status=ERROR; message="Configured compatibility scope is missing from the live nftables table"
    elif dpi_mode_uses_nfqws "$mode"; then
      actual="$(sha256sum "$DPI_NFQWS_BIN" 2>/dev/null | awk '{print $1}')"
      if [[ "$actual" != "$DPI_NFQWS_SHA256" ]] || ! systemctl is-active --quiet "$DPI_NFQWS_UNIT"; then
        status=ERROR; message="Pinned nfqws binary or service does not match the configured mode"
      fi
    fi
  fi
  tcore_add_check "anti_dpi.mode" "$status" "$([[ "$status" == ERROR ]] && printf critical || printf info)" \
    "hostname:$host" configuration "$mode@$ip" STOCK "$message" none
}

dpi_full_uninstall() {
  rm -rf "$DPI_DIR"
  # Best effort: uninstall must continue even if a unit refuses to go away, but
  # the residual state is recorded in the transcript.
  dpi_cleanup_stock_runtime || true
  rm -f "$DPI_DOC_DIR/nfqws-LICENSE.txt"
}

dpi_cmd() {
  local sub="${1:-status}"; shift || true
  case "$sub" in
    status) dpi_status_cmd "${1:-}";;
    list-methods|methods) dpi_list_methods_cmd;;
    set) dpi_set_cmd "${1:-}" "${2:-}" "${3:-}";;
    disable|stock) dpi_disable_cmd "${1:-}";;
    *) die "Usage: twebproxy dpi {status [HOST]|list-methods|set HOST MODE [--accept-shared-scope]|disable HOST}";;
  esac
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

# --- procfs policy (v0.2.23, P1-INHERITED-01) --------------------------------
# Stock MTProxy takes the client secret as "-S <secret>", and /proc/<pid>/cmdline
# is readable by every local account unless procfs is mounted with hidepid.
# A service's own ProtectProc= only changes that service's view of /proc, so the
# supported mitigation is host-wide: hidepid=invisible, with an exempt group for
# tools that must see all processes, persisted in /etc/fstab (applied to /proc
# at boot by systemd-remount-fs). The operator may opt out explicitly
# ("twebproxy proc-hardening disable"); the audit then reports an accepted risk.
proc_top_mount_options() { # options of the EFFECTIVE (topmost) /proc mount of this mount namespace
  # Stacked proc mounts list several /proc lines in mountinfo; only the one no
  # other /proc mount sits on is what path lookups reach (v0.2.24, P2-PROC-MULTIMOUNT).
  # Prints "<mount options>,<super options>"; nothing if /proc is not mounted.
  awk '{ sep = 0; for (i = 7; i <= NF; i++) if ($i == "-") { sep = i; break } }
       sep && $5 == "/proc" && $(sep + 1) == "proc" { id[$1] = 1; par[$1] = $2; opt[$1] = $6 "," $(sep + 3) }
       END { for (i in id) { top = 1; for (j in id) if (par[j] == i) top = 0; if (top) print opt[i] } }' \
    /proc/self/mountinfo 2>/dev/null | head -n1
}

proc_hidepid_value() { # prints the hidepid value of the effective /proc, or nothing; never fails (callers run under errexit/ERR)
  local opts="" v=""
  opts="$(proc_top_mount_options)" || opts=""
  [[ "$opts" =~ (^|,)hidepid=([a-z0-9]+) ]] && v="${BASH_REMATCH[2]}"
  printf '%s' "$v"
}

# Ground truth, independent of how options are spelled: can an unprivileged
# account (nobody, no supplementary groups) read another user's command line
# through the effective /proc of this mount namespace? PID 1 stands for every
# process of another user, the MTProxy backends included.
# Succeeds (= "exposed") also when the probe itself cannot run: its own
# command line must be readable first, otherwise the answer is unknown.
proc_unprivileged_can_read() {
  local rc=0
  setpriv --reuid=65534 --regid=65534 --clear-groups --inh-caps=-all --bounding-set=-all \
    bash -c 'IFS= read -r -d "" s < /proc/self/cmdline || exit 3
             IFS= read -r -d "" a < /proc/1/cmdline && exit 0; exit 1' >/dev/null 2>&1 || rc=$?
  (( rc != 1 ))
}

proc_hide_active() { # hidepid on the effective /proc AND an unprivileged reader really sees nothing
  case "$(proc_hidepid_value)" in 1|2|noaccess|invisible) ;; *) return 1;; esac
  ! proc_unprivileged_can_read
}

# --- Backend socket filter checks (v0.2.24, P1-EXPOSURE-01) -------------------
ip4_to_int() { local IFS=. a b c d; read -r a b c d <<<"$1"; printf '%s' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"; }

ip4_in_dc_cidrs() { # $1=IPv4 -> success if inside one of TELEGRAM_DC_CIDRS
  local cidr net len mask ip
  ip="$(ip4_to_int "$1")"
  for cidr in $TELEGRAM_DC_CIDRS; do
    [[ "$cidr" == *.* ]] || continue
    net="${cidr%/*}"; len="${cidr#*/}"
    mask=$(( len == 0 ? 0 : (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
    (( (ip & mask) == ($(ip4_to_int "$net") & mask) )) && return 0
  done
  return 1
}

# Prints proxy_for IPv4 addresses of the MTProxy routing config outside the
# allowed DC networks (those DCs would be unreachable for the backends).
dc_addresses_outside_allowlist() {
  local f="$MTPROXY_DATA_DIR/proxy-multi.conf" a
  [[ -r "$f" ]] || return 1
  while read -r a; do
    ip4_in_dc_cidrs "$a" || printf '%s\n' "$a"
  done < <(sed -nE 's/^proxy_for[[:space:]]+-?[0-9]+[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):[0-9]+;.*/\1/p' "$f" | sort -u)
}

# 0 = the backend cgroup filter is in effect for $1 (unit) and a connection to
# port $2 through this host's own non-loopback IPv4 does not get through
# (local traffic bypasses the nftables iifname != lo rule, so only the cgroup
# filter can stop it); 1 = missing or bypassed; 2 = systemd did not answer
# (bounded like every audit probe). Prints the observed evidence.
backend_socket_filter_check() {
  local unit="$1" port="$2" out="" load="" deny="" bytes="" ip
  out="$(diag_run "$DIAG_TIMEOUT" systemctl show -p LoadState -p IPAddressDeny -p IPIngressBytes -- "$unit" 2>/dev/null)" ||
    { printf 'unknown'; return 2; }
  load="$(sed -n 's/^LoadState=//p' <<<"$out")"
  deny="$(sed -n 's/^IPAddressDeny=//p' <<<"$out")"
  bytes="$(sed -n 's/^IPIngressBytes=//p' <<<"$out")"
  [[ "$load" == loaded ]] || { printf 'unknown'; return 2; }
  if [[ " $deny " != *" 0.0.0.0/0 "* || " $deny " != *" ::/0 "* || ! "$bytes" =~ ^[0-9]+$ ]]; then
    printf 'filter-missing'; return 1
  fi
  ip="$(diag_run "$DIAG_TIMEOUT" ip -4 -o addr show scope global 2>/dev/null | awk '{sub("/.*", "", $4); print $4; exit}')" || ip=""
  if [[ -n "$ip" ]] && timeout 1 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$ip" "$port" 2>/dev/null; then
    printf 'bypassed-via-%s' "$ip"; return 1
  fi
  printf 'enforced'
}

proc_hardening_state() { # hidden | disabled | exposed
  if proc_hide_active; then printf 'hidden'
  elif [[ -f "$PROC_POLICY_FILE" && "$(head -n1 "$PROC_POLICY_FILE" 2>/dev/null)" == off ]]; then printf 'disabled'
  else printf 'exposed'; fi
}

proc_fstab_line() { printf 'proc /proc proc defaults,nosuid,nodev,noexec,relatime,hidepid=invisible,gid=%s 0 0 %s\n' "$1" "$PROC_FSTAB_MARK"; }

proc_fstab_write() { # $1 = line to install, or empty to remove ours; other proc lines are kept commented
  local tmp fstab=/etc/fstab
  [[ -f "$fstab" && ! -L "$fstab" ]] || { printf '%s is not a regular file' "$fstab"; return 1; }
  [[ -f "$fstab.twebproxy-backup" ]] || cp -p -- "$fstab" "$fstab.twebproxy-backup" || return 1
  tmp="$(mktemp /etc/.fstab.twebproxy.XXXXXX)" || return 1
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == *"$PROC_FSTAB_MARK"* ]]; then continue; fi
      if [[ -n "$1" && "$line" =~ ^[[:space:]]*[^#[:space:]]+[[:space:]]+/proc[[:space:]] ]]; then
        printf '# %s (disabled by TWebProxy proc-hardening)\n' "$line"; continue
      fi
      printf '%s\n' "$line"
    done < "$fstab"
    [[ -z "$1" ]] || printf '%s' "$1"
  } > "$tmp" && chmod --reference="$fstab" "$tmp" && mv -fT -- "$tmp" "$fstab" || { rm -f -- "$tmp"; return 1; }
}

proc_hardening_enable() {
  local gid
  getent group "$PROC_GROUP" >/dev/null || groupadd --system "$PROC_GROUP" || { printf 'groupadd %s failed' "$PROC_GROUP"; return 1; }
  gid="$(getent group "$PROC_GROUP" | cut -d: -f3)"
  [[ "$gid" =~ ^[0-9]+$ ]] || { printf 'no gid for %s' "$PROC_GROUP"; return 1; }
  proc_fstab_write "$(proc_fstab_line "$gid")" || { printf 'could not update /etc/fstab'; return 1; }
  mount -o "remount,hidepid=invisible,gid=$gid" /proc || { printf 'remount of /proc failed'; return 1; }
  proc_hide_active || { printf '/proc still shows every process after remount'; return 1; }
  install -d -m 0700 "$BASE_DIR" && printf 'hidepid\n' > "$PROC_POLICY_FILE" && chmod 0600 "$PROC_POLICY_FILE"
}

proc_hardening_disable() {
  # The decision is recorded first: it is what makes an exposed /proc an
  # accepted (WARNING) instead of an unintended (fail-closed) state.
  install -d -m 0700 "$BASE_DIR" &&
    printf 'off\naccepted_at=%s\naccepted_by=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SUDO_USER:-$(id -un)}" > "$PROC_POLICY_FILE" &&
    chmod 0600 "$PROC_POLICY_FILE" || { printf 'could not record the policy in %s' "$PROC_POLICY_FILE"; return 1; }
  proc_fstab_write "" || { printf 'could not update /etc/fstab'; return 1; }
  if [[ -f /etc/fstab.twebproxy-backup ]] && grep -qE '^[[:space:]]*#[[:space:]].*[[:space:]]/proc[[:space:]].*\(disabled by TWebProxy' /etc/fstab; then
    sed -i -E 's/^# (.*) \(disabled by TWebProxy proc-hardening\)$/\1/' /etc/fstab || return 1
  fi
  mount -o remount,hidepid=0 /proc 2>/dev/null || mount -o remount,hidepid=default /proc || { printf 'remount of /proc failed'; return 1; }
}

# MTProxy backends may run only while the effective /proc hides their command
# lines or the operator explicitly accepted the risk (v0.2.24, P1-INHERITED-01).
proc_secret_safe() { case "$(proc_hardening_state)" in hidden|disabled) return 0;; *) return 1;; esac; }

# An unintentionally exposed /proc must not coexist with live secret-bearing
# backends: stop every TWebProxy backend, prove it stopped, and abort.
proc_fail_closed() {
  local units=() u failed=""
  mapfile -t units < <(systemctl list-units --type=service --all --no-legend --plain 'twebproxy-mtproxy@*.service' 2>/dev/null | awk 'NF {print $1}')
  for u in "${units[@]}"; do
    systemctl stop "$u" >/dev/null 2>&1 || true
    case "$(systemctl is-active "$u" 2>/dev/null || true)" in inactive|failed) ;; *) failed+=" $u";; esac
  done
  [[ -z "$failed" ]] || die "$(ui_msgf proc_fail_closed_stop_failed "$failed")"
  die "$(ui_msgf proc_fail_closed "${#units[@]}")"
}

# Default on: applied by core-install, add and repair (before any backend
# starts) unless the operator opted out; callers fail closed when it fails.
proc_hardening_ensure() {
  local err
  [[ "$(proc_hardening_state)" == disabled ]] && return 0
  if proc_hide_active && grep -qF "$PROC_FSTAB_MARK" /etc/fstab 2>/dev/null; then return 0; fi
  if err="$(proc_hardening_enable 2>&1)"; then
    ok "$(ui_msgf proc_enabled "$PROC_GROUP")"; log "$(ui_msgf proc_note_group "$PROC_GROUP")"
  else
    warn "$(ui_msgf proc_failed "$err")"; return 1
  fi
}

proc_hardening_cmd() {
  need_root
  local action="${1:-status}" err
  case "$action" in
    status)
      case "$(proc_hardening_state)" in
        hidden) ok "$(ui_msgf proc_status_hidden "$(proc_hidepid_value)")";;
        disabled) warn "$(ui_msg proc_status_disabled)";;
        *) warn "$(ui_msg proc_status_exposed)"; return 1;;
      esac;;
    enable)
      err="$(proc_hardening_enable 2>&1)" || die "$(ui_msgf proc_failed "$err")"
      ok "$(ui_msgf proc_enabled "$PROC_GROUP")"; log "$(ui_msgf proc_note_group "$PROC_GROUP")";;
    disable)
      # Deliberate: an interactive operator confirms; a non-interactive call
      # of this explicit command is itself the decision. Both are recorded.
      if [[ -t 0 ]] && ! yesno "$(ui_msg proc_disable_confirm)" n; then
        log "$(ui_msg proc_disable_declined)"; return 1
      fi
      err="$(proc_hardening_disable 2>&1)" || die "$(ui_msgf proc_failed "$err")"
      warn "$(ui_msg proc_disabled)"; warn "$(ui_msgf proc_disable_recorded "$PROC_POLICY_FILE")";;
    *) die "Usage: twebproxy proc-hardening [status|enable|disable]";;
  esac
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
  if ! relay_binary_install "$tmpbin"; then
    rm -f "$tmpbin"
    die "Не удалось установить tproxy-server; прежний binary не изменён."
  fi
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

download_telegram_material() { # official HTTPS, bounded IPv4 retries; no insecure fallback
  local url="$1" output="$2"
  case "$url" in https://core.telegram.org/getProxySecret|https://core.telegram.org/getProxyConfig) ;; *) return 1;; esac
  curl -4 --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 8 --max-time 20 --retry 3 --retry-all-errors --retry-delay 2 --retry-max-time 75 \
    --max-filesize 65536 --output "$output" "$url"
}

refresh_mtproxy_material() (
  log "Получаю официальный proxy-secret и proxy-multi.conf..."
  local work name rollback_ok=1
  work="$(mktemp -d "$MTPROXY_DATA_DIR/.refresh.XXXXXX")" || return 1
  trap 'rm -rf -- "$work"' EXIT
  download_telegram_material https://core.telegram.org/getProxySecret "$work/secret" || return 1
  download_telegram_material https://core.telegram.org/getProxyConfig "$work/config" || return 1
  [[ "$(wc -c < "$work/secret")" -ge 100 && "$(wc -c < "$work/secret")" -le 4096 ]] || return 1
  [[ "$(wc -c < "$work/config")" -ge 100 && "$(wc -c < "$work/config")" -le 65536 ]] || return 1
  grep -q '^default ' "$work/config" && grep -q '^proxy_for ' "$work/config" || return 1
  chmod 0600 "$work/secret" "$work/config"
  for name in proxy-secret proxy-multi.conf; do
    [[ ! -L "$MTPROXY_DATA_DIR/$name" ]] || return 1
    if [[ -e "$MTPROXY_DATA_DIR/$name" ]]; then cp -p -- "$MTPROXY_DATA_DIR/$name" "$work/old-$name" || return 1; fi
  done
  if ! mv -fT -- "$work/secret" "$MTPROXY_DATA_DIR/proxy-secret"; then return 1; fi
  if ! mv -fT -- "$work/config" "$MTPROXY_DATA_DIR/proxy-multi.conf"; then
    if [[ -e "$work/old-proxy-secret" ]]; then
      mv -fT -- "$work/old-proxy-secret" "$MTPROXY_DATA_DIR/proxy-secret" || rollback_ok=0
    else rm -f -- "$MTPROXY_DATA_DIR/proxy-secret" || rollback_ok=0; fi
    (( rollback_ok )) || warn "Telegram material rollback incomplete; inspect $MTPROXY_DATA_DIR before restarting backends."
    return 1
  fi
)

write_global_env() {
  local upstream="${UPSTREAM_COMMIT:-}"
  if [[ -z "$upstream" && -f "$GLOBAL_ENV" ]]; then
    upstream="$( (unset TPROXY_UPSTREAM_COMMIT; source "$GLOBAL_ENV"; printf '%s' "${TPROXY_UPSTREAM_COMMIT:-}") )"
  fi
  [[ -n "$upstream" ]] || upstream=unknown
  # Written beside itself and renamed: never truncated in place, and a write
  # obstruction (immutable, read-only, full) is reported as such.
  local tmp
  if tmp="$(mktemp "$(dirname -- "$GLOBAL_ENV")/.global.env.XXXXXX" 2>/dev/null)" &&
     {
       printf 'MANAGER_VERSION=%q\n' "$MANAGER_VERSION"
       printf 'TPROXY_UPSTREAM_COMMIT=%q\n' "$upstream"
       printf 'MTPROXY_COMMIT=%q\n' "$MTPROXY_COMMIT"
     } > "$tmp" && chmod 0600 "$tmp" && mv -fT -- "$tmp" "$GLOBAL_ENV" 2>/dev/null; then
    return 0
  fi
  [[ -z "${tmp:-}" ]] || rm -f -- "$tmp"
  die "$(ui_msgf global_env_write_failed "$GLOBAL_ENV" "$GLOBAL_ENV")"
}

backend_fw_error() { printf 'backend firewall: %s\n' "$*" >&2; }

backend_fw_render() {
  printf 'table inet twebproxy_backend {\n  chain input {\n    type filter hook input priority -5; policy accept;\n' || return 1
  if [[ -n "$1" ]]; then
    printf '    iifname != "lo" tcp dport { %s } drop\n' "$1" || return 1
  fi
  printf '  }\n}\n'
}

backend_fw_collect() {
  local f pair client stats ports=()
  # Import each backend in its own subshell. No inheritance from the preceding
  # backend, and no change to the manager's glob options.
  for f in "$BF_BACKENDS"/*.env; do
    [[ -e "$f" || -L "$f" ]] || continue
    [[ -f "$f" && ! -L "$f" ]] || { backend_fw_error "unsafe backend state: $f"; return 1; }
    pair="$(
      unset MTPROXY_CLIENT_PORT MTPROXY_STATS_PORT
      source "$f" >/dev/null 2>&1 || exit 1
      [[ -n "${MTPROXY_CLIENT_PORT:-}" && -n "${MTPROXY_STATS_PORT:-}" ]] || exit 1
      printf '%s %s' "$MTPROXY_CLIENT_PORT" "$MTPROXY_STATS_PORT"
    )" || { backend_fw_error "invalid backend state: $f"; return 1; }
    client="${pair%% *}"; stats="${pair##* }"
    if ! is_valid_port "$client" || ! is_valid_port "$stats"; then
      backend_fw_error "invalid backend state: $f"; return 1
    fi
    ports+=("$((10#$client))" "$((10#$stats))")
  done
  if (( ${#ports[@]} )); then
    printf '%s\n' "${ports[@]}" | sort -nu | paste -sd, - || return 1
  fi
  return 0
}

# Accept only the finite manager-owned table shape, not substring matches or
# arbitrary nft objects. Numeric JSON avoids service/priority name ambiguity.
# libnftables may include an explicit TCP protocol dependency; accept exactly it.
backend_fw_ports_json() {
  jq -er '
    def must($p): if $p then . else error("unexpected backend table shape") end;
    def port: type == "number" and floor == . and . >= 1 and . <= 65535;
    def portlist:
      if type == "number" then [.] else
        if type == "object" and keys == ["set"] and (.set|type) == "array"
        then .set else error("invalid port set") end
      end
      | must(length > 0 and all(.[]; port)) | sort | unique;
    .nftables | must(type == "array")
    | map(select(has("metainfo")|not))
    | must(all(.[]; keys == ["table"] or keys == ["chain"] or keys == ["rule"]))
    | . as $all
    | [.[]|.table? // empty] as $t
    | [$all[]|.chain? // empty] as $c
    | [$all[]|.rule? // empty] as $r
    | must(($t|length)==1 and ($c|length)==1 and ($r|length)<=1)
    | must($t[0].family=="inet" and $t[0].name=="twebproxy_backend"
        and (($t[0].flags // [])|length)==0)
    | must($c[0].family=="inet" and $c[0].table=="twebproxy_backend"
        and $c[0].name=="input" and $c[0].type=="filter"
        and $c[0].hook=="input" and $c[0].prio == -5
        and $c[0].policy=="accept")
    | if ($r|length)==0 then "" else
        $r[0] | must(.family=="inet" and .table=="twebproxy_backend" and .chain=="input")
        | .expr | must(type=="array" and (length==3 or length==4))
        | must(.[-1]=={"drop":null})
        | .[0:-1] as $matches
        | must(all($matches[]; keys==["match"]))
        | [$matches[]|.match|select(.op=="!=" and .left=={"meta":{"key":"iifname"}} and .right=="lo")] as $if
        | [$matches[]|.match|select(.op=="==" and .left=={"payload":{"protocol":"tcp","field":"dport"}})] as $dp
        | [$matches[]|.match|select(.op=="==" and .left=={"meta":{"key":"l4proto"}} and (.right=="tcp" or .right==6))] as $tcp
        | must(($if|length)==1 and ($dp|length)==1 and ($tcp|length)==($matches|length)-2)
        | $dp[0].right | portlist | map(tostring) | join(",")
      end
  ' "$1"
}

backend_fw_live_ports() {
  timeout 30 "$BF_NFT" -j -n list table inet twebproxy_backend > "$1" || return 1
  backend_fw_ports_json "$1"
}

backend_fw_batch() {
  # "add", unlike "create", is idempotent on existing tables. In ONE batch,
  # add/delete/recreate handles both initial absence and replacement. No live
  # mutation precedes the final nft -f. Requires nft transaction semantics.
  {
    printf 'add table inet twebproxy_backend\ndelete table inet twebproxy_backend\n' &&
      cat -- "$1"
  } > "$2"
}

backend_fw_restore() {
  local actual
  if [[ "$1" == yes ]]; then
    if timeout 30 "$BF_NFT" -f "$2" &&
        actual="$(backend_fw_live_ports "$3")" && [[ "$actual" == "$4" ]]; then
      backend_fw_error 'operation failed; previous live isolation restored'
    else
      backend_fw_error 'RESTORE FAILED: inspect live twebproxy_backend; canonical file was not published'
    fi
  else
    # Restoring absence would open the ports. Retain the new isolation instead.
    backend_fw_error 'operation failed; retaining applied isolation (no previous table); retry rebuild'
  fi
  return 1
}

# The kernel applies the batch atomically, but the nft client can still fail
# after the commit (e.g. killed by timeout). Say what the kernel holds and
# converge like the other failure paths. The caller always returns failure.
backend_fw_apply_failed() {
  local rc="$1" present="$2" work="$3" ports="$4" old_ports="$5" live
  if live="$(backend_fw_live_ports "$work/failed.json")"; then
    if [[ "$present" == yes && "$live" == "$old_ports" ]]; then
      backend_fw_error "nft apply failed (rc=$rc); previous live isolation unchanged"
      return 1
    fi
    if [[ "$live" == "$ports" ]]; then
      backend_fw_error "nft apply reported failure (rc=$rc) after the kernel committed the new rules"
      backend_fw_restore "$present" "$work/rollback" "$work/restored.json" "$old_ports"
      return 1
    fi
  elif [[ "$present" == no ]] &&
      timeout 30 "$BF_NFT" -j list tables inet > "$work/failed-tables.json" &&
      jq -e '.nftables|type=="array" and all(.[]; (.table.family=="inet" and .table.name=="twebproxy_backend")|not)' \
        "$work/failed-tables.json" >/dev/null; then
    backend_fw_error "nft apply failed (rc=$rc); no table was installed"
    return 1
  fi
  backend_fw_error "RESTORE FAILED: nft apply failed (rc=$rc) and the live twebproxy_backend state is unknown; inspect it; canonical file was not published"
  return 1
}

backend_fw_transaction() {
  local work="$1" ports old_ports='' present=no actual content bytes
  [[ ! -L "$BF_FILE" && ( ! -e "$BF_FILE" || -f "$BF_FILE" ) ]] ||
    { backend_fw_error "unsafe canonical path: $BF_FILE"; return 1; }
  [[ -d "$BF_BACKENDS" && ! -L "$BF_BACKENDS" ]] ||
    { backend_fw_error "backend directory unavailable: $BF_BACKENDS"; return 1; }
  ports="$(backend_fw_collect)" || return 1
  content="$(backend_fw_render "$ports")" || return 1
  printf '%s\n' "$content" > "$work/candidate" || return 1
  chmod 0600 "$work/candidate" || return 1
  [[ "$(stat -c '%u:%g:%a' "$work/candidate")" == 0:0:600 ]] || return 1
  actual="$(cat -- "$work/candidate")" || return 1
  bytes="$(wc -c < "$work/candidate")" || return 1
  [[ "$actual" == "$content" && "$bytes" -eq ${#content}+1 ]] || return 1
  backend_fw_batch "$work/candidate" "$work/batch" || return 1
  timeout 30 "$BF_NFT" -j list tables inet > "$work/tables.json" || return 1
  jq -e '.nftables|type=="array"' "$work/tables.json" >/dev/null || return 1
  if jq -e 'any(.nftables[]; .table.family=="inet" and .table.name=="twebproxy_backend")' "$work/tables.json" >/dev/null; then
    present=yes
    old_ports="$(backend_fw_live_ports "$work/old.json")" ||
      { backend_fw_error 'existing reserved table has unexpected contents; refusing replacement'; return 1; }
    backend_fw_render "$old_ports" > "$work/previous" || return 1
    backend_fw_batch "$work/previous" "$work/rollback" || return 1
  fi
  timeout 30 "$BF_NFT" -c -f "$work/batch" || return 1
  timeout 30 "$BF_NFT" -f "$work/batch" ||
    { backend_fw_apply_failed "$?" "$present" "$work" "$ports" "$old_ports"; return 1; }
  if ! actual="$(backend_fw_live_ports "$work/live.json")" || [[ "$actual" != "$ports" ]]; then
    backend_fw_error 'live verification failed'
    backend_fw_restore "$present" "$work/rollback" "$work/restored.json" "$old_ports"
    return 1
  fi
  # Kernel and filesystem cannot commit atomically. Kernel first: no publication
  # can claim success for unapplied rules. On a rename error restore old live
  # rules if available, otherwise retain new protection and report failure.
  if ! mv -fT -- "$work/candidate" "$BF_FILE"; then
    backend_fw_error "canonical publication failed: $BF_FILE"
    backend_fw_restore "$present" "$work/rollback" "$work/restored.json" "$old_ports"
    return 1
  fi
  return 0
}

backend_fw_main() (
  set -Eeuo pipefail
  export LC_ALL=C
  umask 077
  (( $# == 0 )) || { backend_fw_error 'no arguments supported'; exit 1; }
  [[ -d "$BF_BASE" && ! -L "$BF_BASE" && "$(stat -c '%u:%g:%a' "$BF_BASE")" == 0:0:700 ]] ||
    { backend_fw_error 'unsafe backend state directory'; exit 1; }
  [[ ! -L "$BF_BASE/.backend-firewall.lock" &&
      ( ! -e "$BF_BASE/.backend-firewall.lock" || -f "$BF_BASE/.backend-firewall.lock" ) ]] || exit 1
  exec 7>"$BF_BASE/.backend-firewall.lock" || exit 1
  flock -x -w 20 7 || { backend_fw_error 'lock timeout'; exit 1; }
  local work
  work="$(mktemp -d "$BF_BASE/.firewall.XXXXXXXX")" || exit 1
  trap 'rc=$?; trap - EXIT; rm -rf -- "$work" || rc=1; exit "$rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Boot/reload always regenerates from backend state, including after a signal
  # between kernel commit and file rename. No recovery journal or stale replay.
  backend_fw_transaction "$work"
)

# --- Owned guard table (v0.2.23, P1-EXPOSURE-01 / P1-STOP-01) -------------
# The backend table above is an ordinary table: any "flush ruleset" - which is
# what nftables.service runs on start, reload, restart and stop with the stock
# /etc/nftables.conf - deletes it, and the backends were reachable until it was
# re-applied. inet twebproxy_guard carries the same drop rule but is created
# with "flags owner" by a long-running nft session of twebproxy-firewall.service.
# The kernel skips owned tables in a foreign flush and refuses foreign
# delete/modify (EPERM); the table disappears only when the owning session ends,
# i.e. when the firewall service stops - and the backends are BindsTo= it, so
# they stop first. All guard changes go through that session as one-line nft
# batches, which the kernel applies as one transaction.
fw_guard_ports_elements() { # $1=comma port list -> " { a, b }" or empty
  [[ -n "$1" ]] || return 0
  printf ' { %s }' "${1//,/, }"
}

fw_guard_batch_create() { # $1=comma port list -> one-line batch
  printf 'add table inet %s { flags owner; } ; add set inet %s ports { type inet_service; } ; ' "$BF_GUARD" "$BF_GUARD"
  printf 'add chain inet %s input { type filter hook input priority -6; policy accept; } ; ' "$BF_GUARD"
  printf 'add rule inet %s input iifname != "lo" tcp dport @ports drop' "$BF_GUARD"
  [[ -z "$1" ]] || printf ' ; add element inet %s ports%s' "$BF_GUARD" "$(fw_guard_ports_elements "$1")"
  printf '\n'
}

fw_guard_batch_update() { # $1=comma port list -> one-line batch (atomic swap of the set)
  printf 'flush set inet %s ports' "$BF_GUARD"
  [[ -z "$1" ]] || printf ' ; add element inet %s ports%s' "$BF_GUARD" "$(fw_guard_ports_elements "$1")"
  printf '\n'
}

fw_guard_live() { # prints the live guard port list; fails unless the owned table and its drop rule exist
  local text json
  text="$(timeout 10 "$BF_NFT" list table inet "$BF_GUARD" 2>/dev/null)" || return 1
  grep -qE '^[[:space:]]*flags owner' <<<"$text" || return 1
  grep -qE 'hook input priority' <<<"$text" || return 1
  grep -qF 'iifname != "lo" tcp dport @ports drop' <<<"$text" || return 1
  json="$(timeout 10 "$BF_NFT" -j list set inet "$BF_GUARD" ports 2>/dev/null)" || return 1
  jq -er '[.nftables[] | select(.set) | (.set.elem // [])[] | numbers] | sort | map(tostring) | join(",")' <<<"$json"
}

fw_guard_wait() { # bounded wait until the kernel guard equals the backend state
  local expected live="" i
  expected="$(backend_fw_collect)" || return 1
  for ((i = 0; i < 100; i++)); do
    if live="$(fw_guard_live)" && [[ "$live" == "$expected" ]]; then return 0; fi
    sleep 0.2
  done
  backend_fw_error "guard: kernel guard does not match backend state (expected '${expected:-none}', live '${live:-absent}')"
  return 1
}

fw_guard_hold() { # runs as the service main process: HUP must reach this shell
  set -Eeuo pipefail
  export LC_ALL=C
  umask 077
  local ports nftpid guard_fd
  FW_GUARD_RELOAD=0
  [[ -d "$BF_BASE" && ! -L "$BF_BASE" && "$(stat -c '%u:%g:%a' "$BF_BASE")" == 0:0:700 ]] ||
    { backend_fw_error 'unsafe backend state directory'; exit 1; }
  exec 8>"$BF_BASE/.firewall-guard.lock"
  flock -n 8 || { backend_fw_error 'guard: another guard session is running'; exit 1; }
  ports="$(backend_fw_collect)" || exit 1
  # nft reads its commands from this pipe; its own output goes to the journal.
  exec {guard_fd}> >(exec "$BF_NFT" -i 8>&-)
  nftpid=$!
  fw_guard_batch_create "$ports" >&"$guard_fd"
  trap 'FW_GUARD_RELOAD=1' HUP
  trap 'exit 0' TERM INT
  while kill -0 "$nftpid" 2>/dev/null; do
    if (( FW_GUARD_RELOAD )); then
      FW_GUARD_RELOAD=0
      if ports="$(backend_fw_collect)"; then
        fw_guard_batch_update "$ports" >&"$guard_fd"
      else
        backend_fw_error 'guard: backend state invalid; the previous guard set is kept'
      fi
    fi
    sleep 1 & wait $! || true
  done
  backend_fw_error 'guard: the owning nft session ended; the guard table is gone'
  exit 1
}

fw_guard_main() {
  case "${1:-}" in
    hold) fw_guard_hold;;
    wait) fw_guard_wait;;
    reload)
      [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { backend_fw_error 'guard: reload needs the guard PID'; return 1; }
      kill -HUP "$2" || { backend_fw_error 'guard: guard session is not running'; return 1; }
      fw_guard_wait;;
    *) backend_fw_error 'usage: firewall-guard {hold|wait|reload PID}'; return 2;;
  esac
}

write_firewall_guard_helper() {
  local tmp nft_bin
  nft_bin="$(command -v nft)" || return 1
  [[ -d "$LIBEXEC_DIR" && ! -L "$LIBEXEC_DIR" ]] || return 1
  [[ ! -L "$LIBEXEC_DIR/firewall-guard" ]] || return 1
  tmp="$(mktemp "$LIBEXEC_DIR/.firewall-guard.XXXXXXXX")" || return 1
  if ! (
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n' || exit 1
    printf 'BF_BASE=%q\nBF_BACKENDS=%q\nBF_NFT=%q\nBF_GUARD=%q\n' "$BASE_DIR" "$BACKENDS_DIR" "$nft_bin" "$FW_GUARD_TABLE" || exit 1
    declare -f is_valid_port backend_fw_error backend_fw_collect fw_guard_ports_elements \
      fw_guard_batch_create fw_guard_batch_update fw_guard_live fw_guard_wait fw_guard_hold fw_guard_main || exit 1
    printf 'fw_guard_main "$@"\n' || exit 1
  ) > "$tmp" || ! chmod 0755 "$tmp" || ! bash -n "$tmp" ||
      ! mv -fT -- "$tmp" "$LIBEXEC_DIR/firewall-guard"; then
    rm -f -- "$tmp"; return 1
  fi
}

# --- Backend start gate (v0.2.24) ---------------------------------------------
# ExecStartPre=+ of every MTProxy backend; runs as root in PID 1's mount
# namespace (the "+" prefix skips the unit's own ProtectProc=/ProtectSystem=).
# Refuses the start unless both kernel-level protections that do not depend on
# any long-running TWebProxy process are in effect for this very unit:
#  1. P1-EXPOSURE-01: PID 1 attached this unit's cgroup socket filter
#     (IPAddressDeny=any + IPAddressAllow=loopback/Telegram DCs): IPAddressDeny
#     covers all of IPv4 and IPv6, and IP accounting - installed by the same
#     cgroup-BPF machinery - reports numbers instead of "[no data]";
#  2. P1-INHERITED-01: the effective /proc hides other users' command lines,
#     unless the operator recorded an explicit opt-out (logged as a warning).
backend_start_check_fail() { printf 'twebproxy backend-start-check: %s; refusing to start\n' "$*" >&2; exit 1; }

backend_start_check_main() {
  local unit="${1:-}" deny bytes
  [[ "$unit" =~ ^twebproxy-mtproxy@[^/[:space:]]+\.service$ ]] || backend_start_check_fail "invalid unit '${unit}'"
  deny="$(systemctl show -P IPAddressDeny -- "$unit" 2>/dev/null)" || backend_start_check_fail "systemd did not answer"
  [[ " $deny " == *" 0.0.0.0/0 "* && " $deny " == *" ::/0 "* ]] ||
    backend_start_check_fail "IPAddressDeny=any is not in effect for $unit (got '${deny}')"
  bytes="$(systemctl show -P IPIngressBytes -- "$unit" 2>/dev/null)" || backend_start_check_fail "systemd did not answer"
  [[ "$bytes" =~ ^[0-9]+$ ]] ||
    backend_start_check_fail "this kernel/systemd does not enforce per-unit IP access lists (IPIngressBytes=${bytes})"
  if proc_hide_active; then
    return 0
  elif [[ -f "$PROC_POLICY_FILE" && "$(head -n1 "$PROC_POLICY_FILE" 2>/dev/null)" == off ]]; then
    printf 'twebproxy backend-start-check: WARNING: procfs hardening disabled by the operator (%s); the client secret of %s is readable by local accounts\n' "$PROC_POLICY_FILE" "$unit" >&2
    return 0
  fi
  backend_start_check_fail "the effective /proc shows other users' command lines (hidepid='$(proc_hidepid_value)'); run: twebproxy proc-hardening enable"
}

write_backend_start_check_helper() {
  local tmp
  [[ -d "$LIBEXEC_DIR" && ! -L "$LIBEXEC_DIR" ]] || return 1
  [[ ! -L "$LIBEXEC_DIR/backend-start-check" ]] || return 1
  tmp="$(mktemp "$LIBEXEC_DIR/.backend-start-check.XXXXXXXX")" || return 1
  if ! (
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nexport LC_ALL=C\n' || exit 1
    printf 'PROC_POLICY_FILE=%q\n' "$PROC_POLICY_FILE" || exit 1
    declare -f proc_top_mount_options proc_hidepid_value proc_unprivileged_can_read proc_hide_active \
      backend_start_check_fail backend_start_check_main || exit 1
    printf 'backend_start_check_main "$@"\n' || exit 1
  ) > "$tmp" || ! chmod 0755 "$tmp" || ! bash -n "$tmp" ||
      ! mv -fT -- "$tmp" "$LIBEXEC_DIR/backend-start-check"; then
    rm -f -- "$tmp"; return 1
  fi
}

# Re-applies the ordinary TWebProxy tables after nftables.service loaded or
# flushed the host ruleset. Isolation does not depend on it (the owned guard
# survives a flush); it keeps twebproxy_backend and the optional compatibility
# table present for audit and defence in depth.
write_nftables_dropin() {
  local dir="$SYSTEMD_DIR/nftables.service.d" tmp
  [[ -d "$SYSTEMD_DIR" && ! -L "$SYSTEMD_DIR" && ! -L "$dir" ]] || return 1
  install -d -m 0755 "$dir" || return 1
  [[ ! -L "$dir/$FW_NFT_DROPIN" ]] || return 1
  tmp="$(mktemp "$dir/.twebproxy.XXXXXXXX")" || return 1
  if ! cat > "$tmp" <<EOF
# Written by TWebProxy Manager; removed by "twebproxy core-uninstall".
# "+": run outside nftables.service's sandbox (its /etc is read-only).
[Service]
ExecStartPost=-+$LIBEXEC_DIR/apply-firewall
ExecStartPost=-+$LIBEXEC_DIR/apply-dpi-firewall
ExecStopPost=-+$LIBEXEC_DIR/apply-firewall
ExecStopPost=-+$LIBEXEC_DIR/apply-dpi-firewall
EOF
  then rm -f -- "$tmp"; return 1; fi
  if ! chmod 0644 "$tmp" || ! mv -fT -- "$tmp" "$dir/$FW_NFT_DROPIN"; then
    rm -f -- "$tmp"; return 1
  fi
}

write_backend_firewall_helper() {
  local tmp nft_bin
  nft_bin="$(command -v nft)" || return 1
  [[ -d "$LIBEXEC_DIR" && ! -L "$LIBEXEC_DIR" ]] || return 1
  [[ ! -L "$LIBEXEC_DIR/apply-firewall" ]] || return 1
  tmp="$(mktemp "$LIBEXEC_DIR/.apply-firewall.XXXXXXXX")" || return 1
  if ! (
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n' || exit 1
    printf 'BF_BASE=%q\nBF_BACKENDS=%q\nBF_FILE=%q\nBF_NFT=%q\n' "$BASE_DIR" "$BACKENDS_DIR" "$FIREWALL_FILE" "$nft_bin" || exit 1
    declare -f is_valid_port backend_fw_error backend_fw_render backend_fw_collect \
      backend_fw_ports_json backend_fw_live_ports backend_fw_batch \
      backend_fw_restore backend_fw_apply_failed backend_fw_transaction backend_fw_main || exit 1
    printf 'backend_fw_main "$@"\n' || exit 1
  ) > "$tmp" || ! chmod 0755 "$tmp" || ! bash -n "$tmp" ||
      ! mv -fT -- "$tmp" "$LIBEXEC_DIR/apply-firewall"; then
    rm -f -- "$tmp"; return 1
  fi
}

write_backend_firewall_unit() {
  local tmp systemctl_bin
  systemctl_bin="$(command -v systemctl 2>/dev/null || printf '/usr/bin/systemctl')"
  [[ -d "$SYSTEMD_DIR" && ! -L "$SYSTEMD_DIR" &&
     ! -L "$SYSTEMD_DIR/twebproxy-firewall.service" ]] || return 1
  tmp="$(mktemp "$SYSTEMD_DIR/.twebproxy-firewall.XXXXXXXX")" || return 1
  if ! cat > "$tmp" <<EOF
[Unit]
Description=Firewall for TWebProxy backend-only ports
# The owned guard table lives exactly as long as this service: a foreign
# "flush ruleset" (nftables.service start/reload/restart/stop) cannot remove
# it, so there is no PartOf=nftables.service and an nftables stop no longer
# takes the proxies down. Backends are BindsTo= this unit (fail-closed) and
# WantedBy= it, so starting it after a stop brings every enabled backend back
# only once the guard is verified in the kernel.
After=nftables.service
ReloadPropagatedFrom=nftables.service
# No start rate limit: operator restarts must never leave the guard (and with
# it every backend) down. A failing guard is retried at most every RestartSec;
# the backends stay stopped (fail-closed) until it is verified again.
StartLimitIntervalSec=0

[Service]
Type=exec
ExecStart=$LIBEXEC_DIR/firewall-guard hold
ExecStartPost=$LIBEXEC_DIR/firewall-guard wait
ExecStartPost=$LIBEXEC_DIR/apply-firewall
# Every firewall (re)start also (re)starts the bound backends; repeated
# transitions must not leave them in "start-limit-hit". Runs after the guard is
# verified and before the backends start (they are ordered After= this unit);
# crash-loop protection of a backend itself is unchanged.
ExecStartPost=-$systemctl_bin reset-failed twebproxy-mtproxy@*.service
ExecReload=$LIBEXEC_DIR/firewall-guard reload \$MAINPID
ExecReload=$LIBEXEC_DIR/apply-firewall
# A stop ends the guard session (backends are stopped first); twebproxy_backend
# itself is retained. Core uninstall explicitly tears down.
Restart=on-failure
RestartSec=5s
UMask=0077
TimeoutStartSec=240

[Install]
WantedBy=multi-user.target
EOF
  then rm -f -- "$tmp"; return 1; fi
  if ! chmod 0644 "$tmp" || ! mv -fT -- "$tmp" "$SYSTEMD_DIR/twebproxy-firewall.service"; then
    rm -f -- "$tmp"; return 1
  fi
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

  write_backend_firewall_helper || return 1
  write_firewall_guard_helper || return 1
  write_backend_start_check_helper || return 1

  cat > "$LIBEXEC_DIR/refresh-mtproxy-config" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
dest=/etc/twebproxy/mtproxy/proxy-multi.conf
tmp="$(mktemp /etc/twebproxy/mtproxy/proxy-multi.conf.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
curl -4 --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --connect-timeout 8 --max-time 20 --retry 3 --retry-all-errors --retry-delay 2 --retry-max-time 75 --max-filesize 65536 \
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
BindsTo=twebproxy-firewall.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=mtproxy
Group=mtproxy
EnvironmentFile=/etc/twebproxy/backends/%i.env
LoadCredential=proxy-secret:/etc/twebproxy/mtproxy/proxy-secret
LoadCredential=proxy-multi.conf:/etc/twebproxy/mtproxy/proxy-multi.conf
# Fail-closed start gate: refuses to start unless PID 1's socket filter below
# is enforced for this unit and the effective /proc hides command lines.
ExecStartPre=+/usr/local/libexec/twebproxy/backend-start-check %n
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
# Isolation that lives exactly as long as the backend's cgroup (P1-EXPOSURE-01):
# PID 1 attaches these cgroup-BPF ingress/egress filters before any process of
# the unit runs. Packets from or to any address other than loopback (the local
# relay) and Telegram's DC networks never reach the backend's sockets, whatever
# happens to nftables, the guard session or the order of service transitions.
IPAccounting=yes
IPAddressDeny=any
IPAddressAllow=localhost
IPAddressAllow=@TELEGRAM_DC_CIDRS@
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
# Also pulled in by the firewall unit: starting it after a stop restores every
# enabled backend, but only once the owned guard is verified (After=/BindsTo=).
WantedBy=multi-user.target twebproxy-firewall.service
EOF
  sed -i "s|@TELEGRAM_DC_CIDRS@|$TELEGRAM_DC_CIDRS|" "$SYSTEMD_DIR/twebproxy-mtproxy@.service"

  write_backend_firewall_unit || return 1

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
  local active_rc=0
  # install -d would chmod a symlink's target; the helper refuses them anyway.
  [[ ! -L "$BASE_DIR" && ! -L "$LIBEXEC_DIR" ]] ||
    { backend_fw_error "unsafe symlinked directory: $BASE_DIR or $LIBEXEC_DIR"; return 1; }
  install -d -m 0700 "$BASE_DIR" || return 1
  # twebproxy-mtproxy@ (User=mtproxy) and the nfqws worker (User=twebproxy-dpi)
  # execute from here: keep the canonical root:root 0755 of prepare_users_and_dirs.
  install -d -o root -g root -m 0755 "$LIBEXEC_DIR" || return 1
  # Also upgrade an already installed helper/unit after a script-only update.
  write_backend_firewall_helper || return 1
  write_firewall_guard_helper || return 1
  write_backend_start_check_helper || return 1
  write_backend_firewall_unit || return 1
  write_nftables_dropin || return 1
  systemctl daemon-reload || return 1
  systemctl enable twebproxy-firewall.service >/dev/null || return 1
  systemctl is-active --quiet twebproxy-firewall.service || active_rc=$?
  case "$active_rc" in
    0)
      # A unit still running the pre-0.2.23 oneshot has no guard session: restart
      # it once (backends bound to it are restarted by systemd after the guard).
      if fw_guard_present; then
        systemctl reload twebproxy-firewall.service || return 1
      else
        systemctl restart twebproxy-firewall.service || return 1
      fi;;
    3) systemctl start twebproxy-firewall.service || return 1;;
    *) return 1;;
  esac
}

fw_guard_present() {
  local text
  text="$(nft list table inet "$FW_GUARD_TABLE" 2>/dev/null)" || return 1
  grep -qE '^[[:space:]]*flags owner' <<<"$text"
}

# True when both paths resolve to the same underlying file. Compared by
# device+inode rather than by string, so a relative path or a symlink to the
# destination is recognised too.
same_underlying_file() {
  local a b
  a="$(stat -Lc '%d:%i' -- "$1" 2>/dev/null)" || return 1
  b="$(stat -Lc '%d:%i' -- "$2" 2>/dev/null)" || return 1
  [[ -n "$a" && "$a" == "$b" ]]
}

install_manager_copy() {
  local self="${BASH_SOURCE[0]}" target tmp held=0 rc=0
  [[ -f "$self" ]] || return 0
  install -d -o root -g root -m 0700 "$PROJECT_DIR" "$LOG_DIR" "$LOG_MANAGER_DIR" "$LOG_RUNTIME_DIR" "$LOG_BUNDLE_DIR" "$LOG_FULL_DIR" || return 1
  install_default_site_bundle || return 1
  # While manager-update or its offline rollback runs, the installed copies are
  # theirs: take the update lock for the copy. A lock that cannot be used at all
  # also stops manager-update, so then nothing can overlap.
  if [[ "$STAGE4_UPDATE_LOCK_FD" != 9 ]]; then
    if stage4_acquire_update_lock; then
      held=1
    else
      rc=$?
      if (( rc == 75 )); then
        warn "Копии TWebProxy Manager не синхронизированы: сейчас выполняется обновление или откат TWebProxy Manager ($UPDATE_LOCK_FILE)."
        return 0
      fi
      rc=0
    fi
  fi
  # Each destination is handled independently: when the manager runs from one of
  # its own installed paths that destination is already the running file (GNU
  # install refuses an identical source and destination), but the other copy
  # must still be synchronised. Copies are replaced atomically.
  for target in "$MANAGER_BIN" "$PROJECT_MANAGER_COPY"; do
    if same_underlying_file "$self" "$target"; then
      chown root:root -- "$target" && chmod 0755 -- "$target" || rc=1
    elif tmp="$(mktemp "$(dirname -- "$target")/.twebproxy-copy.XXXXXX")"; then
      if ! { install -o root -g root -m 0755 "$self" "$tmp" && mv -fT -- "$tmp" "$target"; }; then
        rm -f -- "$tmp"
        rc=1
      fi
    else
      rc=1
    fi
    (( rc == 0 )) || break
  done
  (( ! held )) || stage4_release_update_lock
  (( rc != 0 )) || install_bridge_bundle || rc=$?
  return "$rc"
}

# Stage 4 local update backups deliberately cover only the two manager
# executables.  The standalone helper is embedded in the trusted manager so a
# newly installed/repaired Stage 4 manager can bootstrap it without network
# access.  It has no user-selectable root/path options.
stage4_render_restore_helper() {
  cat <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

UPDATE_BACKUP_FORMAT=$(printf '%q' "$UPDATE_BACKUP_FORMAT")
UPDATE_BACKUP_PARENT=$(printf '%q' "$UPDATE_BACKUP_PARENT")
UPDATE_BACKUP_ROOT=$(printf '%q' "$UPDATE_BACKUP_ROOT")
UPDATE_LOCK_FILE=$(printf '%q' "$UPDATE_LOCK_FILE")
MANAGER_BIN=$(printf '%q' "$MANAGER_BIN")
PROJECT_MANAGER_COPY=$(printf '%q' "$PROJECT_MANAGER_COPY")
GLOBAL_ENV=$(printf '%q' "$GLOBAL_ENV")
UPDATE_BACKUP_RETENTION=$(printf '%q' "$UPDATE_BACKUP_RETENTION")
EOF
  cat <<'STAGE4_RESTORE_HELPER'

s4_err() { printf 'restore-update-backup: %s\n' "$*" >&2; }
s4_valid_id() { [[ "${1:-}" =~ ^update-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$ ]]; }
s4_valid_version() { [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

s4_no_symlink_components() {
  local path="$1" part current=""
  [[ "$path" == /* && "$path" != *//* ]] || return 1
  IFS='/' read -r -a _s4_parts <<< "${path#/}"
  for part in "${_s4_parts[@]}"; do
    [[ -n "$part" && "$part" != . && "$part" != .. ]] || return 1
    current="$current/$part"
    [[ ! -L "$current" ]] || return 1
  done
}

s4_safe_dir() {
  local path="$1" mode="$2" st
  s4_no_symlink_components "$path" || return 1
  [[ -d "$path" && ! -L "$path" ]] || return 1
  st="$(stat -c '%u:%g:%a' -- "$path" 2>/dev/null)" || return 1
  [[ "$st" == "0:0:$mode" ]]
}

s4_safe_file() {
  local path="$1" mode="$2" st
  s4_no_symlink_components "$path" || return 1
  [[ -f "$path" && ! -L "$path" ]] || return 1
  st="$(stat -c '%u:%g:%a' -- "$path" 2>/dev/null)" || return 1
  [[ "$st" == "0:0:$mode" ]]
}

s4_embedded_version() {
  local file="$1" values
  values="$(sed -nE 's/^MANAGER_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$file")"
  [[ "$(wc -l <<< "$values")" -eq 1 ]] || return 1
  printf '%s' "$values"
}

# The parent is shared (the ACME webroot lives there and needs traversal): it
# must be root-owned and not group/other-writable. The backup root itself is 0700.
s4_safe_parent_dir() {
  local path="$1" st
  s4_no_symlink_components "$path" || return 1
  [[ -d "$path" && ! -L "$path" ]] || return 1
  st="$(stat -c '%u:%g:%a' -- "$path" 2>/dev/null)" || return 1
  [[ "$st" =~ ^0:0:([0-7]+)$ ]] && (( (8#${BASH_REMATCH[1]} & 8#022) == 0 ))
}

s4_backup_root_safe() {
  s4_safe_parent_dir "$UPDATE_BACKUP_PARENT" && s4_safe_dir "$UPDATE_BACKUP_ROOT" 700
}

s4_verify_backup_dir() {
  local dir="$1" expected_id="$2" state="${3:-published}"
  local base parent entries expected_entries metadata_hash payload_hash source_version embedded
  s4_valid_id "$expected_id" || return 1
  s4_backup_root_safe || return 1
  parent="$(dirname -- "$dir")"; base="$(basename -- "$dir")"
  [[ "$parent" == "$UPDATE_BACKUP_ROOT" ]] || return 1
  case "$state" in
    published) [[ "$base" == "$expected_id" ]] || return 1;;
    incomplete) [[ "$base" == ".incomplete.$expected_id."* ]] || return 1;;
    *) return 1;;
  esac
  s4_safe_dir "$dir" 700 || return 1
  entries="$(find "$dir" -mindepth 1 -printf '%P\n' 2>/dev/null | LC_ALL=C sort)" || return 1
  expected_entries=$'SHA256SUMS\nfiles\nfiles/twebproxy-manager.sh\nmetadata.json'
  [[ "$entries" == "$expected_entries" ]] || return 1
  s4_safe_dir "$dir/files" 700 || return 1
  s4_safe_file "$dir/metadata.json" 600 || return 1
  s4_safe_file "$dir/SHA256SUMS" 600 || return 1
  s4_safe_file "$dir/files/twebproxy-manager.sh" 600 || return 1

  jq -e --arg format "$UPDATE_BACKUP_FORMAT" --arg id "$expected_id" \
    --arg target1 "$MANAGER_BIN" --arg target2 "$PROJECT_MANAGER_COPY" '
      type == "object" and
      (keys | sort) == (["backup_id","created_at","format","manager_payload_sha256","restore_targets","source_manager_version","target_manager_version"] | sort) and
      .format == $format and .backup_id == $id and
      (.created_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      (.source_manager_version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
      (.target_manager_version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
      (.manager_payload_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .restore_targets == [$target1,$target2]
    ' "$dir/metadata.json" >/dev/null || return 1

  [[ "$(wc -l < "$dir/SHA256SUMS")" -eq 2 ]] || return 1
  awk '
    $0 !~ /^[0-9a-f]{64}  (metadata.json|files\/twebproxy-manager.sh)$/ { bad=1 }
    $2 == "metadata.json" { metadata++ }
    $2 == "files/twebproxy-manager.sh" { payload++ }
    END { exit !(bad == 0 && metadata == 1 && payload == 1) }
  ' "$dir/SHA256SUMS" || return 1
  (cd "$dir" && sha256sum --strict -c SHA256SUMS >/dev/null 2>&1) || return 1

  metadata_hash="$(jq -r '.manager_payload_sha256' "$dir/metadata.json")"
  payload_hash="$(sha256sum "$dir/files/twebproxy-manager.sh" | awk '{print $1}')"
  [[ "$metadata_hash" == "$payload_hash" ]] || return 1
  bash -n "$dir/files/twebproxy-manager.sh" || return 1
  source_version="$(jq -r '.source_manager_version' "$dir/metadata.json")"
  embedded="$(s4_embedded_version "$dir/files/twebproxy-manager.sh")" || return 1
  [[ "$embedded" == "$source_version" ]]
}

s4_target_parent_safe() {
  local target="$1" parent
  parent="$(dirname -- "$target")"
  s4_no_symlink_components "$parent" || return 1
  [[ -d "$parent" && ! -L "$parent" ]] || return 1
  [[ "$(stat -c '%u:%g' -- "$parent" 2>/dev/null)" == 0:0 ]]
}

s4_manager_file_safe() {
  s4_safe_file "$1" 755
}

# One bounded health probe: $1=seconds $2=output file $3...=command. The output
# goes to a size-capped file, not a pipe: a descendant that keeps stdout open
# cannot hold the caller the way a command substitution waits for EOF.
# timeout(1) runs the probe in its own process group (SIGKILL 5 s after the
# timeout, for a probe that ignores SIGTERM); whatever is left of that group
# afterwards is killed. No stdin, no update-lock descriptor 9.
s4_probe() {
  local seconds="$1" out="$2" pid rc=0
  shift 2
  ( ulimit -f 4096; export TWEBPROXY_NO_LOG=1; exec timeout -k 5 "$seconds" "$@" ) \
    > "$out" 2>/dev/null < /dev/null 9>&- &
  pid=$!
  wait "$pid" || rc=$?
  kill -KILL -- "-$pid" 2>/dev/null || true
  return "$rc"
}

s4_manager_health() {
  local expected_hash="$1" expected_version="$2" target hash work rc=0
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  s4_valid_version "$expected_version" || return 1
  work="$(mktemp -d "${TMPDIR:-/tmp}/twebproxy-health.XXXXXX")" || return 1
  for target in "$MANAGER_BIN" "$PROJECT_MANAGER_COPY"; do
    if s4_target_parent_safe "$target" && s4_manager_file_safe "$target" \
       && hash="$(sha256sum "$target" | awk '{print $1}')" && [[ "$hash" == "$expected_hash" ]] \
       && bash -n "$target" \
       && s4_probe 15 "$work/help" "$target" --help \
       && grep -Fq "TWebProxy Manager v$expected_version" "$work/help" \
       && s4_probe 20 "$work/overview" "$target" --json overview \
       && jq -e --arg version "$expected_version" '
            type == "object" and .schema_version == "twebproxy.output.v1" and
            .command == "overview" and .data.manager_version == $version
          ' "$work/overview" >/dev/null; then
      continue
    fi
    rc=1
    break
  done
  rm -rf -- "$work"
  return "$rc"
}

s4_stage_payload() {
  local payload="$1" target="$2" expected_hash="$3" tmp hash
  s4_target_parent_safe "$target" || return 1
  tmp="$(mktemp "$(dirname -- "$target")/.twebproxy-stage4.XXXXXX")" || return 1
  if ! install -o root -g root -m 0755 "$payload" "$tmp"; then rm -f -- "$tmp"; return 1; fi
  s4_manager_file_safe "$tmp" || { rm -f -- "$tmp"; return 1; }
  hash="$(sha256sum "$tmp" | awk '{print $1}')"
  [[ "$hash" == "$expected_hash" ]] || { rm -f -- "$tmp"; return 1; }
  bash -n "$tmp" || { rm -f -- "$tmp"; return 1; }
  printf '%s' "$tmp"
}

S4_LOCK_FD=""
s4_acquire_lock() {
  local lock_parent probe_fd=""
  lock_parent="$(dirname -- "$UPDATE_LOCK_FILE")"
  s4_no_symlink_components "$lock_parent" || return 1
  [[ -d "$lock_parent" && ! -L "$lock_parent" ]] || return 1
  if [[ ! -e "$UPDATE_LOCK_FILE" ]]; then
    ( set -o noclobber; : > "$UPDATE_LOCK_FILE" ) 2>/dev/null || true
  fi
  s4_safe_file "$UPDATE_LOCK_FILE" 600 || return 1
  if [[ "${TWEBPROXY_STAGE4_LOCK_HELD:-0}" == 1 ]]; then
    # The updater parent keeps the lock while synchronously waiting for this
    # helper.  Prove that the fixed lock is in fact contended; if it is free,
    # the internal handoff claim is false and restore fails closed.
    exec {probe_fd}>"$UPDATE_LOCK_FILE" || return 1
    if flock -n "$probe_fd"; then
      flock -u "$probe_fd" || true
      eval "exec ${probe_fd}>&-"
      return 1
    fi
    S4_LOCK_FD="externally-held"
    return 0
  fi
  # Fixed descriptor 9, as in the manager: the health probes close it.
  exec 9>"$UPDATE_LOCK_FILE" || return 1
  S4_LOCK_FD=9
  s4_safe_file "$UPDATE_LOCK_FILE" 600 || return 1
  flock -n 9
}

# MANAGER_VERSION in global.env follows the restored copies (an offline restore
# after an update left the newer version there). Only that line changes; the
# file is rewritten beside itself, verified and renamed. Absent file: nothing.
s4_sync_metadata() {
  local version="$1" tmp line found=0
  [[ -n "${GLOBAL_ENV:-}" && ( -e "$GLOBAL_ENV" || -L "$GLOBAL_ENV" ) ]] || return 0
  s4_valid_version "$version" || return 1
  s4_safe_file "$GLOBAL_ENV" 600 || return 1
  if [[ "$(grep -c '^MANAGER_VERSION=' "$GLOBAL_ENV")" == 1 ]] && grep -qx "MANAGER_VERSION=$version" "$GLOBAL_ENV"; then
    return 0
  fi
  tmp="$(mktemp "$(dirname -- "$GLOBAL_ENV")/.global.env.XXXXXX")" || return 1
  if {
       while IFS= read -r line || [[ -n "$line" ]]; do
         if [[ "$line" == MANAGER_VERSION=* ]]; then
           (( found )) || printf 'MANAGER_VERSION=%s\n' "$version"
           found=1
         else
           printf '%s\n' "$line"
         fi
       done < "$GLOBAL_ENV"
       (( found )) || printf 'MANAGER_VERSION=%s\n' "$version"
     } > "$tmp" \
     && [[ "$(grep -v '^MANAGER_VERSION=' "$tmp")" == "$(grep -v '^MANAGER_VERSION=' "$GLOBAL_ENV")" ]] \
     && [[ "$(grep -c '^MANAGER_VERSION=' "$tmp")" == 1 ]] && grep -qx "MANAGER_VERSION=$version" "$tmp" \
     && chmod 0600 "$tmp" && mv -fT -- "$tmp" "$GLOBAL_ENV"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

s4_restore_id() {
  local id="$1" dir payload expected_hash expected_version tmp1="" tmp2=""
  s4_valid_id "$id" || { s4_err "invalid backup id"; return 2; }
  dir="$UPDATE_BACKUP_ROOT/$id"
  s4_verify_backup_dir "$dir" "$id" published || { s4_err "backup verification failed: $id"; return 1; }
  payload="$dir/files/twebproxy-manager.sh"
  expected_hash="$(jq -r '.manager_payload_sha256' "$dir/metadata.json")"
  expected_version="$(jq -r '.source_manager_version' "$dir/metadata.json")"
  tmp1="$(s4_stage_payload "$payload" "$MANAGER_BIN" "$expected_hash")" || return 1
  tmp2="$(s4_stage_payload "$payload" "$PROJECT_MANAGER_COPY" "$expected_hash")" || { rm -f -- "$tmp1"; return 1; }
  trap 'rm -f -- "${tmp1:-}" "${tmp2:-}"' RETURN
  mv -fT -- "$tmp1" "$MANAGER_BIN" || return 1
  tmp1=""
  mv -fT -- "$tmp2" "$PROJECT_MANAGER_COPY" || return 1
  tmp2=""
  s4_manager_health "$expected_hash" "$expected_version" || return 1
  trap - RETURN
  # Complete only when the metadata follows the restored copies. Otherwise the
  # executables are restored (and healthy) but the outcome is partial: distinct
  # marker and status 3, never RESTORE_SUCCESS.
  if ! s4_sync_metadata "$expected_version"; then
    s4_err "executables restored to $expected_version, but MANAGER_VERSION in $GLOBAL_ENV could not be updated (read-only, immutable or full?); make it writable (e.g. chattr -i $GLOBAL_ENV) and run 'twebproxy repair <hostname>'"
    printf 'RESTORE_PARTIAL backup_id=%s manager_version=%s metadata=stale\n' "$id" "$expected_version"
    return 3
  fi
  printf 'RESTORE_SUCCESS backup_id=%s manager_version=%s\n' "$id" "$expected_version"
}

s4_collect_valid_ids() {
  local path id
  s4_backup_root_safe || return 1
  shopt -s nullglob
  for path in "$UPDATE_BACKUP_ROOT"/update-*; do
    [[ -d "$path" && ! -L "$path" ]] || continue
    id="$(basename -- "$path")"
    s4_valid_id "$id" || continue
    s4_verify_backup_dir "$path" "$id" published && printf '%s\n' "$id"
  done
  shopt -u nullglob
}

s4_list() {
  local path id valid=0 invalid=0 source created
  printf 'format=%s\n' "$UPDATE_BACKUP_FORMAT"
  if [[ ! -e "$UPDATE_BACKUP_ROOT" ]]; then
    printf 'valid=0 invalid=0\n'; return 0
  fi
  s4_backup_root_safe || { s4_err "unsafe backup root"; return 1; }
  shopt -s nullglob dotglob
  for path in "$UPDATE_BACKUP_ROOT"/*; do
    id="$(basename -- "$path")"
    if s4_valid_id "$id" && s4_verify_backup_dir "$path" "$id" published; then
      source="$(jq -r '.source_manager_version' "$path/metadata.json")"
      created="$(jq -r '.created_at' "$path/metadata.json")"
      printf 'backup_id=%s source_version=%s created_at=%s status=VERIFIED\n' "$id" "$source" "$created"
      valid=$((valid+1))
    else
      printf 'entry=%q status=INVALID\n' "$id"
      invalid=$((invalid+1))
    fi
  done
  shopt -u nullglob dotglob
  printf 'valid=%s invalid=%s\n' "$valid" "$invalid"
}

s4_restore_latest() {
  local id
  id="$(s4_collect_valid_ids | LC_ALL=C sort -r | head -n1)"
  [[ -n "$id" ]] || { s4_err "no verified backup"; return 1; }
  s4_restore_id "$id"
}

s4_prune_verified() {
  local protect="${1:-}" id kept=0
  local -a ids=()
  mapfile -t ids < <(s4_collect_valid_ids | LC_ALL=C sort -r)
  if [[ -n "$protect" ]]; then
    s4_valid_id "$protect" || return 1
    s4_verify_backup_dir "$UPDATE_BACKUP_ROOT/$protect" "$protect" published || return 1
    kept=1
  fi
  for id in "${ids[@]}"; do
    [[ -n "$protect" && "$id" == "$protect" ]] && continue
    if (( kept < UPDATE_BACKUP_RETENTION )); then
      kept=$((kept+1))
      continue
    fi
    rm -rf --one-file-system -- "$UPDATE_BACKUP_ROOT/$id"
  done
}

s4_main() {
  if [[ "${1:-}" != list && -e /etc/twebproxy/bridge/node.json ]]; then s4_err "Bridge compatibility guard: detach/remove before Manager executable rollback"; return 1; fi
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { s4_err "root required"; return 1; }
  case "${1:-}" in
    list)
      [[ $# -eq 1 ]] || { s4_err "usage: restore-update-backup list"; return 2; }
      s4_list
      ;;
    restore-latest)
      [[ $# -eq 1 ]] || { s4_err "usage: restore-update-backup restore-latest"; return 2; }
      s4_acquire_lock || { s4_err "update lock is busy or unsafe"; return 1; }
      s4_restore_latest
      ;;
    restore)
      [[ $# -eq 2 ]] || { s4_err "usage: restore-update-backup restore <id>"; return 2; }
      s4_valid_id "$2" || { s4_err "invalid backup id"; return 2; }
      s4_acquire_lock || { s4_err "update lock is busy or unsafe"; return 1; }
      s4_restore_id "$2"
      ;;
    *) s4_err "usage: restore-update-backup {list|restore-latest|restore <id>}"; return 2;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  s4_main "$@"
fi
STAGE4_RESTORE_HELPER
}

stage4_no_symlink_components() {
  local path="$1" part current=""
  [[ "$path" == /* && "$path" != *//* ]] || return 1
  IFS='/' read -r -a _stage4_parts <<< "${path#/}"
  for part in "${_stage4_parts[@]}"; do
    [[ -n "$part" && "$part" != . && "$part" != .. ]] || return 1
    current="$current/$part"
    [[ ! -L "$current" ]] || return 1
  done
}

stage4_safe_root_file() {
  local path="$1" mode="$2"
  stage4_no_symlink_components "$path" || return 1
  [[ -f "$path" && ! -L "$path" ]] || return 1
  [[ "$(stat -c '%u:%g:%a' -- "$path" 2>/dev/null)" == "0:0:$mode" ]]
}

stage4_restore_helper_valid() { # $1=helper file: safe, parseable, bound to these paths, answers list
  local helper="$1" output first
  stage4_safe_root_file "$helper" 755 || return 1
  bash -n "$helper" || return 1
  bash -c '
    source "$1"
    [[ "$UPDATE_BACKUP_FORMAT" == "$2" && "$UPDATE_BACKUP_PARENT" == "$3" &&
       "$UPDATE_BACKUP_ROOT" == "$4" && "$UPDATE_LOCK_FILE" == "$5" &&
       "$MANAGER_BIN" == "$6" && "$PROJECT_MANAGER_COPY" == "$7" ]]
    declare -F s4_verify_backup_dir s4_manager_health s4_restore_id s4_prune_verified >/dev/null
  ' _ "$helper" "$UPDATE_BACKUP_FORMAT" "$UPDATE_BACKUP_PARENT" \
    "$UPDATE_BACKUP_ROOT" "$UPDATE_LOCK_FILE" "$MANAGER_BIN" "$PROJECT_MANAGER_COPY" 9>&- || return 1
  output="$(exec 9>&-; TWEBPROXY_NO_LOG=1 timeout 10 "$helper" list 2>/dev/null)" || return 1
  first="${output%%$'\n'*}"
  [[ "$first" == "format=$UPDATE_BACKUP_FORMAT" ]]
}

stage4_install_restore_helper() {
  # no: verify the installed helper; yes: also bootstrap a missing one;
  # refresh (manager-update, under the update lock): also replace a valid helper
  # rendered by another manager version, so helper fixes reach existing hosts.
  # An unsafe or invalid helper is never replaced.
  local mode="${1:-no}" dir dir_parent tmp
  dir="$(dirname -- "$UPDATE_RESTORE_HELPER")"
  stage4_no_symlink_components "$dir" || return 1
  if [[ ! -e "$dir" ]]; then
    [[ "$mode" != no ]] || return 1
    dir_parent="$(dirname -- "$dir")"
    stage4_no_symlink_components "$dir_parent" || return 1
    [[ -d "$dir_parent" && ! -L "$dir_parent" && "$(stat -c '%u:%g' -- "$dir_parent" 2>/dev/null)" == 0:0 ]] || return 1
    install -d -o root -g root -m 0755 "$dir" || return 1
  fi
  [[ -d "$dir" && ! -L "$dir" && "$(stat -c '%u:%g' -- "$dir" 2>/dev/null)" == 0:0 ]] || return 1
  if [[ -e "$UPDATE_RESTORE_HELPER" || -L "$UPDATE_RESTORE_HELPER" ]]; then
    stage4_restore_helper_valid "$UPDATE_RESTORE_HELPER" || return 1
    [[ "$mode" == refresh ]] || return 0
  else
    [[ "$mode" != no ]] || return 1
  fi
  tmp="$(mktemp "$dir/.restore-update-backup.XXXXXX")" || return 1
  if stage4_render_restore_helper > "$tmp" && chmod 0755 "$tmp" && chown root:root "$tmp"; then
    if [[ -f "$UPDATE_RESTORE_HELPER" ]] && cmp -s -- "$tmp" "$UPDATE_RESTORE_HELPER"; then
      rm -f -- "$tmp"
      return 0
    fi
    if stage4_restore_helper_valid "$tmp" && mv -fT -- "$tmp" "$UPDATE_RESTORE_HELPER"; then
      stage4_restore_helper_valid "$UPDATE_RESTORE_HELPER"
      return
    fi
  fi
  rm -f -- "$tmp"
  return 1
}

stage4_verify_backup() {
  local dir="$1" id="$2" state="${3:-published}"
  bash -c 'source "$1"; s4_verify_backup_dir "$2" "$3" "$4"' _ \
    "$UPDATE_RESTORE_HELPER" "$dir" "$id" "$state" 9>&-
}

stage4_prune_backups() {
  local protect="${1:-}"
  bash -c 'source "$1"; s4_prune_verified "$2"' _ "$UPDATE_RESTORE_HELPER" "$protect" 9>&-
}

# UPDATE_BACKUP_PARENT is shared with the ACME webroot, which the web server must
# traverse: a missing parent is created 0755, an existing one must be root-owned
# and not group/other-writable (its mode is left as it is). Backups and staging
# below it are 0700.
stage4_backup_parent_ready() {
  local parent_parent st
  parent_parent="$(dirname -- "$UPDATE_BACKUP_PARENT")"
  stage4_no_symlink_components "$parent_parent" || return 1
  [[ -d "$parent_parent" && ! -L "$parent_parent" ]] || return 1
  if [[ ! -e "$UPDATE_BACKUP_PARENT" ]]; then
    install -d -o root -g root -m 0755 "$UPDATE_BACKUP_PARENT" || return 1
  fi
  stage4_no_symlink_components "$UPDATE_BACKUP_PARENT" || return 1
  [[ -d "$UPDATE_BACKUP_PARENT" && ! -L "$UPDATE_BACKUP_PARENT" ]] || return 1
  st="$(stat -c '%u:%g:%a' -- "$UPDATE_BACKUP_PARENT" 2>/dev/null)" || return 1
  [[ "$st" =~ ^0:0:([0-7]+)$ ]] && (( (8#${BASH_REMATCH[1]} & 8#022) == 0 ))
}

stage4_prepare_backup_root() {
  stage4_backup_parent_ready || return 1
  if [[ ! -e "$UPDATE_BACKUP_ROOT" ]]; then
    install -d -o root -g root -m 0700 "$UPDATE_BACKUP_ROOT" || return 1
  fi
  stage4_no_symlink_components "$UPDATE_BACKUP_ROOT" || return 1
  [[ -d "$UPDATE_BACKUP_ROOT" && ! -L "$UPDATE_BACKUP_ROOT" ]] || return 1
  [[ "$(stat -c '%u:%g:%a' -- "$UPDATE_BACKUP_ROOT" 2>/dev/null)" == 0:0:700 ]]
}

STAGE4_UPDATE_LOCK_FD=""
stage4_acquire_update_lock() { # 0 held, 75 busy after the bounded wait, 1 unsafe or unavailable
  local parent wait="$UPDATE_LOCK_WAIT_SECONDS"
  [[ "$wait" =~ ^[0-9]{1,3}$ ]] || wait=30
  parent="$(dirname -- "$UPDATE_LOCK_FILE")"
  stage4_no_symlink_components "$parent" || return 1
  [[ -d "$parent" && ! -L "$parent" ]] || return 1
  if [[ ! -e "$UPDATE_LOCK_FILE" ]]; then
    ( set -o noclobber; : > "$UPDATE_LOCK_FILE" ) 2>/dev/null || true
  fi
  stage4_safe_root_file "$UPDATE_LOCK_FILE" 600 || return 1
  # Fixed descriptor 9: the offline helper inherits this exact locked open file
  # description for rollback, and every health probe runs with it closed.
  STAGE4_UPDATE_LOCK_FD=9
  exec 9>"$UPDATE_LOCK_FILE" || { STAGE4_UPDATE_LOCK_FD=""; return 1; }
  stage4_safe_root_file "$UPDATE_LOCK_FILE" 600 || { stage4_release_update_lock; return 1; }
  # Bounded wait for a finishing update or rollback. The kernel drops the lock
  # with its holder, so an interrupted update never leaves it behind; the lock
  # file itself is never deleted.
  flock -w "$wait" 9 || { stage4_release_update_lock; return 75; }
}

stage4_release_update_lock() {
  [[ "$STAGE4_UPDATE_LOCK_FD" == 9 ]] || return 0
  exec 9>&-
  STAGE4_UPDATE_LOCK_FD=""
}

stage4_current_manager_preflight() {
  local first_hash second_hash first_version second_version
  stage4_safe_root_file "$MANAGER_BIN" 755 || return 1
  stage4_safe_root_file "$PROJECT_MANAGER_COPY" 755 || return 1
  first_hash="$(sha256sum "$MANAGER_BIN" | awk '{print $1}')"
  second_hash="$(sha256sum "$PROJECT_MANAGER_COPY" | awk '{print $1}')"
  [[ "$first_hash" == "$second_hash" ]] || return 1
  cmp -s -- "$MANAGER_BIN" "$PROJECT_MANAGER_COPY" || return 1
  bash -n "$MANAGER_BIN" && bash -n "$PROJECT_MANAGER_COPY" || return 1
  first_version="$(sed -nE 's/^MANAGER_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$MANAGER_BIN")"
  second_version="$(sed -nE 's/^MANAGER_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$PROJECT_MANAGER_COPY")"
  [[ "$first_version" == "$MANAGER_VERSION" && "$second_version" == "$MANAGER_VERSION" ]] || return 1
  bash -c 'source "$1"; s4_manager_health "$2" "$3"' _ "$UPDATE_RESTORE_HELPER" "$first_hash" "$MANAGER_VERSION" 9>&-
}

stage4_create_backup() {
  local target_version="$1" now id suffix incomplete final payload_hash metadata_hash
  stage4_prepare_backup_root || return 1
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  id="update-$(date -u '+%Y%m%dT%H%M%SZ')-$(openssl rand -hex 6)"
  [[ "$id" =~ ^update-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$ ]] || return 1
  suffix="$(openssl rand -hex 6)"
  incomplete="$UPDATE_BACKUP_ROOT/.incomplete.$id.$suffix"
  final="$UPDATE_BACKUP_ROOT/$id"
  [[ ! -e "$incomplete" && ! -e "$final" ]] || return 1
  install -d -o root -g root -m 0700 "$incomplete" || return 1
  install -d -o root -g root -m 0700 "$incomplete/files" || return 1
  trap 'rm -rf --one-file-system -- "$incomplete"' RETURN
  install -o root -g root -m 0600 "$MANAGER_BIN" "$incomplete/files/twebproxy-manager.sh" || return 1
  payload_hash="$(sha256sum "$incomplete/files/twebproxy-manager.sh" | awk '{print $1}')"
  jq -cn \
    --arg format "$UPDATE_BACKUP_FORMAT" --arg id "$id" --arg created "$now" \
    --arg source "$MANAGER_VERSION" --arg target "$target_version" --arg hash "$payload_hash" \
    --arg target1 "$MANAGER_BIN" --arg target2 "$PROJECT_MANAGER_COPY" \
    '{format:$format,backup_id:$id,created_at:$created,source_manager_version:$source,target_manager_version:$target,manager_payload_sha256:$hash,restore_targets:[$target1,$target2]}' \
    > "$incomplete/metadata.json" || return 1
  chmod 0600 "$incomplete/metadata.json"
  metadata_hash="$(sha256sum "$incomplete/metadata.json" | awk '{print $1}')"
  printf '%s  metadata.json\n%s  files/twebproxy-manager.sh\n' "$metadata_hash" "$payload_hash" > "$incomplete/SHA256SUMS"
  chmod 0600 "$incomplete/SHA256SUMS"
  stage4_verify_backup "$incomplete" "$id" incomplete || return 1
  mv -T -- "$incomplete" "$final" || return 1
  incomplete=""
  stage4_verify_backup "$final" "$id" published || return 1
  trap - RETURN
  printf '%s' "$id"
}

stage4_install_candidate_target() {
  local candidate="$1" target="$2" expected_hash="$3" dir tmp hash
  dir="$(dirname -- "$target")"
  stage4_no_symlink_components "$dir" || return 1
  [[ -d "$dir" && ! -L "$dir" && "$(stat -c '%u:%g' -- "$dir" 2>/dev/null)" == 0:0 ]] || return 1
  tmp="$(mktemp "$dir/.twebproxy-stage4.XXXXXX")" || return 1
  # Explicit cleanup, no RETURN trap: one set here replaced the caller's trap
  # and outlived this function after a failure.
  if install -o root -g root -m 0755 "$candidate" "$tmp" \
     && stage4_safe_root_file "$tmp" 755 \
     && hash="$(sha256sum "$tmp" | awk '{print $1}')" && [[ "$hash" == "$expected_hash" ]] \
     && bash -n "$tmp" \
     && mv -fT -- "$tmp" "$target"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

stage4_manager_copies_match() { # $1=SHA-256: both installed copies are exactly this root 0755 file
  local target
  for target in "$MANAGER_BIN" "$PROJECT_MANAGER_COPY"; do
    stage4_safe_root_file "$target" 755 || return 1
    [[ "$(sha256sum "$target" | awk '{print $1}')" == "$1" ]] || return 1
  done
}

stage4_manager_health() {
  local expected_hash="$1" expected_version="$2"
  bash -c 'source "$1"; s4_manager_health "$2" "$3"' _ \
    "$UPDATE_RESTORE_HELPER" "$expected_hash" "$expected_version" 9>&-
}

# The only child that keeps descriptor 9: the helper restores under the very
# lock this updater holds, also if the updater dies meanwhile.
stage4_rollback_exact() {
  local id="$1"
  TWEBPROXY_STAGE4_LOCK_HELD=1 \
    "$UPDATE_RESTORE_HELPER" restore "$id"
}

manager_backup_list_cmd() {
  need_root; banner
  stage4_install_restore_helper no || die "Offline rollback helper отсутствует или небезопасен: $UPDATE_RESTORE_HELPER"
  "$UPDATE_RESTORE_HELPER" list
}

manager_restore_backup_cmd() {
  [[ ! -e "$BASE_DIR/bridge/node.json" ]] || die "Remove/detach Bridge before Manager version update/rollback (Gate2 compatibility guard)."
  need_root; banner
  local selector="${1:-latest}"
  stage4_install_restore_helper no || die "Offline rollback helper отсутствует или небезопасен: $UPDATE_RESTORE_HELPER"
  local question rc=0
  if [[ "$selector" == latest ]]; then
    question="Восстановить самый новый проверенный manager backup?"
  else
    [[ "$selector" =~ ^update-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$ ]] || die "Некорректный backup ID."
    question="Восстановить manager из $selector?"
  fi
  stage4_confirm_restore "$question" || return $?
  if [[ "$selector" == latest ]]; then
    "$UPDATE_RESTORE_HELPER" restore-latest || rc=$?
  else
    "$UPDATE_RESTORE_HELPER" restore "$selector" || rc=$?
  fi
  (( rc != 3 )) || warn "$(ui_msgf restore_partial_hint "$GLOBAL_ENV" "$GLOBAL_ENV")"
  return "$rc"
}

# A declined or unanswerable confirmation restores nothing and is not success:
# ROLLBACK_NOT_PERFORMED with status 1 (declined) or 130 (input closed).
stage4_confirm_restore() {
  local reply=""
  if ! read -r -p "$(ui_localize_legacy "$1") [y/N]: " reply; then
    printf '\n' >&2
    warn "$(ui_msg rollback_not_performed_eof)"
    printf 'ROLLBACK_NOT_PERFORMED reason=eof\n'
    return 130
  fi
  case "$reply" in y|Y|yes|YES|Yes|д|Д|да|Да|ДА) return 0;; esac
  log "$(ui_msg rollback_not_performed_declined)"
  printf 'ROLLBACK_NOT_PERFORMED reason=declined\n'
  return 1
}

stage4_backup_tui_summary() {
  local output summary
  if ! stage4_install_restore_helper no 2>/dev/null; then
    printf 'unavailable'
    return 0
  fi
  output="$("$UPDATE_RESTORE_HELPER" list 2>/dev/null)" || { printf 'unavailable'; return 0; }
  summary="$(tail -n1 <<< "$output")"
  [[ "$summary" =~ ^valid=([0-9]+)[[:space:]]invalid=([0-9]+)$ ]] || { printf 'unavailable'; return 0; }
  printf '%s verified, %s invalid/incomplete preserved' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
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
  local line version="" ref="" source=""
  manager_update_cache_fresh || return 1
  unset REMOTE_MANAGER_VERSION REMOTE_MANAGER_REF REMOTE_MANAGER_SOURCE CHECKED_AT
  # Parsed, never sourced. Only a stable-release entry is accepted: a cache
  # written before Stage F may name a development branch.
  while IFS= read -r line; do
    case "$line" in
      REMOTE_MANAGER_VERSION=*) version="${line#*=}";;
      REMOTE_MANAGER_REF=*) ref="${line#*=}";;
      REMOTE_MANAGER_SOURCE=*) source="${line#*=}";;
    esac
  done < "$UPDATE_CACHE_FILE"
  valid_manager_version "$version" && [[ "$source" == release && "$ref" == "v$version" ]] || return 1
  REMOTE_MANAGER_VERSION="$version"
  REMOTE_MANAGER_REF="$ref"
  REMOTE_MANAGER_SOURCE="$source"
}

manager_release_tag_from_json() { # $1=GitHub releases/latest answer -> the validated stable tag
  jq -er --arg slug "$MANAGER_REPO_SLUG" '
    if type == "object" and (.tag_name | type) == "string"
       and (.tag_name | test("^v[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,6}$"))
       and .draft == false and .prerelease == false
       and .html_url == ("https://github.com/" + $slug + "/releases/tag/" + .tag_name)
    then .tag_name else empty end' <<< "$1" 2>/dev/null
}

manager_latest_release_tag() { # $1=connect timeout $2=max time $3=user agent -> stable tag
  local json
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
  # The API answers with the newest published release that is neither a draft
  # nor a prerelease; the answer is validated anyway. Redirects are not
  # followed: a moved repository is not silently trusted.
  json="$(exec 9>&-; curl -fsS --connect-timeout "$1" --max-time "$2" --max-filesize 1048576 \
    --proto '=https' --tlsv1.2 \
    -H 'Accept: application/vnd.github+json' \
    -H "User-Agent: $3" \
    "$MANAGER_API_URL/releases/latest" 2>/dev/null)" || return 1
  manager_release_tag_from_json "$json"
}

fetch_manager_update_info() {
  local allow_cache="${1:-yes}" tag
  unset REMOTE_MANAGER_VERSION REMOTE_MANAGER_REF REMOTE_MANAGER_SOURCE

  if [[ "$allow_cache" == "yes" ]] && load_manager_update_cache; then
    return 0
  fi
  # Only the latest stable GitHub Release is a candidate: a VERSION file on a
  # development branch is never an update source.
  tag="$(exec 9>&-; manager_latest_release_tag 3 8 twebproxy-manager-update-check)" || return 1
  REMOTE_MANAGER_VERSION="${tag#v}"
  REMOTE_MANAGER_REF="$tag"
  REMOTE_MANAGER_SOURCE="release"
  write_manager_update_cache "$REMOTE_MANAGER_VERSION" "$tag" release
  return 0
}

manager_release_download() { # $1=URL $2=output $3=max bytes $4=direct|assets
  local url="$1" out="$2" max="$3" policy="$4" meta code redirects effective redirs=0
  [[ "$policy" == direct ]] || redirs=3
  # Checked after the transfer: HTTP 200 only, no redirect for a direct URL, and
  # for release downloads only a redirect to a GitHub release-asset host. A body
  # from anywhere else is discarded before anything reads it.
  meta="$(exec 9>&-; curl -fsSL --connect-timeout 5 --max-time 60 --retry 2 --max-redirs "$redirs" \
    --max-filesize "$max" --proto '=https' --proto-redir '=https' --tlsv1.2 \
    -H 'User-Agent: twebproxy-manager-updater' \
    -w '%{http_code} %{num_redirects} %{url_effective}' -o "$out" "$url" 2>/dev/null)" || return 1
  read -r code redirects effective <<< "$meta"
  [[ "$code" == 200 && "$redirects" =~ ^[0-9]+$ ]] || return 1
  if (( redirects == 0 )); then
    [[ "$effective" == "$url" ]] || return 1
  else
    [[ "$policy" == assets && "$effective" =~ ^https://([^/@:]+)/ ]] || return 1
    case "${BASH_REMATCH[1]}" in
      objects.githubusercontent.com|release-assets.githubusercontent.com) ;;
      *) return 1;;
    esac
  fi
  [[ -f "$out" && ! -L "$out" ]] || return 1
  (( $(stat -c %s -- "$out") <= max ))
}

manager_release_signature_ok() { # $1=manifest $2=base64 signature $3=work dir: a pinned key verifies it
  local manifest="$1" signature="$2" dir="$3" key n=0
  tr -d '\n' < "$signature" | base64 -d > "$dir/manifest.sig.bin" 2>/dev/null || return 1
  [[ "$(stat -c %s -- "$dir/manifest.sig.bin")" == 64 ]] || return 1
  for key in "${MANAGER_UPDATE_TRUSTED_KEYS[@]}"; do
    n=$((n + 1))
    printf '%s' "$key" | base64 -d > "$dir/trusted-key-$n.der" 2>/dev/null || continue
    openssl pkey -pubin -inform DER -in "$dir/trusted-key-$n.der" -out "$dir/trusted-key-$n.pem" 2>/dev/null || continue
    # -rawin accepts only EdDSA keys; with a 64-byte signature that is Ed25519.
    if openssl pkeyutl -verify -pubin -inkey "$dir/trusted-key-$n.pem" -rawin \
         -in "$manifest" -sigfile "$dir/manifest.sig.bin" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

manager_release_manifest_fields() { # $1=verified manifest $2=release tag -> "commit sha256 size release_version"
  jq -er --arg format "$MANAGER_RELEASE_FORMAT" --arg slug "$MANAGER_REPO_SLUG" --arg tag "$2" \
    --argjson max "$MANAGER_ARTIFACT_MAX_BYTES" '
    def ok:
      type == "object"
      and (keys == ["artifact","channel","commit","format","release_version","repository","tag","version"])
      and .format == $format and .repository == $slug and .channel == "stable"
      and (.version | type) == "string" and (.version | test("^[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,6}$"))
      and .tag == $tag and .tag == ("v" + .version)
      and (.release_version | type) == "string" and (.release_version | test("^[0-9A-Za-z.+-]{1,64}$"))
      and (.version as $v | .release_version == $v or (.release_version | startswith($v + "-")))
      and (.commit | type) == "string" and (.commit | test("^[0-9a-f]{40}$"))
      and (.artifact | type) == "object" and ((.artifact | keys) == ["name","sha256","size"])
      and .artifact.name == "twebproxy-manager.sh"
      and (.artifact.sha256 | type) == "string" and (.artifact.sha256 | test("^[0-9a-f]{64}$"))
      and (.artifact.size | type) == "number" and .artifact.size == (.artifact.size | floor)
      and .artifact.size > 0 and .artifact.size <= $max;
    if ok then [.commit, .artifact.sha256, (.artifact.size | tostring), .release_version] | join(" ")
    else empty end' "$1" 2>/dev/null
}

manager_candidate_identity_ok() { # $1=file $2=version [$3=exact release label]: syntax and embedded identity
  local file="$1" version="$2" label="${3:-}" versions labels
  bash -n "$file" 2>/dev/null || return 1
  versions="$(sed -nE 's/^MANAGER_VERSION="([^"]*)"$/\1/p' "$file")"
  labels="$(sed -nE 's/^MANAGER_RELEASE_VERSION="([^"]*)"$/\1/p' "$file")"
  [[ "$versions" == "$version" ]] || return 1
  [[ "$labels" != *$'\n'* && ( "$labels" == "$version" || "$labels" == "$version"-* ) ]] || return 1
  [[ -z "$label" || "$labels" == "$label" ]]
}

manager_check_update_impl() {
  local allow_cache="${1:-yes}"
  if ! fetch_manager_update_info "$allow_cache"; then
    warn "Не удалось получить последний стабильный релиз TWebProxy Manager с $MANAGER_REPO_URL: релиз не опубликован, ответ некорректен или сеть недоступна."
    return 2
  fi

  echo "Manager:  local=$MANAGER_VERSION remote=$REMOTE_MANAGER_VERSION source=$REMOTE_MANAGER_SOURCE ref=$REMOTE_MANAGER_REF"
  if version_is_newer "$REMOTE_MANAGER_VERSION" "$MANAGER_VERSION"; then
    warn "Доступна новая версия TWebProxy Manager: $REMOTE_MANAGER_VERSION"
    if (( ${#MANAGER_UPDATE_TRUSTED_KEYS[@]} == 0 )); then
      warn "В этой сборке не закреплён ключ подписи релизов: manager-update установит релиз только с --sha256, полученным из независимого источника (docs/UPDATES.md)."
    fi
    [[ "$UI_LANGUAGE" == en ]] && echo "Update: sudo twebproxy manager-update" || echo "Обновить: sudo twebproxy manager-update"
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
  local new_version="$1" upstream=unknown mtcommit="$MTPROXY_COMMIT" content tmp
  [[ -f "$GLOBAL_ENV" ]] || return 0
  upstream="$( (unset TPROXY_UPSTREAM_COMMIT; source "$GLOBAL_ENV"; printf '%s' "${TPROXY_UPSTREAM_COMMIT:-unknown}") )"
  mtcommit="$( (unset MTPROXY_COMMIT; source "$GLOBAL_ENV"; printf '%s' "${MTPROXY_COMMIT:-$mtcommit}") )"
  content="$(printf 'MANAGER_VERSION=%q\nTPROXY_UPSTREAM_COMMIT=%q\nMTPROXY_COMMIT=%q' "$new_version" "$upstream" "$mtcommit")" || return 1
  # Written beside the file, verified, then renamed: a failed write (disk full)
  # leaves the previous global.env intact.
  tmp="$(mktemp "$(dirname -- "$GLOBAL_ENV")/.global.env.XXXXXX")" || return 1
  if printf '%s\n' "$content" > "$tmp" && chmod 0600 "$tmp" \
     && [[ "$(cat -- "$tmp")" == "$content" ]] && mv -fT -- "$tmp" "$GLOBAL_ENV"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Private root-only staging for one manager-update, beside the backup root. A
# staging directory or install temp file left by an update that was killed is
# removed here, under the update lock (no other update can own it).
stage4_update_prepare() {
  local staging="$UPDATE_BACKUP_PARENT/update-staging" dir stale
  stage4_backup_parent_ready || return 1
  if [[ -e "$staging" || -L "$staging" ]]; then
    [[ -d "$staging" && ! -L "$staging" ]] || return 1
    rm -rf --one-file-system -- "$staging" || return 1
  fi
  for dir in "$(dirname -- "$MANAGER_BIN")" "$(dirname -- "$PROJECT_MANAGER_COPY")"; do
    for stale in "$dir"/.twebproxy-stage4.?????? "$dir"/.twebproxy-copy.??????; do
      if [[ -f "$stale" && ! -L "$stale" ]]; then rm -f -- "$stale"; fi
    done
  done
  install -d -o root -g root -m 0700 "$staging" || return 1
  printf '%s' "$staging"
}

stage4_update_end() { # removes the staging directory, restores the signals, releases the lock
  rm -rf --one-file-system -- "$UPDATE_BACKUP_PARENT/update-staging" 2>/dev/null || true
  trap - EXIT INT TERM HUP
  stage4_release_update_lock
}

stage4_update_abort() { # $1=exit status: interrupted before any manager copy was touched
  stage4_update_end
  exit "$1"
}

stage4_update_refuse() { # $1=reason $2=message: the update is refused, no manager copy touched
  printf 'UPDATE_REFUSED reason=%s\n' "$1" >&2
  die "$2"
}

manager_update_cmd() {
  [[ ! -e "$BASE_DIR/bridge/node.json" ]] || die "Remove/detach Bridge before Manager version update/rollback (Gate2 compatibility guard)."
  need_root; banner
  local force=0 pinned="" pinned_given=0 work version tag trust url expected size="" label="" fields commit actual
  local backup_id="" old_hash="" outcome
  while (( $# )); do
    case "$1" in
      --force) force=1;;
      --sha256)
        [[ $# -ge 2 ]] || stage4_update_refuse usage "Значение --sha256 должно состоять из 64 шестнадцатеричных символов."
        pinned="$2"; pinned_given=1; shift;;
      --sha256=*) pinned="${1#--sha256=}"; pinned_given=1;;
      '') ;;
      *) stage4_update_refuse usage "Неизвестный параметр manager-update: $1. Допустимо: --force, --sha256 <SHA-256>.";;
    esac
    shift
  done
  pinned="${pinned,,}"
  (( ! pinned_given )) || [[ "$pinned" =~ ^[0-9a-f]{64}$ ]] \
    || stage4_update_refuse usage "Значение --sha256 должно состоять из 64 шестнадцатеричных символов."

  stage4_acquire_update_lock || die "Manager update уже выполняется или lock небезопасен: $UPDATE_LOCK_FILE"
  trap 'stage4_update_end' EXIT
  trap 'stage4_update_abort 130' INT; trap 'stage4_update_abort 143' TERM; trap 'stage4_update_abort 129' HUP
  # Children run without descriptor 9 (the lock) unless they need it: a child
  # that outlives a killed updater must not keep the lock.
  work="$(exec 9>&-; stage4_update_prepare)" \
    || die "Закрытый каталог обновления в $UPDATE_BACKUP_PARENT не подготовлен; manager не изменён."
  stage4_install_restore_helper refresh || die "Offline rollback helper отсутствует или небезопасен; обновление остановлено до создания backup."
  stage4_current_manager_preflight \
    || die "Текущие manager-копии не образуют точное безопасное состояние; обновление остановлено до создания backup. Если прошлое обновление было прервано, восстанови проверенную копию без сети: $UPDATE_RESTORE_HELPER restore-latest"

  fetch_manager_update_info no \
    || stage4_update_refuse release "Не удалось получить последний стабильный релиз TWebProxy Manager с $MANAGER_REPO_URL: релиз не опубликован, ответ некорректен или сеть недоступна."
  version="$REMOTE_MANAGER_VERSION"; tag="$REMOTE_MANAGER_REF"
  if (( ! force )) && ! version_is_newer "$version" "$MANAGER_VERSION"; then
    if [[ "$version" == "$MANAGER_VERSION" ]]; then
      ok "TWebProxy Manager $MANAGER_VERSION уже актуален."
      stage4_update_end
      return 0
    fi
    die "Опубликованная версия $version не новее локальной $MANAGER_VERSION. Для принудительной установки: manager-update --force"
  fi

  # Trust: a manifest signed by a pinned key (required whenever a key is
  # pinned), else an operator-pinned SHA-256; nothing else is authentication.
  if (( ${#MANAGER_UPDATE_TRUSTED_KEYS[@]} )); then
    trust="signed-release"
    manager_release_download "$MANAGER_REPO_URL/releases/download/$tag/$MANAGER_RELEASE_MANIFEST" "$work/manifest.json" 65536 assets \
      && manager_release_download "$MANAGER_REPO_URL/releases/download/$tag/$MANAGER_RELEASE_MANIFEST.sig" "$work/manifest.json.sig" 4096 assets \
      || stage4_update_refuse download "Релиз $tag не публикует подписанный манифест ($MANAGER_RELEASE_MANIFEST и .sig) по ожидаемому адресу GitHub; manager не изменён."
    manager_release_signature_ok "$work/manifest.json" "$work/manifest.json.sig" "$work" \
      || stage4_update_refuse signature "Подпись манифеста релиза $tag не подтверждена закреплённым ключом; manager не изменён."
    fields="$(exec 9>&-; manager_release_manifest_fields "$work/manifest.json" "$tag")" \
      || stage4_update_refuse manifest "Манифест релиза $tag некорректен или не соответствует релизу; manager не изменён."
    read -r commit expected size label <<< "$fields"
    [[ -z "$pinned" || "$pinned" == "$expected" ]] \
      || stage4_update_refuse digest "SHA-256 из --sha256 не совпадает с подписанным манифестом релиза $tag; manager не изменён."
    url="$MANAGER_RAW_URL/$commit/twebproxy-manager.sh"
  elif [[ -n "$pinned" ]]; then
    trust="operator-sha256"
    expected="$pinned"
    url="$MANAGER_RAW_URL/$tag/twebproxy-manager.sh"
  else
    stage4_update_refuse no-trust-anchor "Доступна версия $version, но в этой сборке не закреплён ключ подписи релизов, а SHA256SUMS из того же источника не подтверждает подлинность. Автоматическое обновление отключено: укажи --sha256 <SHA-256 из независимого источника> или обнови вручную (docs/UPDATES.md)."
  fi

  log "Скачиваю TWebProxy Manager $version ($tag, trust=$trust)..."
  manager_release_download "$url" "$work/twebproxy-manager.sh" "$MANAGER_ARTIFACT_MAX_BYTES" direct \
    || stage4_update_refuse download "Не удалось скачать manager $version с $url без переадресации; manager не изменён."
  actual="$(sha256sum "$work/twebproxy-manager.sh" | awk '{print $1}')"
  [[ "$actual" == "$expected" && ( -z "$size" || "$(stat -c %s -- "$work/twebproxy-manager.sh")" == "$size" ) ]] \
    || stage4_update_refuse digest "SHA-256 скачанного manager не совпадает с доверенным значением ($trust); manager не изменён."
  manager_candidate_identity_ok "$work/twebproxy-manager.sh" "$version" "$label" \
    || stage4_update_refuse identity "Скачанный manager не проходит bash -n или его MANAGER_VERSION / MANAGER_RELEASE_VERSION не соответствуют релизу $tag; manager не изменён."
  chmod 0600 "$work/twebproxy-manager.sh"

  # The downloaded script has not executed at this point. Publish and verify
  # the exact pre-update payload before the first target mutation.
  old_hash="$(sha256sum "$MANAGER_BIN" | awk '{print $1}')"
  backup_id="$(exec 9>&-; stage4_create_backup "$version")" \
    || die "Не удалось создать и проверить локальный pre-update backup; manager не изменён."
  log "Проверенный pre-update backup: $backup_id"

  # From the first copy to a verified outcome an interruption must not leave the
  # copies mixed: INT, TERM, HUP and PIPE (a vanished terminal) are ignored by
  # this process and by every step it runs, the rollback helper included.
  trap '' INT TERM HUP PIPE
  if stage4_install_candidate_target "$work/twebproxy-manager.sh" "$MANAGER_BIN" "$actual" \
     && stage4_install_candidate_target "$work/twebproxy-manager.sh" "$PROJECT_MANAGER_COPY" "$actual" \
     && stage4_manager_health "$actual" "$version"; then
    outcome=success
  elif stage4_manager_copies_match "$old_hash"; then
    outcome=unchanged
  else
    warn "Установка или bounded health-check не завершились. Выполняю один exact rollback: $backup_id" || true
    stage4_rollback_exact "$backup_id" > "$work/rollback.log" 2>&1 || true
    # The outcome is what the installed copies prove, not the helper's status.
    if stage4_manager_health "$old_hash" "$MANAGER_VERSION"; then outcome=rolled-back; else outcome=rollback-failed; fi
  fi
  trap 'stage4_update_abort 130' INT; trap 'stage4_update_abort 143' TERM; trap 'stage4_update_abort 129' HUP; trap - PIPE

  case "$outcome" in
    unchanged)
      warn "Новая версия не установлена; обе копии TWebProxy Manager не изменялись (проверено по SHA-256). Проверенная резервная копия сохранена: $backup_id"
      printf 'UPDATE_FAILED_UNCHANGED backup_id=%s\n' "$backup_id"
      stage4_update_end
      return 1;;
    rolled-back)
      [[ ! -s "$work/rollback.log" ]] || cat -- "$work/rollback.log"
      stage4_prune_backups "$backup_id" || warn "Не удалось выполнить retention проверенных backup; содержимое оставлено без изменений."
      printf 'UPDATE_FAILED_ROLLBACK_SUCCESS backup_id=%s\n' "$backup_id"
      stage4_update_end
      return 1;;
    rollback-failed)
      # No retention here: older verified backups may be the way back.
      [[ ! -s "$work/rollback.log" ]] || cat -- "$work/rollback.log" >&2
      printf 'UPDATE_FAILED_ROLLBACK_FAILED backup_id=%s\n' "$backup_id" >&2
      warn "Откат не подтверждён. Восстанови TWebProxy Manager без сети: $UPDATE_RESTORE_HELPER restore $backup_id (или restore-latest; список: $UPDATE_RESTORE_HELPER list)."
      stage4_update_end
      return 1;;
  esac

  if ! set_global_manager_version "$version"; then
    warn "Manager обновлён, но не удалось обновить metadata в global.env; следующий repair исправит metadata."
  fi
  rm -f "$UPDATE_CACHE_FILE" || warn "Manager обновлён, но update cache не удалён."
  stage4_prune_backups "$backup_id" || warn "Manager обновлён, но retention проверенных backup не выполнен."
  stage4_update_end
  ok "TWebProxy Manager обновлён: $MANAGER_VERSION -> $version"
  printf 'UPDATE_SUCCESS backup_id=%s\n' "$backup_id"
}

fetch_manager_update_hint_info() {
  local tag
  if load_manager_update_cache; then
    return 0
  fi
  # The automatic hint is deliberately cheap: one short request for the latest
  # stable release (never a development branch).
  tag="$(exec 9>&-; manager_latest_release_tag 2 3 twebproxy-manager-update-hint)" || return 1
  REMOTE_MANAGER_VERSION="${tag#v}"
  REMOTE_MANAGER_REF="$tag"
  REMOTE_MANAGER_SOURCE="release"
  write_manager_update_cache "$REMOTE_MANAGER_VERSION" "$tag" release
}

manager_update_hint() {
  # At most one quick check per interactive process. GitHub outage must never
  # make every menu redraw slow or prevent normal administration.
  (( MANAGER_UPDATE_HINT_ATTEMPTED == 0 )) || return 0
  MANAGER_UPDATE_HINT_ATTEMPTED=1
  if fetch_manager_update_hint_info 2>/dev/null && version_is_newer "$REMOTE_MANAGER_VERSION" "$MANAGER_VERSION"; then
    if [[ "$UI_LANGUAGE" == en ]]; then
      printf "%b[update]%b TWebProxy Manager %s is available (current %s). Command: twebproxy manager-update\n\n" \
        "$C_YELLOW" "$C_RESET" "$REMOTE_MANAGER_VERSION" "$MANAGER_VERSION"
    else
      printf "%b[update]%b Доступен TWebProxy Manager %s (сейчас %s). Команда: twebproxy manager-update\n\n" \
        "$C_YELLOW" "$C_RESET" "$REMOTE_MANAGER_VERSION" "$MANAGER_VERSION"
    fi
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
  need_root; need_systemd; ui_language_ensure_interactive_install; check_platform; banner
  check_no_legacy_v1
  local site_bundle; site_bundle="$(default_site_bundle_dir)"
  [[ ! -f "$site_bundle/MANIFEST.json" ]] || default_site_action verify >/dev/null || die "Default site bundle verification failed before installation."
  install_base_deps
  prepare_users_and_dirs
  proc_hardening_ensure || proc_fail_closed
  stage4_install_restore_helper yes || die "Не удалось установить безопасный offline rollback helper."
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
  if [[ -f "$BASE_DIR/bridge/node.json" ]]; then
    local brc=0
    python3 -c 'import json,sys
try:
 s=json.load(open(sys.argv[1])); used=[s["entry"]["local_port"],s["previous_port"]]; sys.exit(0 if int(sys.argv[2]) in used else 1)
except Exception:sys.exit(2)' "$BASE_DIR/bridge/node.json" "$needle" || brc=$?
    case "$brc" in 0) return 0;; 1) ;; *) warn "Bridge allocation state unknown; port allocation blocked." >&2; return 2;; esac
  fi
  shopt -s nullglob
  # The authoritative profile record counts even when its derived backend env
  # is missing (interrupted commit): such a port is never handed out twice.
  for f in "$INSTANCES_DIR"/*/profiles.d/*.env; do
    if ( unset BACKEND_PORT STATS_PORT; source "$f"; [[ "${BACKEND_PORT:-}" == "$needle" || "${STATS_PORT:-}" == "$needle" ]] ); then
      shopt -u nullglob; return 0
    fi
  done
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

# 0 = a TCP listener uses port $1, 1 = none does, 2 = unknown because ss
# failed. The whole ss output is captured first: an early-exiting pipeline
# reader under pipefail (SIGPIPE) made occupied ports look free.
port_listening() {
  local p="$1" out local_addr
  if ! out="$(ss -H -ltn 2>/dev/null)"; then
    warn "Не удалось получить список TCP listeners (ss); порт не считается свободным." >&2
    return 2
  fi
  while read -r _ _ _ local_addr _; do
    [[ "$local_addr" == *":$p" ]] && return 0
  done <<< "$out"
  return 1
}

# Free only when valid, not registered by TWebProxy and positively not
# listened on; an ss failure is never proof of a free port (rc 2).
port_available() {
  local p rc=0
  is_valid_port "$1" || return 1
  p="$((10#$1))"
  local registered_rc=0
  port_registered "$p" || registered_rc=$?
  case "$registered_rc" in 0) return 1;; 1) ;; *) return 2;; esac
  port_listening "$p" || rc=$?
  case "$rc" in 0) return 1;; 1) return 0;; *) return 2;; esac
}

next_free_port() {
  local start="$1" end="${2:-65535}" p rc
  for ((p=start; p<=end; p++)); do
    rc=0; port_available "$p" || rc=$?
    case "$rc" in 0) printf '%s' "$p"; return 0;; 2) return 2;; esac
  done
  return 1
}

ask_internal_port() {
  local label="$1" default="$2" p
  while true; do
    p="$(ask "$label" "$default")" || return $?
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
  local cm chooser=choose
  (( ! TUI_ACTIVE )) || chooser=tui_preset_choose
  cm="$("$chooser" "$(ui_msg smart_carrier_title)" \
    "$(ui_msg smart_carrier_https)" "$(ui_msg smart_carrier_lanes)" \
    "$(ui_msg smart_carrier_ws)" "$(ui_msg smart_carrier_ws_lanes)")" || return $?
  case "$cm" in 1) printf https;; 2) printf https-lanes;; 3) printf websocket;; 4) printf websocket-lanes;; esac
}

# Versioned distribution assets; live per-domain website files are never an update target.
DEFAULT_SITE_MANIFEST_SHA256="988bf2a45f56d7fc1dd795d1ddaed766e7a5dff44294a96b46352a2b7075efe8"
default_site_bundle_dir() {
  local adjacent="$(dirname "${BASH_SOURCE[0]}")/sites/podmoskovye"
  if [[ -f "$adjacent/MANIFEST.json" ]]; then printf '%s' "$adjacent"; else printf '%s/default-site-%s' "$PROJECT_DIR" "$DEFAULT_SITE_MANIFEST_SHA256"; fi
}
default_site_action() { # verify | install | deploy; target is an owned cache/new site
  local op="$1" target="${2:-}" bundle
  bundle="$(default_site_bundle_dir)"
  python3 - "$bundle" "$DEFAULT_SITE_MANIFEST_SHA256" "$op" "$target" <<'PY_SITE'
import hashlib,json,os,shutil,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]);expected,op=sys.argv[2:4];target=Path(sys.argv[4]) if sys.argv[4] else None
try:
 if root.is_symlink():raise ValueError('site bundle symlink refused')
 raw=(root/'MANIFEST.json').read_bytes()
 if hashlib.sha256(raw).hexdigest()!=expected:raise ValueError('default website manifest mismatch')
 records=json.loads(raw)
 def verify(base):
  files=set()
  for p in base.rglob('*'):
   if p.is_symlink():raise ValueError('site bundle symlink refused')
   if p.is_file():files.add(str(p.relative_to(base)))
  if files!=set(records)|{'MANIFEST.json'}:raise ValueError('unmanifested default website component')
  for name,sha in records.items():
   if Path(name).is_absolute() or '..' in Path(name).parts:raise ValueError('unsafe website path')
   if hashlib.sha256((base/name).read_bytes()).hexdigest()!=sha:raise ValueError('default website component digest mismatch: '+name)
 verify(root)
 if op=='verify':print(json.dumps({'verified':True,'bundle_sha256':expected}));sys.exit(0)
 if op not in ('install','deploy') or target is None:raise ValueError('invalid site action')
 if target.is_symlink():raise ValueError('live website symlink refused; files preserved')
 if target.exists() and any(target.iterdir()):
  if op=='install':verify(target)
  elif not (target/'index.html').is_file():raise ValueError('existing nonempty website has no index; files preserved')
  print(json.dumps({'preserved':True,'bundle_sha256':expected}));sys.exit(0)
 target.parent.mkdir(parents=True,exist_ok=True,mode=0o755)
 tmp=Path(tempfile.mkdtemp(prefix='.default-site-',dir=target.parent))
 try:
  for name in records:
   dst=tmp/name;dst.parent.mkdir(parents=True,exist_ok=True,mode=0o755);shutil.copyfile(root/name,dst);dst.chmod(0o644)
  if op=='install':shutil.copyfile(root/'MANIFEST.json',tmp/'MANIFEST.json');(tmp/'MANIFEST.json').chmod(0o644)
  tmp.chmod(0o755)
  for d in tmp.rglob('*'):
   if d.is_dir():d.chmod(0o755)
  # A concurrent nonempty target makes rename fail; it is never removed.
  os.rename(tmp,target)
 finally:
  if tmp.exists():shutil.rmtree(tmp)
 print(json.dumps({'deployed':True,'schema':'twebproxy.default-site.v1','bundle_sha256':expected,'files':records}))
except Exception as e:
 print('Default website: '+str(e),file=sys.stderr);sys.exit(1)
PY_SITE
}
install_default_site_bundle() {
  local bundle; bundle="$(default_site_bundle_dir)"
  [[ -f "$bundle/MANIFEST.json" ]] || return 0 # custom-site single-file installs stay supported
  default_site_action install "$PROJECT_DIR/default-site-$DEFAULT_SITE_MANIFEST_SHA256" >/dev/null
}
make_unique_placeholder() { # compatibility name for old SITE_MODE=placeholder records
  local host="$1" result
  result="$(default_site_action deploy "$(site_dir "$host")")" || die "Default website unavailable or changed; use the complete verified Manager distribution. Existing files preserved."
  if [[ "$result" == *'"deployed": true'* ]]; then
    state_write_file "$(instance_dir "$host")/default-site.json" 0600 printf '%s\n' "$result" || return 1
  fi
}

prepare_site_for_instance() {
  local host="$1" d tmp; d="$(site_dir "$host")"
  case "$SITE_MODE" in
    default|placeholder) make_unique_placeholder "$host" ;;
    directory)
      if [[ -e "$d" ]]; then
        [[ -d "$d" && ! -L "$d" && -r "$d/index.html" ]] || die "Existing website preserved; readable index.html required in $d."
        return 0
      fi
      [[ -d "$SOURCE_SITE_DIR" && -r "$SOURCE_SITE_DIR/index.html" ]] || die "В $SOURCE_SITE_DIR нет читаемого index.html."
      install -d -m 0755 "${d%/*}"
      tmp="$(mktemp -d "${d%/*}/.custom-site.XXXXXX")" || return 1
      if cp -a "$SOURCE_SITE_DIR/." "$tmp/" && chown -R root:root "$tmp" &&
         find "$tmp" -type d -exec chmod 0755 {} + && find "$tmp" -type f -exec chmod 0644 {} + &&
         chmod 0755 "$tmp" && mv -T -- "$tmp" "$d"; then :
      else rm -rf -- "$tmp"; die "Custom website deployment failed; existing files preserved."; fi
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
    default|placeholder|directory) source_line="\"public_dir\": \"$(site_dir "$host")\"," ;;
    upstream) source_line="\"public_upstream\": \"$SITE_UPSTREAM\"," ;;
    *) die "Неизвестный SITE_MODE=$SITE_MODE" ;;
  esac
  state_write_file "$d/config.json" 0600 cat <<EOF || die "Не удалось записать состояние: $d/config.json"
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
  # can remain root-only (state_write_file: root:root 0600) and no root-owned
  # state directory needs to be traversable by the tproxy account.
}

# One profiles.json entry, read in a subshell from a verified record.
render_profile_json_entry() ( # $1=host $2=profile
  load_profile "$1" "$2"
  profile_record_valid "$2" || exit 1
  jq -cn --arg n "$PROFILE_NAME" --arg s "$SECRET" --arg b "127.0.0.1:$BACKEND_PORT" --arg c "$CARRIER_MODE" \
    '{name:$n,secret:$s,backend:$b,carrier_mode:$c}'
)

# Regenerates profiles.json without touching the caller's profile globals;
# returns non-zero (old file kept) when a record or the write fails.
rebuild_profiles_json() {
  local host="$1" d p entry arr='[]' profiles=()
  d="$(profile_dir "$host")"
  [[ -d "$d" ]] || die "Нет каталога профилей у $host"
  while read -r p; do [[ -n "$p" ]] && profiles+=("$p"); done < <(list_profiles_array "$host")
  ((${#profiles[@]} > 0)) || die "У $host должен оставаться хотя бы один профиль."
  for p in "${profiles[@]}"; do
    entry="$(render_profile_json_entry "$host" "$p")" || return 1
    arr="$(jq -c --argjson a "$arr" --argjson e "$entry" '$a + [$e]' <<<null)" || return 1
  done
  state_write_file "$(profiles_json "$host")" 0400 jq -n --argjson profiles "$arr" '{profiles:$profiles}'
}

validate_instance() {
  local host="$1"
  "$TPROXY_BIN" -config "$(instance_dir "$host")/config.json" -profiles-file "$(profiles_json "$host")" -check >/dev/null
}

wait_profile_backend_ready() {
  local host="$1" profile="$2" id unit i port
  id="$(backend_id "$host" "$profile")"
  unit="twebproxy-mtproxy@$id.service"
  port="$(load_profile "$host" "$profile"; printf '%s' "$BACKEND_PORT")" || die "Профиль $profile не найден у $host"
  for i in {1..15}; do
    if systemctl is-active --quiet "$unit" && port_listening "$port" 2>/dev/null; then
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
  proc_secret_safe || proc_fail_closed
  systemctl reset-failed "twebproxy-mtproxy@$id.service" >/dev/null 2>&1 || true
  systemctl enable --now "twebproxy-mtproxy@$id.service" >/dev/null
  systemctl restart "twebproxy-mtproxy@$id.service"
  wait_profile_backend_ready "$host" "$profile"
}

# Stops and disables one MTProxy backend unit and proves it is down: the stop
# must succeed and systemd must then report the unit inactive or failed.
# Anything else (failed stop, (de)activating, unknown, a systemctl error) is
# "not proven stopped": callers then keep its env file, and with it the
# backend firewall protection of its ports.
stop_backend_unit() { # $1=backend id
  local unit="twebproxy-mtproxy@$1.service" state=""
  systemctl disable --now "$unit" >/dev/null 2>&1 || return 1
  state="$(systemctl is-active "$unit" 2>/dev/null)" || true
  [[ "$state" == inactive || "$state" == failed ]]
}

stop_profile_backend() {
  local host="$1" profile="$2"
  stop_backend_unit "$(backend_id "$host" "$profile")"
}

# A backend id is <host>--<profile> and both parts may contain "--", so one id
# can name several (hostname, profile) pairs. Prints every split into a valid
# hostname and a valid profile name, one "host profile" per line.
backend_id_owners() { # $1=id
  local rest="$1" pre="" h p
  while [[ "$rest" == *--* ]]; do
    h="$pre${rest%%--*}"; p="${rest#*--}"
    if is_valid_hostname "$h" && is_valid_profile_name "$p"; then printf '%s %s\n' "$h" "$p"; fi
    pre="$h--"; rest="$p"
  done
  return 0
}

# "id host profile" for every live profile record of every instance.
live_backend_pairs() {
  local h q
  while read -r h; do
    [[ -n "$h" ]] || continue
    while read -r q; do
      [[ -n "$q" ]] && printf '%s %s %s\n' "$(backend_id "$h" "$q")" "$h" "$q"
    done < <(list_profiles_array "$h")
  done < <(list_hosts_array)
  return 0
}

# Backend ids of $1 that another live pair also produces (state written by an
# earlier version: one env file and one unit serving two owners).
shared_backend_ids() { # $1=host
  live_backend_pairs | awk -v h="$1" '{n[$1]++; if ($2 == h) mine[$1] = 1} END {for (i in mine) if (n[i] > 1) print i}'
}

# Every mutation of an instance first refuses such shared ownership: rewriting,
# stopping or removing the backend would also act on the other owner.
require_unshared_backends() { # $1=host
  local ids
  ids="$(shared_backend_ids "$1" | sort | paste -sd' ' -)"
  [[ -z "$ids" ]] || die "Backend $ids одновременно принадлежит профилям разных инстансов; ничего не изменено. Нужно ручное разрешение конфликта имён."
}

# A new pair may take its backend id only if no other live pair produces it.
backend_id_used_by_other() { # $1=host $2=profile
  local id; id="$(backend_id "$1" "$2")"
  live_backend_pairs | awk -v id="$id" -v h="$1" -v p="$2" '$1 == id && !($2 == h && $3 == p) {f = 1} END {exit !f}'
}

# Existing instances whose hostname is a "--" extension of $1 or vice versa:
# their backend ids could alias, so such a hostname is never created.
# Live hosts whose backend ids can coincide with those of $1: H and H--X collide
# exactly when X--<profile> is itself a valid profile name (X has no dot etc.).
overlapping_hosts() { # $1=host
  local h
  while read -r h; do
    [[ -n "$h" && "$h" != "$1" ]] || continue
    if { [[ "$h" == "$1--"* ]] && is_valid_profile_name "${h#"$1--"}--x"; } ||
       { [[ "$1" == "$h--"* ]] && is_valid_profile_name "${1#"$h--"}--x"; }; then printf '%s\n' "$h"; fi
  done < <(list_hosts_array)
  return 0
}

# Backend env files named $1--<profile> that no live profile record owns:
# "orphan <id>" when the name splits only one way, as this instance, else
# "ambiguous <id>" (it may belong to another, possibly deleted, instance).
# Symlinks and names outside the profile-name grammar are never candidates.
orphan_backend_ids() { # $1=host
  local host="$1" f id
  local -A live=()
  while read -r id _; do [[ -n "$id" ]] && live["$id"]=1; done < <(live_backend_pairs)
  for f in "$BACKENDS_DIR/$host--"*.env; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    id="${f##*/}"; id="${id%.env}"
    is_valid_profile_name "${id#"$host--"}" || continue
    [[ -z "${live[$id]:-}" ]] || continue
    if [[ "$(backend_id_owners "$id")" == "$host ${id#"$host--"}" ]]; then
      printf 'orphan %s\n' "$id"
    else
      printf 'ambiguous %s\n' "$id"
    fi
  done
}

# Orphans of $1 (left by an interrupted removal) are removed only after their
# unit is proven stopped; the caller rebuilds the firewall afterwards. An
# orphan that cannot be proven stopped, or whose owner cannot be proven, keeps
# its env file and protection, and the call fails.
reconcile_orphan_backends() { # $1=host
  local kind id rc=0
  while read -r kind id; do
    [[ -n "$id" ]] || continue
    if [[ "$kind" != orphan ]]; then
      warn "Backend env $id нельзя однозначно отнести к $1: имя может принадлежать другому инстансу; файл и защита firewall сохранены." >&2
      rc=1; continue
    fi
    if stop_backend_unit "$id"; then
      rm -f -- "$BACKENDS_DIR/$id.env" || rc=1
      log "Backend twebproxy-mtproxy@$id.service без профиля остановлен; его env удалён."
    else
      warn "Backend twebproxy-mtproxy@$id.service без профиля не остановлен или его состояние неизвестно; его env и защита firewall сохранены." >&2
      rc=1
    fi
  done < <(orphan_backend_ids "$1")
  return "$rc"
}

start_all_backends() {
  local host="$1" p
  while read -r p; do [[ -n "$p" ]] && start_profile_backend "$host" "$p"; done < <(list_profiles_array "$host")
}

# Bounded wait until the relay of $1 answers /readyz. A refused connection
# (relay not listening yet) is retried like any other failure.
relay_wait_ready() { # $1=host
  local admin i
  admin="$(load_instance "$1" >/dev/null 2>&1; printf '%s' "${ADMIN_PORT:-}")"
  [[ "$admin" =~ ^[0-9]+$ ]] || return 1
  for ((i = 0; i < RELAY_READY_WAIT_SECONDS; i++)); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$admin/readyz" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

# One more look after all relays were restarted: still active and ready.
relay_verify() { # $1=host
  local admin
  admin="$(load_instance "$1" >/dev/null 2>&1; printf '%s' "${ADMIN_PORT:-}")"
  [[ "$admin" =~ ^[0-9]+$ ]] || return 1
  systemctl is-active --quiet "twebproxy@$1.service" &&
    curl -fsS --max-time 2 "http://127.0.0.1:$admin/readyz" >/dev/null 2>&1
}

restart_relay_wait_ready() {
  local host="$1" unit="twebproxy@$1.service"
  load_instance "$host"
  relay_lock_acquire || die "Другая операция обновляет или перезапускает relay; повтори позже."
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  if ! systemctl enable --now "$unit" >/dev/null || ! systemctl restart "$unit"; then
    systemctl --no-pager --full status "$unit" || true
    die "Не удалось перезапустить relay $unit."
  fi
  if ! relay_wait_ready "$host"; then
    systemctl --no-pager --full status "$unit" || true
    journalctl -u "$unit" -n 80 --no-pager || true
    die "Relay $host не стал ready."
  fi
  relay_lock_release
}

# Stops and disables the relay of $1 and proves it is not running (inactive or
# failed afterwards); anything else, including a systemctl error, is "not proven".
stop_relay_unit() { # $1=host
  local unit="twebproxy@$1.service" state=""
  systemctl disable --now "$unit" >/dev/null 2>&1 || true
  state="$(systemctl is-active "$unit" 2>/dev/null)" || true
  [[ "$state" == inactive || "$state" == failed ]]
}

# Replaces $TPROXY_BIN by renaming a complete copy written next to it, so a
# failed or interrupted write never leaves a partial binary in place.
relay_binary_install() { # $1=source binary
  local tmp
  tmp="$(mktemp "$TPROXY_BIN.new.XXXXXX")" || return 1
  if install -o root -g root -m 0755 "$1" "$tmp" && mv -f -T "$tmp" "$TPROXY_BIN"; then return 0; fi
  rm -f -- "$tmp"; return 1
}

# Durable copy of the installed relay binary (survives /tmp cleanup and an
# interrupted update); the rollback source of relay_update_apply.
relay_previous_save() { # -> path on stdout
  local dir="$PROJECT_DIR/relay" tmp
  install -d -o root -g root -m 0700 "$dir" || return 1
  tmp="$(mktemp "$dir/tproxy-server.previous.XXXXXX")" || return 1
  if install -o root -g root -m 0755 "$TPROXY_BIN" "$tmp" && cmp -s "$TPROXY_BIN" "$tmp" &&
     mv -f -T "$tmp" "$dir/tproxy-server.previous"; then
    printf '%s\n' "$dir/tproxy-server.previous"; return 0
  fi
  rm -f -- "$tmp"; return 1
}

# Installs a validated candidate and restarts every relay on it, one at a time;
# success only when all of them are verified ready on it. On the first failure,
# or once the caller's trap recorded an interruption, the previous binary is
# put back and every relay restarted so far is restarted on it and checked.
# Returns 0 updated; 1 rolled back, all ready; 2 rolled back, RELAY_UPDATE_NOTREADY
# not ready; 3 previous binary not restored; 4 candidate not written (no change).
# Every step is checked explicitly: callers run it in an || context.
relay_update_apply() { # $1=candidate $2=previous copy $3...=hosts
  local candidate="$1" prev="$2" host failed=0; shift 2
  local -a restarted=() notready=()
  RELAY_UPDATE_NOTREADY=""
  relay_binary_install "$candidate" || return 4
  for host in "$@"; do
    if (( RELAY_UPDATE_INTERRUPTED )); then break; fi
    restarted+=("$host")
    systemctl reset-failed "twebproxy@$host.service" >/dev/null 2>&1 || true
    if ! systemctl restart "twebproxy@$host.service" >/dev/null 2>&1; then
      warn "Relay twebproxy@$host.service не перезапустился с новым binary; восстанавливаю прежний relay binary."
      failed=1; break
    fi
    if ! relay_wait_ready "$host"; then
      warn "Relay $host не стал ready с новым binary; восстанавливаю прежний relay binary."
      failed=1; break
    fi
  done
  if (( ! failed && RELAY_UPDATE_INTERRUPTED )); then
    warn "Обновление relay прервано; восстанавливаю прежний relay binary."
    failed=1
  fi
  if (( ! failed )); then
    for host in "$@"; do
      relay_verify "$host" && continue
      warn "Relay $host перестал работать после обновления; восстанавливаю прежний relay binary."
      failed=1; break
    done
  fi
  (( failed )) || return 0
  if ! relay_binary_install "$prev"; then
    RELAY_UPDATE_NOTREADY="${restarted[*]}"; return 3
  fi
  for host in "${restarted[@]}"; do
    systemctl reset-failed "twebproxy@$host.service" >/dev/null 2>&1 || true
    if ! systemctl restart "twebproxy@$host.service" >/dev/null 2>&1 || ! relay_wait_ready "$host"; then
      notready+=("$host")
    fi
  done
  RELAY_UPDATE_NOTREADY="${notready[*]}"
  (( ${#notready[@]} == 0 )) && return 1
  return 2
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

# Replaces $2 by renaming a complete copy of $1 written in the same directory
# (symlinks resolved; mode and owner of an existing file kept, else mode $3),
# so a failed or interrupted write never leaves a partial file in place.
frontend_file_replace() { # $1=content file $2=target [$3=mode of a new file]
  local target tmp
  target="$(readlink -f -- "$2")" || return 1
  tmp="$(mktemp "${target%/*}/.twebproxy-tmp.XXXXXX")" || return 1
  if cat -- "$1" > "$tmp" &&
     if [[ -e "$target" ]]; then chmod --reference="$target" -- "$tmp" && chown --reference="$target" -- "$tmp"
     else chmod "${3:-0644}" -- "$tmp"; fi &&
     mv -f -T -- "$tmp" "$target"; then
    return 0
  fi
  rm -f -- "$tmp"; return 1
}

# Creates missing frontend directories (0755); existing ones keep their mode.
frontend_dirs() {
  local d
  for d; do [[ -d "$d" ]] || install -d -m 0755 -- "$d" || return 1; done
}

# A frontend change (swap, test, reload, rollback) always runs to its end: an
# INT/TERM/HUP meanwhile is only recorded and acted on once the files are
# consistent again. Callers run the change in an || context, so every step in
# it is checked explicitly.
frontend_signals_defer() { FRONTEND_INTERRUPTED=0; trap 'FRONTEND_INTERRUPTED=1' INT TERM HUP; }
frontend_signals_end() { # $1=outcome of the change (0 applied, 3 previous state not restored)
  trap - INT TERM HUP
  (( FRONTEND_INTERRUPTED )) || return 0
  case "$1" in
    0) die "Прервано: изменение frontend уже применено и проверено.";;
    3) die "Прервано: изменение frontend не применено, и прежнюю конфигурацию восстановить не удалось.";;
    *) die "Прервано: изменение frontend не применено, прежняя конфигурация восстановлена.";;
  esac
}

# Line range "first last" of the TWebProxy block of $1 in Caddyfile $2 (nothing
# when there is none). Fails, with the reason on stderr, when the markers that
# concern $1 are ambiguous: altered, duplicated, unpaired or interleaved with
# another block. Ownership is never guessed from such a file.
caddy_block_range() { # $1=host $2=file
  awk -v h="$1" '
    function fail(why) { print "line " NR ": " why > "/dev/stderr"; bad = 1; exit 1 }
    {
      line = $0; sub(/\r$/, "", line)
      if (line !~ /^[ \t]*#[ \t]*(BEGIN|END)[ \t]+TWEBPROXY([ \t]|$)/) next
      m = line; sub(/^[ \t]*#[ \t]*/, "", m); split(m, w, /[ \t]+/); k = w[1]; x = w[3]
      if (x == h && $0 != "# " k " TWEBPROXY " h) fail("altered marker of " h)
      if (k == "BEGIN") {
        if (cur != "" && (cur == h || x == h)) fail("BEGIN marker of " x " inside the block of " cur)
        if (cur == "") cur = x
        if (x == h) { if (pairs) fail("second block of " h); open = NR }
      } else {
        if (x == h) { if (cur != h) fail("END marker of " h " without BEGIN"); first = open; last = NR; pairs++ }
        else if (cur == h) fail("END marker of " x " inside the block of " h)
        if (x == cur) cur = ""
      }
    }
    END {
      if (bad) exit 1
      if (cur == h) { print "line " open ": BEGIN marker of " h " without END" > "/dev/stderr"; exit 1 }
      if (pairs) print first, last
    }' "$2"
}

# Removes the TWebProxy block of $1 (and the blank line written before it) from
# the private Caddyfile copy $2; fails, leaving $2 unchanged, if its markers are
# ambiguous.
remove_caddy_block() { # $1=host $2=file
  local range first last
  range="$(caddy_block_range "$1" "$2")" || return 1
  [[ -n "$range" ]] || return 0
  read -r first last <<<"$range"
  if awk -v a="$first" -v b="$last" 'NR < a - 1 || (NR == a - 1 && $0 != "") || NR > b' "$2" > "$2.cut" &&
     mv -f -T -- "$2.cut" "$2"; then
    return 0
  fi
  rm -f -- "$2.cut"; return 1
}

render_caddy_block() { # $1=host $2=relay port
  cat <<EOF
# BEGIN TWEBPROXY $1
$1 {
$(if [[ -n "${ACME_EMAIL:-}" ]]; then printf '    tls %s {\n        ca https://acme-v02.api.letsencrypt.org/directory\n    }\n' "$ACME_EMAIL"; fi)
    encode zstd gzip
    reverse_proxy 127.0.0.1:$2 {
        transport http {
            response_header_timeout 40s
        }
    }
    log {
        output discard
    }
}
# END TWEBPROXY $1
EOF
}

# Publishes candidate $1, a complete Caddyfile written next to the live one $2
# (so relative imports resolve alike): caddy validate, atomic swap, reload (or
# start). A failed activation puts the previous file back unchanged; Caddy keeps
# serving its previous configuration after a failed reload, so it is never
# restarted. The replaced file is kept as $2.twebproxy-previous.
# 0 published; 1 invalid (nothing changed); 2 not activated, previous file
# restored; 3 not activated and the previous file not restored.
caddy_publish() { # $1=candidate $2=live Caddyfile (symlinks resolved)
  local cand="$1" live="$2" prev="" out rc=0 swapped=0
  if ! out="$(caddy validate --config "$cand" --adapter caddyfile 2>&1)"; then
    printf '%s\n' "$out" | tail -n 8 >&2
    rm -f -- "$cand"; return 1
  fi
  if [[ -e "$live" ]]; then
    if ! prev="$(mktemp "${live%/*}/.twebproxy-previous.XXXXXX")" || ! cp -p -- "$live" "$prev" ||
       ! chmod --reference="$live" -- "$cand" || ! chown --reference="$live" -- "$cand"; then
      rm -f -- "$cand" "$prev"; return 2
    fi
  else
    chmod 0644 -- "$cand" || { rm -f -- "$cand"; return 2; }
  fi
  frontend_signals_defer
  if mv -f -T -- "$cand" "$live"; then
    swapped=1
    if systemctl is-active --quiet caddy; then
      systemctl reload caddy || rc=2
    else
      systemctl enable --now caddy || rc=2
    fi
  else
    rc=2
  fi
  if (( rc && swapped )); then
    if [[ -n "$prev" ]]; then mv -f -T -- "$prev" "$live" || rc=3; else rm -f -- "$live" || rc=3; fi
  fi
  if [[ -n "$prev" && -e "$prev" ]]; then mv -f -T -- "$prev" "$live.twebproxy-previous" || rm -f -- "$prev"; fi
  rm -f -- "$cand"
  frontend_signals_end "$rc"
  return "$rc"
}

# Removes the TWebProxy block of $1 from the live Caddyfile. 0 removed or none
# there; 1 ambiguous markers or the rest of the Caddyfile is invalid (nothing
# changed); 2 reload failed, previous file restored; 3 previous file not
# restored; 5 frontend lock busy (nothing changed).
caddy_remove_host() { # $1=host
  local live cand rc=0
  [[ -e "$CADDYFILE" ]] || return 0
  frontend_lock_acquire || return 5
  if ! live="$(readlink -f -- "$CADDYFILE")" || ! cand="$(mktemp "${live%/*}/.twebproxy-candidate.XXXXXX")"; then
    frontend_lock_release; return 1
  fi
  if ! cp -- "$live" "$cand" || ! remove_caddy_block "$1" "$cand"; then
    rc=1
  elif cmp -s -- "$live" "$cand"; then
    :
  else
    caddy_publish "$cand" "$live" || rc=$?
  fi
  rm -f -- "$cand"; frontend_lock_release
  return "$rc"
}

configure_caddy_host() {
  local host="$1" relay="$2" family live cand block rc=0
  family="$(managed_frontend_family)"
  [[ -z "$family" || "$family" == caddy ]] || die "Другой TWebProxy-инстанс уже использует Nginx на 80/443. Нельзя параллельно запустить managed Caddy."
  check_public_listener_owner caddy
  install_caddy
  frontend_dirs "$CADDY_DIR" || die "Не удалось подготовить candidate Caddyfile в $CADDY_DIR."
  # The Caddyfile is shared by all instances: read, change and publish it under one lock.
  frontend_lock_acquire || die "Конфигурацию frontend сейчас меняет другая операция; повтори позже."
  live="$(readlink -f -- "$CADDYFILE")" && cand="$(mktemp "${live%/*}/.twebproxy-candidate.XXXXXX")" ||
    die "Не удалось подготовить candidate Caddyfile в $CADDY_DIR."
  if [[ -e "$live" ]] && ! cp -- "$live" "$cand"; then
    rm -f -- "$cand"; die "Не удалось подготовить candidate Caddyfile в $CADDY_DIR."
  fi
  if ! remove_caddy_block "$host" "$cand"; then
    rm -f -- "$cand"
    die "Маркеры блока TWebProxy для $host в Caddyfile неоднозначны; Caddyfile не изменён. Исправь их вручную."
  fi
  if grep -Eq "^[[:space:]]*${host//./\\.}([[:space:]{,]|$)" "$cand"; then
    rm -f -- "$cand"
    die "В Caddyfile уже есть $host вне управляемого блока TWebProxy."
  fi
  block="$(mktemp)" || { rm -f -- "$cand"; die "Не удалось подготовить candidate Caddyfile в $CADDY_DIR."; }
  render_caddy_block "$host" "$relay" > "$block"
  # Format only the generated block. Never rewrite unrelated user-managed sites.
  caddy fmt --overwrite "$block" >/dev/null 2>&1 || true
  if ! { printf '\n'; cat -- "$block"; } >> "$cand"; then
    rm -f -- "$cand" "$block"; die "Не удалось подготовить candidate Caddyfile в $CADDY_DIR."
  fi
  rm -f -- "$block"
  caddy_publish "$cand" "$live" || rc=$?
  frontend_lock_release
  case "$rc" in
    0) ;;
    1) if [[ -e "$live" ]] && ! caddy validate --config "$live" --adapter caddyfile >/dev/null 2>&1; then
         die "Активный Caddyfile уже не проходит caddy validate; блок $host не добавлен, Caddyfile не изменён."
       fi
       die "Candidate Caddyfile не прошёл validate; активный Caddyfile не изменён.";;
    2) die "Caddy не применил новую конфигурацию $host; прежний Caddyfile восстановлен, Caddy работает с прежней конфигурацией.";;
    *) die "Caddy не применил новую конфигурацию $host, и прежний Caddyfile восстановить не удалось: проверь $CADDYFILE (прежняя версия рядом, *.twebproxy-previous).";;
  esac
}

nginx_common_install() {
  local family tmp map="$NGINX_DIR/conf.d/twebproxy-map.conf"
  family="$(managed_frontend_family)"
  [[ -z "$family" || "$family" == nginx ]] || die "Другой TWebProxy-инстанс уже использует Caddy на 80/443. Нельзя параллельно запустить managed Nginx."
  check_public_listener_owner nginx
  if ! command -v nginx >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y nginx || die "Не удалось установить Nginx."
  fi
  frontend_dirs "$NGINX_DIR/sites-available" "$NGINX_DIR/sites-enabled" "$NGINX_DIR/conf.d" &&
    tmp="$(mktemp)" || die "Не удалось записать $map."
  cat > "$tmp" <<'EOF'
map $http_upgrade $twebproxy_connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
  if ! cmp -s -- "$tmp" "$map" && ! frontend_file_replace "$tmp" "$map" 0644; then
    rm -f -- "$tmp"; die "Не удалось записать $map."
  fi
  rm -f -- "$tmp"
}

nginx_domain_conflict() {
  local host="$1" f
  while IFS= read -r f; do
    [[ "$f" == "$NGINX_DIR/sites-available/twebproxy-$host.conf" || "$f" == "$NGINX_DIR/sites-enabled/twebproxy-$host.conf" ]] && continue
    die "Nginx уже содержит server_name $host вне TWebProxy: $f"
  done < <(grep -RlsE "^[^#]*server_name[^;#]*[[:space:]]${host//./\\.}([[:space:];]|$)" "$NGINX_DIR" 2>/dev/null || true)
}

# The managed vhost of $1 may be changed only while it looks as the manager left
# it: the sites-available file absent or a regular file, the sites-enabled entry
# absent or a link to that file. Anything else is reported, never overwritten.
nginx_managed_state_ok() { # $1=host
  local f="$NGINX_DIR/sites-available/twebproxy-$1.conf" l="$NGINX_DIR/sites-enabled/twebproxy-$1.conf"
  { [[ ! -e "$f" && ! -L "$f" ]] || [[ -f "$f" && ! -L "$f" ]]; } &&
    { [[ ! -e "$l" && ! -L "$l" ]] || [[ -L "$l" && "$(readlink -f -- "$l")" == "$(readlink -f -- "$f")" ]]; }
}

nginx_link_enable() { # $1=host: sites-enabled link to the managed file, replaced atomically
  local f="$NGINX_DIR/sites-available/twebproxy-$1.conf" l="$NGINX_DIR/sites-enabled/twebproxy-$1.conf"
  local tmp="$NGINX_DIR/sites-enabled/.twebproxy-link.$$"
  if ln -sfn -- "$f" "$tmp" && mv -f -T -- "$tmp" "$l"; then return 0; fi
  rm -f -- "$tmp"; return 1
}

nginx_managed_save() { # $1=host $2=private dir: remembers the managed file and link
  local f="$NGINX_DIR/sites-available/twebproxy-$1.conf" l="$NGINX_DIR/sites-enabled/twebproxy-$1.conf"
  if [[ -f "$f" ]] && ! cp -p -- "$f" "$2/conf"; then return 1; fi
  if [[ -L "$l" ]] && ! : > "$2/link"; then return 1; fi
  return 0
}

nginx_managed_restore() { # $1=host $2=private dir: puts the remembered file and link back exactly
  local f="$NGINX_DIR/sites-available/twebproxy-$1.conf" l="$NGINX_DIR/sites-enabled/twebproxy-$1.conf" rc=0
  if [[ -f "$2/conf" ]]; then frontend_file_replace "$2/conf" "$f" || rc=1; else rm -f -- "$f" || rc=1; fi
  if [[ -e "$2/link" ]]; then nginx_link_enable "$1" || rc=1; else rm -f -- "$l" || rc=1; fi
  return "$rc"
}

nginx_test() { # nginx -t; on failure the tail of its output goes to stderr
  local out
  out="$(nginx -t 2>&1)" && return 0
  printf '%s\n' "$out" | tail -n 6 >&2
  return 1
}

# Puts candidate $2 (removed afterwards) in place as the managed vhost of $1
# (file plus sites-enabled link), tests the complete configuration (nginx -t)
# and reloads, or starts, Nginx. On any failure the previous file and link (or
# their absence) are put back exactly; a running Nginx keeps serving its
# previous configuration.
# 0 applied; 1 rejected by nginx -t; 2 not activated; 3 previous state not
# restored; 4 managed files in an unexpected state (nothing changed); 5 not
# written (previous state restored); 6 frontend lock busy (nothing changed).
nginx_managed_apply() { # $1=host $2=candidate
  local host="$1" save rc=0
  frontend_lock_acquire || { rm -f -- "$2"; return 6; }
  nginx_managed_state_ok "$host" || { rm -f -- "$2"; frontend_lock_release; return 4; }
  save="$(mktemp -d)" || { rm -f -- "$2"; frontend_lock_release; return 2; }
  nginx_managed_save "$host" "$save" || { rm -rf -- "$save" "$2"; frontend_lock_release; return 2; }
  frontend_signals_defer
  if ! frontend_file_replace "$2" "$NGINX_DIR/sites-available/twebproxy-$host.conf" 0644 || ! nginx_link_enable "$host"; then
    rc=5
  elif ! nginx_test; then
    rc=1
  elif systemctl is-active --quiet nginx; then
    systemctl reload nginx || rc=2
  else
    systemctl enable --now nginx || rc=2
  fi
  (( rc == 0 )) || nginx_managed_restore "$host" "$save" || rc=3
  rm -rf -- "$save" "$2"
  frontend_lock_release
  frontend_signals_end "$rc"
  return "$rc"
}

# Removes the managed vhost of $1, tests the remaining configuration and reloads
# a running Nginx; on failure the file and link are put back exactly.
# 0 removed or nothing to remove; 1 nginx -t fails without it; 2 reload failed;
# 3 previous state not restored; 4 managed files in an unexpected state;
# 6 frontend lock busy (nothing changed).
nginx_managed_remove() { # $1=host
  local host="$1" f="$NGINX_DIR/sites-available/twebproxy-$1.conf" l="$NGINX_DIR/sites-enabled/twebproxy-$1.conf" save rc=0
  [[ -e "$f" || -L "$f" || -e "$l" || -L "$l" ]] || return 0
  frontend_lock_acquire || return 6
  nginx_managed_state_ok "$host" || { frontend_lock_release; return 4; }
  save="$(mktemp -d)" || { frontend_lock_release; return 2; }
  nginx_managed_save "$host" "$save" || { rm -rf -- "$save"; frontend_lock_release; return 2; }
  frontend_signals_defer
  if ! rm -f -- "$l" "$f"; then
    rc=2
  elif ! nginx_test; then
    rc=1
  elif systemctl is-active --quiet nginx; then
    systemctl reload nginx || rc=2
  fi
  (( rc == 0 )) || nginx_managed_restore "$host" "$save" || rc=3
  rm -rf -- "$save"
  frontend_lock_release
  frontend_signals_end "$rc"
  return "$rc"
}

nginx_apply_or_die() { # $1=host $2=candidate (removed): nginx_managed_apply with its outcome reported
  local rc=0
  nginx_managed_apply "$1" "$2" || rc=$?
  rm -f -- "$2"
  case "$rc" in
    0) return 0;;
    1) die "Nginx отклонил конфигурацию $1 (nginx -t); прежняя конфигурация $1 восстановлена, работающий Nginx не менялся.";;
    2) die "Nginx не применил конфигурацию $1 (reload/start не удался); прежняя конфигурация $1 восстановлена.";;
    3) die "Не удалось восстановить прежнюю конфигурацию Nginx для $1: проверь $NGINX_DIR/sites-available/twebproxy-$1.conf и nginx -t.";;
    5) die "Не удалось записать конфигурацию Nginx для $1; прежняя конфигурация $1 восстановлена.";;
    6) die "Конфигурацию frontend сейчас меняет другая операция; повтори позже.";;
    *) die "Файлы Nginx для $1 в неожиданном состоянии (sites-enabled/twebproxy-$1.conf не ссылка на свой файл); ничего не изменено.";;
  esac
}

# Certificate $1 and key $2 are readable, parse and belong together.
tls_pair_matches() {
  local a b
  [[ -r "$1" && -r "$2" ]] || return 1
  a="$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)" || return 1
  b="$(openssl pkey -in "$2" -pubout -outform DER 2>/dev/null | sha256sum)" || return 1
  [[ "$a" == "$b" ]]
}

le_cert_usable() { # $1=host: its Let's Encrypt lineage has a matching certificate and key
  tls_pair_matches "$LE_DIR/live/$1/fullchain.pem" "$LE_DIR/live/$1/privkey.pem"
}

render_nginx_acme_conf() { # $1=host: HTTP-only vhost for the first ACME HTTP-01 challenge
  cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $1;
    location /.well-known/acme-challenge/ { root $ACME_WEBROOT; }
    location / { return 200 "ok\n"; add_header Content-Type text/plain; }
    access_log off;
}
EOF
}

render_nginx_tls_conf() { # $1=host $2=relay port $3=certificate $4=key -> vhost on stdout
  local host="$1" relay="$2" cert="$3" key="$4"
  cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $host;
    location /.well-known/acme-challenge/ { root $ACME_WEBROOT; }
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
}

install_nginx_certbot_deploy_hook() {
  local tmp hook="$LE_DIR/renewal-hooks/deploy/twebproxy-nginx-reload"
  frontend_dirs "$LE_DIR/renewal-hooks/deploy" && tmp="$(mktemp)" || die "Не удалось записать $hook."
  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if systemctl is-active --quiet nginx.service; then
  nginx -t
  systemctl reload nginx.service
fi
EOF
  if ! frontend_file_replace "$tmp" "$hook" 0755 || ! chmod 0755 "$hook"; then rm -f -- "$tmp"; die "Не удалось записать $hook."; fi
  rm -f -- "$tmp"
}

write_certbot_fallback_timer() {
  cat > "$SYSTEMD_DIR/twebproxy-cert-renew.service" <<'EOF'
[Unit]
Description=TWebProxy Let's Encrypt certificate renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet
EOF

  cat > "$SYSTEMD_DIR/twebproxy-cert-renew.timer" <<'EOF'
[Unit]
Description=Periodic TWebProxy Let's Encrypt certificate renewal

[Timer]
OnCalendar=*-*-* 03,15:17:00
RandomizedDelaySec=1h
Persistent=true
AccuracySec=1min
Unit=twebproxy-cert-renew.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

certbot_auto_renew_source() {
  if systemctl is-enabled --quiet certbot.timer 2>/dev/null && systemctl is-active --quiet certbot.timer 2>/dev/null; then
    printf 'certbot.timer'
    return 0
  fi
  if systemctl is-enabled --quiet twebproxy-cert-renew.timer 2>/dev/null && systemctl is-active --quiet twebproxy-cert-renew.timer 2>/dev/null; then
    printf 'twebproxy-cert-renew.timer'
    return 0
  fi
  printf 'disabled'
  return 1
}

ensure_nginx_le_auto_renew() {
  command -v certbot >/dev/null 2>&1 || die "certbot не установлен."
  install_nginx_certbot_deploy_hook

  # Prefer distro Certbot timer. If it is absent or cannot be enabled, install
  # a manager-owned fallback. Certbot itself decides whether renewal is due.
  if systemctl list-unit-files certbot.timer --no-legend 2>/dev/null | grep -q '^certbot\.timer'; then
    if systemctl enable --now certbot.timer >/dev/null 2>&1; then
      systemctl disable --now twebproxy-cert-renew.timer >/dev/null 2>&1 || true
      rm -f "$SYSTEMD_DIR/twebproxy-cert-renew.timer" "$SYSTEMD_DIR/twebproxy-cert-renew.service"
      systemctl daemon-reload
      ok "Let's Encrypt auto-renew: certbot.timer active"
      return 0
    fi
  fi

  write_certbot_fallback_timer
  systemctl enable --now twebproxy-cert-renew.timer >/dev/null
  ok "Let's Encrypt auto-renew: twebproxy-cert-renew.timer active"
}

# The web server's unprivileged worker reads the ACME webroot, so the manager
# directory above it must be searchable. Updaters before Stage F created that
# parent (/var/lib/twebproxy, shared with the update backups) with mode 0700.
# Only search permission is added, and only to a real root-owned directory:
# never read or write, never through a symbolic link.
acme_webroot_prepare() {
  local parent
  install -d -m 0755 "$ACME_WEBROOT" || return 1
  parent="$(dirname -- "$ACME_WEBROOT")"
  if [[ -d "$parent" && ! -L "$parent" && "$(stat -c %u -- "$parent" 2>/dev/null)" == 0 ]]; then
    chmod go+x -- "$parent" || return 1
  fi
}

configure_nginx_le() {
  local host="$1" relay="$2" email="$3" live="$LE_DIR/live/$1" cand had_cert=0 had_conf=0 days="" rc=0
  nginx_common_install; nginx_domain_conflict "$host"
  if ! command -v certbot >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y certbot || die "Не удалось установить certbot."
  fi
  acme_webroot_prepare || die "Не удалось подготовить $ACME_WEBROOT."
  [[ -e "$NGINX_DIR/sites-available/twebproxy-$host.conf" ]] && had_conf=1
  if le_cert_usable "$host"; then
    # The managed TLS vhost already answers HTTP-01 on port 80: renewal and
    # re-issue never replace it with the HTTP-only bootstrap.
    had_cert=1
  else
    # First issuance: the hostname must answer HTTP-01 on port 80 before any
    # certificate exists. Nothing serves HTTPS for it yet.
    cand="$(mktemp)" || die "Не удалось создать временный файл."
    render_nginx_acme_conf "$host" > "$cand"
    nginx_apply_or_die "$host" "$cand"
  fi
  if ! certbot certonly --webroot -w "$ACME_WEBROOT" --cert-name "$host" -d "$host" --non-interactive --agree-tos --email "$email" --keep-until-expiring; then
    if (( had_cert )) && days="$(cert_days_remaining_file "$live/fullchain.pem")" && (( days > 0 )); then
      warn "Certbot не смог получить или продлить сертификат $host; остаётся действующий сертификат (дней до истечения: $days)."
    else
      if (( ! had_cert && ! had_conf )); then
        nginx_managed_remove "$host" || rc=$?
        (( rc == 0 )) || warn "Временная HTTP-конфигурация $host для ACME не убрана; проверь $NGINX_DIR/sites-available/twebproxy-$host.conf."
      elif (( ! had_cert )); then
        warn "Для $host оставлена временная HTTP-конфигурация ACME: прежняя ссылалась на отсутствующий сертификат."
      fi
      die "Certbot не смог получить сертификат для $host; существующие сертификаты не изменены."
    fi
  fi
  le_cert_usable "$host" || die "После certbot нет пригодной пары сертификат/ключ для $host в $live."
  install_nginx_certbot_deploy_hook
  ensure_nginx_le_auto_renew
  cand="$(mktemp)" || die "Не удалось создать временный файл."
  render_nginx_tls_conf "$host" "$relay" "$live/fullchain.pem" "$live/privkey.pem" > "$cand"
  nginx_apply_or_die "$host" "$cand"
}

configure_nginx_custom() {
  local host="$1" relay="$2" cert="$3" key="$4" cand days="" path_re='^/[A-Za-z0-9._/@+:,=~%-]+$'
  nginx_common_install; nginx_domain_conflict "$host"
  [[ "$cert" =~ $path_re && "$key" =~ $path_re ]] ||
    die "Пути к сертификату и ключу должны быть абсолютными, без пробелов и спецсимволов: $cert $key"
  [[ -r "$cert" ]] || die "Сертификат не читается: $cert"
  [[ -r "$key" ]] || die "Ключ не читается: $key"
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || die "Некорректный PEM certificate."
  openssl pkey -in "$key" -noout >/dev/null 2>&1 || die "Некорректный PEM key."
  tls_pair_matches "$cert" "$key" || die "Ключ $key не соответствует сертификату $cert."
  if days="$(cert_days_remaining_file "$cert")" && (( days < 0 )); then warn "Сертификат $cert уже истёк."; fi
  if [[ "$(stat -L -c '%a' -- "$key")" =~ [4567]$ ]]; then warn "Ключ $key доступен для чтения всем пользователям; ограничь права (chmod 600)."; fi
  cand="$(mktemp)" || die "Не удалось создать временный файл."
  render_nginx_tls_conf "$host" "$relay" "$cert" "$key" > "$cand"
  nginx_apply_or_die "$host" "$cand"
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

# Removes the managed frontend of $1. Fails, with the reason reported, when that
# is not proven; the previous frontend configuration then stays in place.
remove_reverse_proxy_for_instance() {
  local host="$1" rc=0; load_instance "$host"
  case "$TLS_MODE" in
    caddy)
      caddy_remove_host "$host" || rc=$?
      case "$rc" in
        0) ;;
        1) warn "Блок TWebProxy для $host не удалён из Caddyfile: маркеры неоднозначны или Caddyfile без него невалиден; Caddyfile не изменён.";;
        2) warn "Caddy не применил Caddyfile без $host; прежний Caddyfile восстановлен.";;
        5) warn "Конфигурацию frontend сейчас меняет другая операция; повтори позже.";;
        *) warn "Caddy не применил Caddyfile без $host, и прежний Caddyfile восстановить не удалось: проверь $CADDYFILE (прежняя версия рядом, *.twebproxy-previous).";;
      esac
      ;;
    nginx-*)
      nginx_managed_remove "$host" || rc=$?
      case "$rc" in
        0) ;;
        1) warn "Nginx без конфигурации $host не проходит nginx -t; её файлы восстановлены, Nginx не менялся.";;
        2) warn "Nginx не перезагрузился без конфигурации $host; её файлы восстановлены.";;
        3) warn "Не удалось восстановить конфигурацию Nginx для $host: проверь $NGINX_DIR/sites-available/twebproxy-$host.conf и nginx -t.";;
        6) warn "Конфигурацию frontend сейчас меняет другая операция; повтори позже.";;
        *) warn "Файлы Nginx для $host в неожиданном состоянии (sites-enabled/twebproxy-$host.conf не ссылка на свой файл); ничего не изменено.";;
      esac
      ;;
  esac
  return "$rc"
}

configure_ufw() {
  local approval_default=y
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  (( ! TUI_ACTIVE )) || approval_default=n
  if yesno "UFW активен. Разрешить TCP 80 и 443?" "$approval_default"; then ufw allow 80/tcp; ufw allow 443/tcp; fi
}

smart_dns_ready() {
  # Read DNS, not /etc/hosts. An unavailable public-IP probe is not success.
  local host="$1" answers local_ips public_ip=""
  if command -v dig >/dev/null 2>&1; then
    answers="$(dig +time=3 +tries=1 +short A "$host")" || return 1
  else
    answers="$(getent -s dns ahostsv4 "$host" | awk '{print $1}')" || return 1
  fi
  local_ips="$(ip -4 -o addr show scope global | awk '{split($4,a,"/");print a[1]}')" || return 1
  if command -v curl >/dev/null 2>&1; then
    public_ip="$(curl -4fsS --proto '=https' --connect-timeout 3 --max-time 6 https://api.ipify.org 2>/dev/null)" || public_ip=""
  fi
  python3 - "$answers" "$local_ips" "$public_ip" <<'PY_DNS'
import ipaddress,sys
def public(values):
 out=set()
 for v in values.split():
  try:
   a=ipaddress.IPv4Address(v)
   if a.is_global:out.add(str(a))
  except ValueError:pass
 return out
sys.exit(0 if public(sys.argv[1]) & (public(sys.argv[2]) | public(sys.argv[3])) else 1)
PY_DNS
}

smart_frontend_settings() {
  local family listeners h contact="" tool
  for tool in ss ip getent python3 openssl; do
    command -v "$tool" >/dev/null 2>&1 || die "$(ui_msgf smart_probe_missing "$tool")"
  done
  family="$(managed_frontend_family)"
  listeners="$(ss -H -ltnp '( sport = :80 or sport = :443 )')" || die "$(ui_msg smart_frontend_blocked)"
  # Do not adopt an unknown web server, even when its binary is familiar.
  [[ "$family" != mixed && ( -n "$family" || -z "$listeners" ) ]] || die "$(ui_msg smart_frontend_blocked)"
  TLS_MODE=caddy
  [[ "$family" != nginx ]] || TLS_MODE=nginx-le
  if [[ -n "$listeners" ]]; then
    while IFS= read -r h; do
      [[ -z "$h" || "$h" == *"\"${family}\""* ]] || die "$(ui_msg smart_frontend_blocked)"
    done <<< "$listeners"
  fi
  # Reuse only a validated contact from a compatible managed record.
  while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    contact="$( (load_instance "$h"; [[ "$TLS_MODE" == caddy || "$TLS_MODE" == nginx-le ]] && printf '%s' "${ACME_EMAIL:-}") )" || contact=""
    [[ "$contact" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] && break
    contact=""
  done < <(list_hosts_array)
  ACME_EMAIL="$contact"; NGINX_CERT=""; NGINX_KEY=""
  [[ "$TLS_MODE" != nginx-le || -n "$ACME_EMAIL" ]] || die "$(ui_msg smart_contact_missing)"
  SITE_MODE=default; SITE_UPSTREAM=""; SOURCE_SITE_DIR=""
  default_site_action verify >/dev/null
  check_frontend_compatibility "$TLS_MODE"
}

collect_instance_settings() {
  local attempt reason
  printf '%s\n' "$(ui_msg setup_hostname_intro)"
  # Three attempts for a mistyped name; EOF still cancels (ask returns 130).
  for attempt in 1 2 3; do
    HOSTNAME="$(ask 'Hostname WEB-proxy (без https://)' '')" || return $?
    HOSTNAME="${HOSTNAME,,}"
    if ! is_valid_hostname "$HOSTNAME"; then
      reason="Нужен lowercase ASCII/ACE hostname вида proxy.example.com"
    elif instance_exists "$HOSTNAME"; then
      reason="Инстанс $HOSTNAME уже существует."
    else
      break
    fi
    (( attempt < 3 )) || die "$reason"
    warn "$reason"; warn "$(ui_msgf setup_hostname_retry $((3 - attempt)))"
  done

  # Quick setup keeps every safety check and only answers the advanced
  # questions (ports, profile, secret, carrier, MTProxy limits) with defaults.
  local st
  case "${TUI_SETUP_KIND:-}" in
    quick) st=1;; advanced) st=2;;
    *) st="$(choose "$(ui_msg setup_type)" "$(ui_msg setup_quick)" "$(ui_msg setup_advanced)")" || return $?;;
  esac
  SETUP_MODE=quick; [[ "$st" == 1 ]] || SETUP_MODE=advanced

  echo
  if [[ "$UI_LANGUAGE" == en ]]; then
    printf "%bWEB Proxy uses public HTTPS/443; the client does not specify a port.%b\n" "$C_YELLOW" "$C_RESET"
  else
    printf "%bWEB Proxy использует публичный HTTPS/443 — порт в клиенте не задаётся.%b\n" "$C_YELLOW" "$C_RESET"
  fi
  local auto rdef adef
  INSTANCE_PORTS_AUTO=0
  if [[ "$SETUP_MODE" == quick ]] || yesno "Внутренние relay/admin порты подобрать автоматически?" y; then
    INSTANCE_PORTS_AUTO=1
    RELAY_PORT="$(next_free_port 18080 19999)" || die "Нет свободного relay port."
    ADMIN_PORT="$(next_free_port $((RELAY_PORT+1)) 20999)" || die "Нет свободного admin port."
  else
    rdef="$(next_free_port 18080 19999)"; RELAY_PORT="$(ask_internal_port 'Relay port (loopback)' "$rdef")"
    adef="$(next_free_port 18081 20999)"; ADMIN_PORT="$(ask_internal_port 'Admin/metrics port (loopback)' "$adef")"
  fi
  [[ "$RELAY_PORT" != "$ADMIN_PORT" ]] || die "Порты должны быть разными."

  if [[ "${TUI_SETUP_KIND:-}" == quick ]]; then
    smart_frontend_settings
    smart_dns_ready "$HOSTNAME" || die "$(ui_msg smart_dns_blocked)"
    CREATED_AT="$(date -Is)"
    return 0
  fi

  local sm
  echo; printf '%s\n' "$(ui_msg setup_site_intro)"
  sm="$(choose 'Обычный сайт на hostname:' \
    "$(ui_msg site_placeholder)" "$(ui_msg site_directory)" "$(ui_msg site_upstream)")" || return $?
  SITE_UPSTREAM=""; SOURCE_SITE_DIR=""
  case "$sm" in
    1) SITE_MODE=default ;;
    2) SITE_MODE=directory; SOURCE_SITE_DIR="$(ask 'Путь к каталогу с index.html' '')" ;;
    3) SITE_MODE=upstream; SITE_UPSTREAM="$(ask 'Loopback URL' 'http://127.0.0.1:3000')" ;;
  esac

  local tm
  tm="$(choose 'SSL / reverse proxy:' \
    "$(ui_msg tls_caddy)" "$(ui_msg tls_nginx_le)" "$(ui_msg tls_nginx_custom)" "$(ui_msg tls_manual)")" || return $?
  ACME_EMAIL=""; NGINX_CERT=""; NGINX_KEY=""
  case "$tm" in
    1) TLS_MODE=caddy; ACME_EMAIL="$(ask 'Email для Let’s Encrypt' '')"; [[ "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] || die "Некорректный email." ;;
    2) TLS_MODE=nginx-le; ACME_EMAIL="$(ask 'Email для Let’s Encrypt' '')"; [[ "$ACME_EMAIL" == *@*.* ]] || die "Некорректный email." ;;
    3) TLS_MODE=nginx-custom; NGINX_CERT="$(ask 'Путь к fullchain.pem' '')"; NGINX_KEY="$(ask 'Путь к privkey.pem' '')" ;;
    4) TLS_MODE=manual ;;
  esac
  check_frontend_compatibility "$TLS_MODE"
  CREATED_AT="$(date -Is)"
}

collect_profile_settings() {
  local host="$1" suggested="${2:-default}" mode="${3:-advanced}" auto bdef sdef
  if [[ "$mode" == quick ]]; then
    # Quick setup of a new hostname: its first profile with safe defaults.
    PROFILE_NAME="$suggested"
    SECRET="$(openssl rand -hex 16)"
    CARRIER_MODE=https
    PROFILE_PORTS_AUTO=1
    BACKEND_PORT="$(next_free_port 23980 26999)" || die "Нет свободного backend port."
    STATS_PORT="$(next_free_port 28980 31999)" || die "Нет свободного stats port."
    WORKERS=1
    MAX_CONNECTIONS=4096
    PROFILE_CREATED_AT="$(date -Is)"
    return 0
  fi
  while true; do
    PROFILE_NAME="$(ask 'Имя профиля/секрета' "$suggested")" || return $?; PROFILE_NAME="${PROFILE_NAME,,}"
    is_valid_profile_name "$PROFILE_NAME" || { warn "Имя: a-z, 0-9, _ и -, максимум 32 символа."; continue; }
    [[ ! -f "$(profile_env "$host" "$PROFILE_NAME")" ]] || { warn "Профиль уже существует."; continue; }
    break
  done

  if yesno "Сгенерировать новый 16-byte secret?" y; then SECRET="$(openssl rand -hex 16)"; else
    read -r -s -p "$([[ "$UI_LANGUAGE" == en ]] && printf 'Secret (32 hex or dd+32 hex): ' || printf 'Secret (32 hex либо dd+32 hex): ')" SECRET || return 130; echo
    is_valid_secret "$SECRET" || die "Некорректный secret."
  fi
  CARRIER_MODE="$(carrier_choose)"

  PROFILE_PORTS_AUTO=0
  if yesno "Backend/stats порты подобрать автоматически?" y; then
    PROFILE_PORTS_AUTO=1
    BACKEND_PORT="$(next_free_port 23980 26999)" || die "Нет свободного backend port."
    STATS_PORT="$(next_free_port 28980 31999)" || die "Нет свободного stats port."
  else
    bdef="$(next_free_port 23980 26999)"; BACKEND_PORT="$(ask_internal_port 'MTProxy backend port' "$bdef")"
    sdef="$(next_free_port 28980 31999)"; STATS_PORT="$(ask_internal_port 'MTProxy stats port' "$sdef")"
  fi
  [[ "$BACKEND_PORT" != "$STATS_PORT" ]] || die "Backend и stats ports должны отличаться."

  if (( TUI_ACTIVE )); then
    local limits
    limits="$(tui_preset_choose "$(ui_msg smart_profile_preset)" "$(ui_msg smart_limits_one)" "$(ui_msg smart_limits_two)" "$(ui_msg smart_advanced)")" || return $?
    case "$limits" in
      1) WORKERS=1; MAX_CONNECTIONS=4096;;
      2) WORKERS=2; MAX_CONNECTIONS=4096;;
      3) WORKERS="$(ask 'MTProxy workers' '1')"; MAX_CONNECTIONS="$(ask 'Max connections на worker' '4096')";;
    esac
  else
    WORKERS="$(ask 'MTProxy workers' '1')"
    MAX_CONNECTIONS="$(ask 'Max connections на worker' '4096')"
  fi
  [[ "$WORKERS" =~ ^[1-9][0-9]*$ ]] && (( WORKERS <= 256 )) || die "workers: 1..256"
  [[ "$MAX_CONNECTIONS" =~ ^[1-9][0-9]*$ ]] || die "max connections должен быть > 0"
  PROFILE_CREATED_AT="$(date -Is)"
}

# Under the port lock: keep a still-free automatic proposal, otherwise select
# again. An unknown listener/registry state always blocks allocation.
preferred_free_port() {
  local candidate="${1:-}" low="$2" high="$3" rc=0
  if is_valid_port "$candidate" && (( 10#$candidate >= low && 10#$candidate <= high )); then
    port_available "$candidate" || rc=$?
    case "$rc" in 0) printf '%s' "$candidate"; return 0;; 2) return 2;; esac
  fi
  next_free_port "$low" "$high"
}

claim_instance_ports() {
  if [[ "${INSTANCE_PORTS_AUTO:-1}" == 1 ]]; then
    RELAY_PORT="$(preferred_free_port "${RELAY_PORT:-}" 18080 19999)" || die "Нет свободного relay port."
    ADMIN_PORT="$(preferred_free_port "${ADMIN_PORT:-}" $((RELAY_PORT+1)) 20999)" || die "Нет свободного admin port."
  else
    port_available "$RELAY_PORT" || die "Порт $RELAY_PORT уже занят или зарегистрирован TWebProxy."
    port_available "$ADMIN_PORT" || die "Порт $ADMIN_PORT уже занят или зарегистрирован TWebProxy."
  fi
}

claim_profile_ports() {
  if [[ "${PROFILE_PORTS_AUTO:-1}" == 1 ]]; then
    BACKEND_PORT="$(preferred_free_port "${BACKEND_PORT:-}" 23980 26999)" || die "Нет свободного backend port."
    STATS_PORT="$(preferred_free_port "${STATS_PORT:-}" 28980 31999)" || die "Нет свободного stats port."
  else
    port_available "$BACKEND_PORT" || die "Порт $BACKEND_PORT уже занят или зарегистрирован TWebProxy."
    port_available "$STATS_PORT" || die "Порт $STATS_PORT уже занят или зарегистрирован TWebProxy."
  fi
}

# Caddy obtains its certificate asynchronously after the configuration is
# loaded, so an audit right after setup can see no valid certificate yet.
# Bounded wait (TWEBPROXY_CADDY_CERT_WAIT seconds, default 90; 0 disables) for a
# strictly verified HTTPS handshake; on timeout the audit still runs and reports
# exactly what it sees.
caddy_wait_certificate() { # $1=host
  local host="$1" limit="${TWEBPROXY_CADDY_CERT_WAIT:-90}" deadline
  [[ "$limit" =~ ^[0-9]{1,4}$ ]] || limit=90
  (( limit > 0 )) || return 0
  log "$(ui_msgf caddy_wait_cert "$limit" "$host")"
  deadline=$((SECONDS + limit))
  while (( SECONDS < deadline )); do
    if curl -sS -o /dev/null --proto '=https' --max-time 5 "https://$host/" >/dev/null 2>&1; then
      ok "$(ui_msgf caddy_wait_cert_ok "$host")"; return 0
    fi
    sleep 3
  done
  warn "$(ui_msgf caddy_wait_cert_timeout "$host" "$limit" "$host")"
  return 1
}

add_instance_cmd() {
  need_root; need_systemd; check_platform; banner
  (( TUI_ACTIVE )) || ensure_core
  collect_instance_settings

  echo
  [[ "$UI_LANGUAGE" == en ]] && printf "%bFirst profile for %s%b\n" "$C_BOLD" "$HOSTNAME" "$C_RESET" \
    || printf "%bПервый профиль для %s%b\n" "$C_BOLD" "$HOSTNAME" "$C_RESET"
  local host="$HOSTNAME" profile others other bid
  collect_profile_settings "$host" default "${SETUP_MODE:-advanced}"
  profile="$PROFILE_NAME"

  echo
  if (( TUI_ACTIVE )) && [[ "${TUI_SETUP_KIND:-}" == quick ]]; then
    tui_text "$(ui_msgf smart_quick_plan "$host" "$TLS_MODE")"
  elif [[ "$UI_LANGUAGE" == en ]]; then cat <<EOF
Plan:
  Hostname:       $host
  Public:         HTTPS/443
  Relay:          127.0.0.1:$RELAY_PORT
  Admin/metrics:  127.0.0.1:$ADMIN_PORT
  TLS:            $TLS_MODE
  Site:           $SITE_MODE
  Profile:        $PROFILE_NAME
  Carrier:        $CARRIER_MODE
  MTProxy:        :$BACKEND_PORT (blocked externally by firewall)
  MTProxy stats:  :$STATS_PORT (blocked externally by firewall)
  Setup:          $(ui_msg "setup_${SETUP_MODE:-advanced}_short")
  Network mode:   $(ui_msg plan_network_value)
EOF
  else cat <<EOF
План:
  Hostname:       $host
  Публичный адрес: HTTPS/443
  Relay:          127.0.0.1:$RELAY_PORT
  Администрирование/метрики: 127.0.0.1:$ADMIN_PORT
  TLS:            $TLS_MODE
  Сайт:           $SITE_MODE
  Профиль:        $PROFILE_NAME
  Carrier:        $CARRIER_MODE
  MTProxy:        :$BACKEND_PORT (будет закрыт межсетевым экраном снаружи)
  Статистика MTProxy: :$STATS_PORT (будет закрыт межсетевым экраном снаружи)
  Настройка:      $(ui_msg "setup_${SETUP_MODE:-advanced}_short")
  Сетевой режим:  $(ui_msg plan_network_value)
EOF
  fi
  if (( TUI_ACTIVE )); then
    [[ "${TUI_SETUP_KIND:-}" != quick ]] || tui_text "$(ui_msg smart_auto_plan)"
    tui_text "$(ui_msg smart_install_impact)"
    yesno "$(ui_msg smart_apply)" n || { log "$(ui_msg smart_cancelled)"; return 0; }
  else
    yesno "Создать?" y || exit 0
  fi

  if [[ "$TLS_MODE" != manual ]]; then
    if [[ "${TUI_SETUP_KIND:-}" == quick ]]; then
      smart_dns_ready "$host" || die "$(ui_msg smart_dns_blocked)"
    else
      check_dns_for_host "$host" || yesno "DNS пока не совпадает. Продолжить?" n || exit 1
    fi
  fi
  (( ! TUI_ACTIVE )) || ensure_core

  # procfs first (v0.2.24): with an unprotected /proc no backend may start, and
  # failing here leaves no half-created instance behind.
  proc_hardening_ensure || proc_fail_closed
  instance_lock_acquire "$host" || die "Другая операция изменяет $host; повтори позже."
  instance_exists "$host" && die "Инстанс $host уже существует."
  # The leaf port lock is shared by every create path: it also serializes the
  # hostname and backend-id ownership checks below against concurrent creations.
  port_lock_acquire || die "Другая операция выделяет порты; повтори позже."
  others="$(overlapping_hosts "$host")"
  [[ -z "$others" ]] || { other="${others%%$'\n'*}"
    die "Hostname $host пересекается с $other в именах backend (<hostname>--<profile>); инстанс не создан, ничего не изменено."; }
  # Backend env files of this hostname left by an interrupted earlier deletion.
  reconcile_orphan_backends "$host" ||
    die "Backends без профиля у $host не удалось безопасно убрать; их env и защита firewall сохранены."
  bid="$(backend_id "$host" "$profile")"
  ! backend_id_used_by_other "$host" "$profile" && [[ ! -e "$BACKENDS_DIR/$bid.env" && ! -L "$BACKENDS_DIR/$bid.env" ]] ||
    die "Имя backend $bid уже использует профиль другого инстанса; профиль не создан, ничего не изменено."
  claim_instance_ports
  claim_profile_ports
  [[ "$(printf '%s\n' "$RELAY_PORT" "$ADMIN_PORT" "$BACKEND_PORT" "$STATS_PORT" | sort -u | wc -l)" == 4 ]] ||
    die "Порты должны быть разными."
  save_instance "$host"
  prepare_site_for_instance "$host"
  write_instance_config "$host"
  profile_state_commit "$host" "$profile" ""
  port_lock_release
  rebuild_firewall
  start_profile_backend "$host" "$profile"
  restart_relay_wait_ready "$host"
  configure_tls_for_instance "$host"
  configure_ufw
  dpi_with_mutation_lock dpi_repair_all || true
  [[ "$TLS_MODE" != caddy ]] || caddy_wait_certificate "$host" || true
  if ! audit_instance_impl "$host"; then
    die "Инстанс создан, но isolation audit для $host не пройден."
  fi
  instance_lock_release
  install_manager_copy
  ok "Инстанс $host создан и прошёл isolation audit."
  show_instance_cmd "$host"
  setup_next_steps "$host"
}

repair_instance_cmd() {
  need_root; need_systemd; check_platform; banner; ensure_core
  local host="${1:-}"
  [[ -n "$host" ]] || host="$(select_instance)"
  if bridge_managed "$host"; then foreign_node_cmd repair; return; fi
  require_instance "$host"
  instance_lock_acquire "$host" || die "Другая операция изменяет $host; повтори позже."
  require_unshared_backends "$host"

  log "Проверяю и восстанавливаю runtime для $host..."
  # Recreate generated artifacts from the canonical per-instance/profile state.
  prepare_users_and_dirs
  stage4_install_restore_helper yes || die "Не удалось установить безопасный offline rollback helper."
  # repair doubles as a safe manager-runtime upgrade path: regenerate helpers and
  # systemd templates from the currently running manager version before restarts.
  write_runner_helpers
  write_systemd_templates
  # Converges backend env files and profiles.json left behind by an interrupted operation.
  instance_derive_state "$host" || die "Не удалось записать состояние: $(instance_dir "$host")"
  write_instance_config "$host"
  validate_instance "$host"
  # Backend env files left without a profile: removed once their unit is proven
  # stopped (then the firewall rebuild below drops their ports), else fail closed.
  reconcile_orphan_backends "$host" ||
    die "Backends без профиля у $host не удалось безопасно убрать; их env и защита firewall сохранены."
  rebuild_firewall
  systemctl daemon-reload
  # Before any backend (re)starts: an unprotected /proc stops them all instead.
  proc_hardening_ensure || proc_fail_closed
  start_all_backends "$host"
  restart_relay_wait_ready "$host"
  configure_tls_for_instance "$host"
  configure_ufw
  dpi_with_mutation_lock dpi_repair_all || true
  [[ "${TLS_MODE:-}" != caddy ]] || caddy_wait_certificate "$host" || true
  if ! audit_instance_impl "$host"; then
    die "Runtime восстановлен, но isolation audit для $host не пройден."
  fi
  instance_lock_release
  write_global_env
  install_manager_copy
  ok "Инстанс $host восстановлен и прошёл readiness/isolation checks."
  show_instance_cmd "$host"
}

next_profile_name() {
  local host="$1" n name id
  for n in {1..33}; do
    name="profile$n"; id="$(backend_id "$host" "$name")"
    [[ ! -e "$(profile_env "$host" "$name")" && ! -L "$(profile_env "$host" "$name")" && ! -e "$BACKENDS_DIR/$id.env" && ! -L "$BACKENDS_DIR/$id.env" ]] || continue
    backend_id_used_by_other "$host" "$name" && continue
    printf '%s' "$name"; return 0
  done
  return 1
}

profile_add_cmd() {
  need_root; banner
  (( TUI_ACTIVE )) || ensure_core
  local host="${1:-}" profile count orphan_id; [[ -n "$host" ]] || host="$(select_instance)"
  bridge_reject_profile_change "$host"
  require_instance "$host"
  count="$(count_profiles "$host")"; (( count < 32 )) || die "Upstream max_profiles по текущему конфигу: 32."
  if (( TUI_ACTIVE )); then
    local preset suggested mode=quick
    preset="$(tui_preset_choose "$(ui_msg smart_profile_preset)" "$(ui_msg smart_quick)" "$(ui_msg smart_advanced)")" || return $?
    [[ "$preset" == 1 ]] || mode=advanced
    if [[ "$mode" == quick ]]; then
      suggested="$(next_profile_name "$host")" || die "$(ui_msg smart_profile_name_blocked)"
    else
      suggested="$(next_profile_name "$host")" || suggested=custom
    fi
    collect_profile_settings "$host" "$suggested" "$mode"
    tui_text "$(ui_msgf smart_profile_plan "$PROFILE_NAME" "$CARRIER_MODE" "$WORKERS" "$MAX_CONNECTIONS")"
    yesno "$(ui_msg smart_apply)" n || { log "$(ui_msg smart_cancelled)"; return 0; }
    ensure_core
  else
    collect_profile_settings "$host" "profile$((count+1))"
  fi
  # From here on the target is this local name, whatever helpers do to globals.
  profile="$PROFILE_NAME"
  instance_lock_acquire "$host" || die "Другая операция изменяет $host; повтори позже."
  require_instance "$host"
  [[ ! -e "$(profile_env "$host" "$profile")" && ! -L "$(profile_env "$host" "$profile")" ]] || die "Профиль уже существует."
  (( $(count_profiles "$host") < 32 )) || die "Upstream max_profiles по текущему конфигу: 32."
  require_unshared_backends "$host"
  orphan_id="$(backend_id "$host" "$profile")"
  port_lock_acquire || die "Другая операция выделяет порты; повтори позже."
  # Under the shared create lock: no other live profile may already produce this
  # id, and never write over a backend env left without a profile (its unit may run).
  ! backend_id_used_by_other "$host" "$profile" ||
    die "Имя backend $orphan_id уже использует профиль другого инстанса; профиль не создан, ничего не изменено."
  [[ ! -e "$BACKENDS_DIR/$orphan_id.env" && ! -L "$BACKENDS_DIR/$orphan_id.env" ]] ||
    die "У $host уже есть backend env $orphan_id без профиля; выполни 'twebproxy repair $host'."
  claim_profile_ports
  profile_state_commit "$host" "$profile" ""
  port_lock_release
  rebuild_firewall
  start_profile_backend "$host" "$profile"
  warn "Добавление профиля перезапускает relay и сбрасывает активные WEB-сессии; Telegram переподключится автоматически."
  restart_relay_wait_ready "$host"
  instance_lock_release
  ok "Профиль $profile добавлен."
  show_profile_cmd "$host" "$profile"
}

profile_delete_cmd() {
  need_root; banner
  local host="${1:-}" profile="${2:-}" prev unit
  [[ -n "$host" ]] || host="$(select_instance)"
  bridge_reject_profile_change "$host"
  require_instance "$host"
  [[ -n "$profile" ]] || profile="$(select_profile "$host")"
  (( $(count_profiles "$host") > 1 )) || die "Нельзя удалить последний профиль. Удали весь hostname через 'twebproxy delete'."
  require_profile_file "$host" "$profile"
  warn "Удалится secret $profile и его backend. Клиенты с этим secret сразу перестанут подключаться."
  yesno "Удалить профиль $profile?" n || exit 0
  instance_lock_acquire "$host" || die "Другая операция изменяет $host; повтори позже."
  require_profile_file "$host" "$profile"
  require_unshared_backends "$host"
  (( $(count_profiles "$host") > 1 )) || die "Нельзя удалить последний профиль. Удали весь hostname через 'twebproxy delete'."
  prev="$(cat -- "$(profile_env "$host" "$profile")")"
  # The backend is proven down first: until then its record, env file and
  # firewall protection stay. The firewall is rebuilt only after the removal.
  unit="twebproxy-mtproxy@$(backend_id "$host" "$profile").service"
  stop_profile_backend "$host" "$profile" ||
    die "Backend $unit не остановлен или его состояние неизвестно; ничего не удалено, защита firewall сохранена. Проверь его (systemctl status $unit) и повтори."
  if ! profile_state_remove "$host" "$profile" "$prev"; then
    # The previous record and env are back; so must be its running backend.
    ( start_profile_backend "$host" "$profile" ) >/dev/null ||
      die "Прежнее состояние $host восстановлено, но backend профиля $profile не запущен; выполни 'twebproxy repair $host'."
    die "Не удалось применить новое состояние $host; прежнее состояние восстановлено."
  fi
  rebuild_firewall; restart_relay_wait_ready "$host"
  instance_lock_release
  ok "Профиль $profile удалён."
}

profile_rotate_cmd() {
  need_root; banner
  local host="${1:-}" profile="${2:-}" new_secret prev
  [[ -n "$host" ]] || host="$(select_instance)"
  bridge_reject_profile_change "$host"
  require_instance "$host"
  [[ -n "$profile" ]] || profile="$(select_profile "$host")"
  require_profile "$host" "$profile"
  local generate=1 preset
  if (( TUI_ACTIVE )); then
    tui_text "$(ui_msgf smart_target "$host" "$profile")"
    preset="$(tui_preset_choose "$(ui_msg smart_rotate_preset)" "$(ui_msg smart_rotate_auto)" "$(ui_msg smart_rotate_manual)")" || return $?
    [[ "$preset" == 1 ]] || generate=0
    yesno "$(ui_msg smart_rotate_warning)" n || { log "$(ui_msg smart_cancelled)"; return 0; }
  else
    yesno "Сгенерировать новый secret?" y || generate=0
  fi
  if (( generate )); then new_secret="$(openssl rand -hex 16)"; else
    read -r -s -p "$([[ "$UI_LANGUAGE" == en ]] && printf 'New secret: ' || printf 'Новый secret: ')" new_secret || return 130; echo
  fi
  is_valid_secret "$new_secret" || die "Некорректный secret."
  # Read-modify-write on the record as it is under the lock, not as it was
  # before the prompt: a concurrent change to other fields is kept.
  instance_lock_acquire "$host" || die "Другая операция изменяет $host; повтори позже."
  require_profile "$host" "$profile"
  require_unshared_backends "$host"
  prev="$(cat -- "$(profile_env "$host" "$profile")")"
  SECRET="$new_secret"
  profile_state_commit "$host" "$profile" "$prev"
  [[ "$BACKEND_PORTS_CHANGED" != 1 ]] || rebuild_firewall
  start_profile_backend "$host" "$profile"
  restart_relay_wait_ready "$host"
  instance_lock_release
  ok "Secret $profile заменён. Старый больше не работает."
  show_profile_cmd "$host" "$profile"
}

profile_carrier_cmd() {
  need_root; banner
  local host="${1:-}" profile="${2:-}" carrier prev old_carrier
  [[ -n "$host" ]] || host="$(select_instance)"
  require_instance "$host"
  [[ -n "$profile" ]] || profile="$(select_profile "$host")"
  require_profile "$host" "$profile"
  old_carrier="$CARRIER_MODE"
  carrier="$(carrier_choose)" || return $?
  is_valid_carrier_mode "$carrier" || return 0
  if (( TUI_ACTIVE )); then
    [[ "$carrier" != "$old_carrier" ]] || { log "$(ui_msg smart_unchanged)"; return 0; }
    tui_text "$(ui_msgf smart_target "$host" "$profile")"
    yesno "$(ui_msgf smart_carrier_change "$old_carrier" "$carrier")" n || { log "$(ui_msg smart_cancelled)"; return 0; }
  fi
  instance_lock_acquire "$host" || die "Другая операция изменяет $host; повтори позже."
  require_profile "$host" "$profile"
  require_unshared_backends "$host"
  prev="$(cat -- "$(profile_env "$host" "$profile")")"
  CARRIER_MODE="$carrier"
  profile_state_commit "$host" "$profile" "$prev"
  [[ "$BACKEND_PORTS_CHANGED" != 1 ]] || rebuild_firewall
  restart_relay_wait_ready "$host"
  instance_lock_release
  ok "Carrier профиля $profile: $carrier"
}

select_instance() {
  local hosts=() h n
  while read -r h; do [[ -n "$h" ]] && hosts+=("$h"); done < <(list_hosts_array)
  ((${#hosts[@]} > 0)) || die "$(ui_msg no_hostnames)"
  if ((${#hosts[@]} == 1)); then printf '%s' "${hosts[0]}"; return; fi
  n="$(choose "$(ui_msg select_hostname):" "${hosts[@]}")" || return $?
  printf '%s' "${hosts[$((n-1))]}"
}

select_profile() {
  local host="$1" profiles=() p n
  while read -r p; do [[ -n "$p" ]] && profiles+=("$p"); done < <(list_profiles_array "$host")
  ((${#profiles[@]} > 0)) || die "$(ui_msgf no_profiles "$host")"
  if ((${#profiles[@]} == 1)); then printf '%s' "${profiles[0]}"; return; fi
  n="$(choose "$(ui_msg select_profile):" "${profiles[@]}")" || return $?
  printf '%s' "${profiles[$((n-1))]}"
}

list_cmd() {
  need_root; banner
  local host state pcount tls relay admin
  printf "%-34s %-9s %-8s %-14s %-8s %-8s\n" "$(ui_msg hostname)" "$(ui_msg state)" "$(ui_msg profiles_count)" "TLS" "$(ui_msg relay)" "$(ui_msg admin_metrics)"
  printf '%*s\n' 88 '' | tr ' ' '-'
  while read -r host; do
    [[ -n "$host" ]] || continue
    load_instance "$host"; tls="$TLS_MODE"; relay="$RELAY_PORT"; admin="$ADMIN_PORT"; pcount="$(count_profiles "$host")"
    state="$(systemctl is-active "twebproxy@$host.service" 2>/dev/null || true)"
    printf "%-34s %-9s %-8s %-14s %-8s %-8s\n" "$host" "$state" "$pcount" "$tls" "$relay" "$admin"
  done < <(list_hosts_array)
  [[ "$(count_instances)" -gt 0 ]] || printf '%s\n' "$(ui_msg no_instances)"
}

profiles_list_cmd() {
  need_root
  local host="${1:-}" p state masked
  [[ -n "$host" ]] || host="$(select_instance)"
  if [[ "$OUTPUT_MODE" != human ]]; then
    collect_profiles_state "$host"
    case "$OUTPUT_MODE" in json) tcore_render_json;; raw) tcore_render_raw;; esac
    return 0
  fi
  printf "%b%s %s%b\n" "$C_BOLD" "$(ui_msg profiles)" "$host" "$C_RESET"
  printf "%-18s %-18s %-16s %-9s %-9s %-12s\n" "$(ui_msg profile)" "$(ui_msg carrier)" "$(ui_msg secret)" "$(ui_msg backend)" "$(ui_msg stats)" "$(ui_msg state)"
  printf '%*s\n' 90 '' | tr ' ' '-'
  while read -r p; do
    [[ -n "$p" ]] || continue
    load_profile "$host" "$p"
    masked="${SECRET:0:6}…${SECRET: -4}"
    state="$(systemctl is-active "$(bridge_runtime_unit "$host" "$p")" 2>/dev/null || true)"
    printf "%-18s %-18s %-16s %-9s %-9s %-12s\n" "$p" "$CARRIER_MODE" "$masked" "$BACKEND_PORT" "$STATS_PORT" "$state"
  done < <(list_profiles_array "$host")
}

# Read-only probes are bounded: an external command runs at most $1 seconds and
# 124 (or 137) means it timed out; a shell function, as fixtures provide, runs as is.
diag_run() { # $1=seconds, rest=command
  local t="$1"; shift
  if [[ "$(type -t "$1")" == file ]]; then timeout --foreground -k 2 "$t" "$@"; else "$@"; fi
}

# The same for a transcript section: output as is plus a note when the probe
# timed out or the tool is missing; never fails.
diag_show() {
  local rc=0
  diag_run "$DIAG_TIMEOUT" "$@" || rc=$?
  case "$rc" in
    124|137) printf '[%s: timed out after %ss]\n' "$1" "$DIAG_TIMEOUT";;
    127) printf '[%s: not available]\n' "$1";;
  esac
  return 0
}

# Observed state of a systemd unit, or "unknown" when systemd could not be
# asked (missing, timed out, no bus): never mistaken for an inactive unit.
diag_unit_state() { # $1=unit
  local state=""
  state="$(diag_run "$DIAG_TIMEOUT" systemctl is-active "$1" 2>/dev/null)" || true
  case "$state" in
    active|inactive|failed|activating|deactivating|reloading|maintenance|refreshing) printf '%s' "$state";;
    *) printf unknown;;
  esac
}

collect_overview() {
  local host p unit state tls_mode frontend_unit host_count=0 profile_count=0 current_profiles
  tcore_reset overview global

  while read -r host; do
    [[ -n "$host" ]] || continue
    host_count=$((host_count+1))
    current_profiles="$(count_profiles "$host")"
    profile_count=$((profile_count+current_profiles))
  done < <(list_hosts_array)
  TCORE_DATA_JSON="$(jq -cn --argjson hostnames "$host_count" --argjson profiles "$profile_count" \
    '{hostnames:$hostnames,profiles:$profiles}')"

  if (( host_count == 0 )); then
    tcore_add_check "inventory.hostnames" DISABLED info global state 0 ">=1" \
      "No WEB Proxy hostnames are configured" none
    tcore_add_check "anti_dpi.mode" DISABLED info global configuration STOCK STOCK \
      "STOCK mode; no experimental traffic treatment is implemented" none
    tcore_finalize
    return 0
  fi

  tcore_add_check "inventory.hostnames" OK info global state "$host_count" ">=1" \
    "Configured WEB Proxy hostnames" none
  tcore_add_check "inventory.profiles" OK info global state "$profile_count" ">=1 per active hostname" \
    "Configured profiles" none

  while read -r host; do
    [[ -n "$host" ]] || continue
    load_instance "$host"
    tls_mode="$TLS_MODE"
    unit="twebproxy@$host.service"
    state="$(diag_unit_state "$unit")"
    if [[ "$state" == active ]]; then
      tcore_add_check "relay.service.active" OK critical "hostname:$host" systemd active active \
        "Relay service is active" none
    elif [[ "$state" == unknown ]]; then
      tcore_add_check "relay.service.active" UNKNOWN warning "hostname:$host" systemd unknown active \
        "Relay service state could not be determined" none
    else
      tcore_add_check "relay.service.active" ERROR critical "hostname:$host" systemd "${state:-unknown}" active \
        "Relay service is not active" none
    fi

    case "$tls_mode" in
      caddy) frontend_unit="caddy.service";;
      nginx-le|nginx-custom) frontend_unit="nginx.service";;
      manual) frontend_unit="";;
      *) frontend_unit="";;
    esac
    if [[ -z "$frontend_unit" && "$tls_mode" == manual ]]; then
      tcore_add_check "frontend.service.active" DISABLED info "hostname:$host" configuration external external \
        "Frontend is managed externally" none
    elif [[ -n "$frontend_unit" ]]; then
      state="$(diag_unit_state "$frontend_unit")"
      if [[ "$state" == active ]]; then
        tcore_add_check "frontend.service.active" OK critical "hostname:$host" systemd active active \
          "Managed frontend service is active" none
      elif [[ "$state" == unknown ]]; then
        tcore_add_check "frontend.service.active" UNKNOWN warning "hostname:$host" systemd unknown active \
          "Managed frontend service state could not be determined" none
      else
        tcore_add_check "frontend.service.active" ERROR critical "hostname:$host" systemd "${state:-unknown}" active \
          "Managed frontend service is not active" none
      fi
    else
      tcore_add_check "frontend.service.active" UNKNOWN warning "hostname:$host" configuration "$tls_mode" "known frontend mode" \
        "Frontend mode is not recognized" none
    fi

    tcore_add_check "tls.mode" OK info "hostname:$host" configuration "$tls_mode" configured \
      "Configured TLS lifecycle mode" none
    current_profiles="$(count_profiles "$host")"
    if (( current_profiles == 0 )); then
      tcore_add_check "profiles.present" ERROR critical "hostname:$host" state 0 ">=1" \
        "No profiles/backends are configured" none
    else
      tcore_add_check "profiles.present" OK critical "hostname:$host" state "$current_profiles" ">=1" \
        "Profiles/backends are configured" none
    fi

    while read -r p; do
      [[ -n "$p" ]] || continue
      load_profile "$host" "$p"
      state="$(diag_unit_state "$(bridge_runtime_unit "$host" "$p")")"
      if [[ "$state" == active ]]; then
        tcore_add_check "profile.backend.service.active" OK critical "profile:$host/$p" systemd active active \
          "$(bridge_backend_label "$host") service is active" none
      elif [[ "$state" == unknown ]]; then
        tcore_add_check "profile.backend.service.active" UNKNOWN warning "profile:$host/$p" systemd unknown active \
          "MTProxy backend service state could not be determined" none
      else
        tcore_add_check "profile.backend.service.active" ERROR critical "profile:$host/$p" systemd "${state:-unknown}" active \
          "$(bridge_backend_label "$host") service is not active" none
      fi
      tcore_add_check "profile.carrier" OK info "profile:$host/$p" configuration "$CARRIER_MODE" configured \
        "Configured WEB carrier" none
    done < <(list_profiles_array "$host")
    dpi_collect_host_check "$host"
  done < <(list_hosts_array)
  tcore_finalize
}

collect_profiles_state() {
  local host="$1" p count state
  tcore_reset profile-list "hostname:$host"
  TCORE_HOST="$host"
  if ! instance_exists "$host"; then
    tcore_add_check "instance.state.present" ERROR critical "hostname:$host" state absent present \
      "Instance state is missing" none
    tcore_finalize
    return 0
  fi
  load_instance "$host"
  TCORE_TLS_MODE="$TLS_MODE"
  count="$(count_profiles "$host")"
  TCORE_DATA_JSON="$(jq -cn --argjson profiles "$count" '{profiles:$profiles}')"
  if (( count == 0 )); then
    tcore_add_check "profiles.present" ERROR critical "hostname:$host" state 0 ">=1" \
      "No profiles are configured" none
    tcore_finalize
    return 0
  fi
  tcore_add_check "profiles.present" OK critical "hostname:$host" state "$count" ">=1" \
    "Profiles are configured" none
  while read -r p; do
    [[ -n "$p" ]] || continue
    load_profile "$host" "$p"
    tcore_add_check "profile.identity" OK info "profile:$host/$p" configuration "$p" configured \
      "Profile identity" none
    tcore_add_check "profile.carrier" OK info "profile:$host/$p" configuration "$CARRIER_MODE" configured \
      "Configured WEB carrier" none
    state="$(systemctl is-active "$(bridge_runtime_unit "$host" "$p")" 2>/dev/null || true)"
    if [[ "$state" == active ]]; then
      tcore_add_check "profile.backend.service.active" OK critical "profile:$host/$p" systemd active active \
        "$(bridge_backend_label "$host") service is active" none
    else
      tcore_add_check "profile.backend.service.active" ERROR critical "profile:$host/$p" systemd "${state:-unknown}" active \
        "$(bridge_backend_label "$host") service is not active" none
    fi
    tcore_add_check "profile.backend.port" OK info "profile:$host/$p" configuration "$BACKEND_PORT" configured \
      "MTProxy backend port" none
    tcore_add_check "profile.stats.port" OK info "profile:$host/$p" configuration "$STATS_PORT" configured \
      "MTProxy statistics port" none
    if is_valid_secret "${SECRET:-}"; then
      tcore_add_check "profile.secret.configured" OK critical "profile:$host/$p" configuration configured configured \
        "Profile secret is configured and redacted" none
    else
      tcore_add_check "profile.secret.configured" ERROR critical "profile:$host/$p" configuration missing configured \
        "Profile secret is missing or invalid" none
    fi
  done < <(list_profiles_array "$host")
  tcore_finalize
}

render_overview_human() {
  local i
  banner
  printf '%s: %s\n' "$(ui_msg operational_overview_label)" "$(tui_state_text "$TCORE_OVERALL")"
  for i in "${!TCORE_IDS[@]}"; do
    printf '%-38s %-9s %s\n' "${TCORE_SCOPES[$i]} / ${TCORE_IDS[$i]}" "${TCORE_STATUSES[$i]}" "${TCORE_OBSERVED[$i]}"
  done
}

overview_cmd() {
  need_root; need_systemd
  collect_overview
  case "$OUTPUT_MODE" in
    human) render_overview_human;;
    json) tcore_render_json;;
    raw) tcore_render_raw;;
  esac
}

show_profile_cmd() {
  local host="${1:-}" profile="${2:-}"
  [[ -n "$host" ]] || host="$(select_instance)"; [[ -n "$profile" ]] || profile="$(select_profile "$host")"
  load_profile "$host" "$profile"
  printf '%-10s %s\n' "$(ui_msg hostname):" "$host"
  printf '%-10s %s\n' "$(ui_msg profile):" "$profile"
  printf '%-10s %s\n' "$(ui_msg carrier):" "$CARRIER_MODE"
  printf '%-10s %s\n' "$(ui_msg secret):" "$SECRET"
  printf '%-10s %s\n' "$(ui_msg link):" "https://t.me/webproxy?server=$host&secret=$SECRET"
  printf '%-10s %s\n' "$(ui_msg tg_link):" "tg://webproxy?server=$host&secret=$SECRET"
}

show_instance_cmd() {
  local host="${1:-}" p
  [[ -n "$host" ]] || host="$(select_instance)"
  load_instance "$host"
  printf '%-22s %s\n' "$(ui_msg hostname):" "$host"
  printf '%-22s %s\n' "$(ui_msg public_endpoint):" "$(ui_msgf public_endpoint_value "https://$host/")"
  printf '%-22s %s\n' "$(ui_msg relay):" "127.0.0.1:$RELAY_PORT"
  printf '%-22s %s\n' "$(ui_msg admin_metrics):" "127.0.0.1:$ADMIN_PORT"
  printf '%-22s %s\n' "TLS:" "$TLS_MODE"
  printf '%-22s %s\n' "$(ui_msg site):" "$SITE_MODE"
  printf '%-22s %s\n' "$(ui_msg profiles_count):" "$(count_profiles "$host")"
  echo
  while read -r p; do [[ -n "$p" ]] && show_profile_cmd "$host" "$p" && echo; done < <(list_profiles_array "$host")
  client_help_render "$host"
}

# Client guidance for the link forms the manager already prints; nothing here
# claims client support the project has not verified.
client_help_render() { # $1=hostname
  local h="$1"
  tui_section "$(ui_msg client_help_title)"
  printf '  1. %s\n' "$(ui_msg client_help_step1)"
  printf '  2. %s\n' "$(ui_msg client_help_step2)"
  printf '  3. %s\n' "$(ui_msg client_help_step3)"
  printf '  %s\n' "$(ui_msg client_help_support)"
  printf '  %s\n' "$(ui_msgf client_help_check "https://$h/" "$h" "$h")"
}

setup_next_steps() { # $1=hostname
  tui_section "$(ui_msg next_steps_title)"
  printf '  - %s\n' "$(ui_msgf next_status "$1")" "$(ui_msgf next_profiles "$1")" "$(ui_msg next_compat)"
}

manual_snippet_cmd() {
  need_root
  local host="${1:-}" nginx_comment map_comment security_warning endpoint_warning
  [[ -n "$host" ]] || host="$(select_instance)"
  load_instance "$host"
  nginx_comment="$(ui_msg manual_nginx_comment)"
  map_comment="$(ui_msg manual_map_comment)"
  security_warning="$(ui_msg manual_security_warning)"
  endpoint_warning="$(ui_msg manual_endpoint_warning)"
  printf '# %s\n' "$(ui_msg manual_snippet_comment)"
  cat <<EOF
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

# $nginx_comment
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

# $map_comment:
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

$security_warning
$endpoint_warning
EOF
}

cert_end_epoch_file() {
  local cert="$1" end
  [[ -r "$cert" ]] || return 1
  end="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  [[ -n "$end" ]] || return 1
  date -d "$end" +%s 2>/dev/null
}

cert_days_remaining_file() {
  local cert="$1" end now
  end="$(cert_end_epoch_file "$cert")" || return 1
  now="$(date +%s)"
  local delta=$(( end - now ))
  if (( delta >= 0 )); then
    printf '%d' "$(( delta / 86400 ))"
  else
    printf '%d' "$(( - ((-delta + 86399) / 86400) ))"
  fi
}

cert_fingerprint_file() {
  local cert="$1"
  openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null | sed 's/^sha256 Fingerprint=//;s/^SHA256 Fingerprint=//'
}

fetch_public_leaf_cert() {
  local host="$1" out="$2"
  timeout 8 openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null \
    | openssl x509 -outform PEM > "$out" 2>/dev/null
  [[ -s "$out" ]]
}

cert_status_impl() {
  local host="$1" tmp days issuer subject serial public_fp='' local_cert='' local_days='' local_fp='' renew='external'
  instance_exists "$host" || { warn "Нет instance state для $host"; return 1; }
  load_instance "$host"
  tmp="$(mktemp /tmp/twebproxy-cert.XXXXXX.pem)"

  printf '== %s: %s ==\n' "$(ui_msg certificate_status)" "$host"
  printf '%s: %s\n' "$(ui_msg tls_mode_label)" "$TLS_MODE"

  if fetch_public_leaf_cert "$host" "$tmp"; then
    days="$(cert_days_remaining_file "$tmp" 2>/dev/null || echo '?')"
    issuer="$(openssl x509 -in "$tmp" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
    subject="$(openssl x509 -in "$tmp" -noout -subject 2>/dev/null | sed 's/^subject=//')"
    serial="$(openssl x509 -in "$tmp" -noout -serial 2>/dev/null | sed 's/^serial=//')"
    public_fp="$(cert_fingerprint_file "$tmp" 2>/dev/null || true)"
    printf '%s:\n' "$(ui_msg public_certificate)"
    printf '  %-12s %s %s\n' "$(ui_msg remaining_days):" "$days" "$(ui_msg days_suffix)"
    printf '  %-12s %s\n' "$(ui_msg issuer):" "${issuer:-unknown}"
    printf '  %-12s %s\n' "$(ui_msg subject):" "${subject:-unknown}"
    printf '  %-12s %s\n' "$(ui_msg serial):" "${serial:-unknown}"
  else
    warn "Не удалось получить публичный leaf certificate с $host:443"
  fi

  case "$TLS_MODE" in
    caddy)
      if systemctl is-active --quiet caddy.service; then renew="$(ui_msg renew_caddy_native)"; else renew="$(ui_msg renew_caddy_inactive)"; fi
      ;;
    nginx-le)
      local_cert="/etc/letsencrypt/live/$host/fullchain.pem"
      if [[ -r "$local_cert" ]]; then
        local_days="$(cert_days_remaining_file "$local_cert" 2>/dev/null || echo '?')"
        local_fp="$(cert_fingerprint_file "$local_cert" 2>/dev/null || true)"
        printf '%s:\n' "$(ui_msg local_certificate)"
        printf '  %-12s %s\n' "$(ui_msg path):" "$local_cert"
        printf '  %-12s %s %s\n' "$(ui_msg remaining_days):" "$local_days" "$(ui_msg days_suffix)"
        if [[ -n "$public_fp" && -n "$local_fp" ]]; then
          if [[ "$public_fp" == "$local_fp" ]]; then
            printf '  %s: %s\n' "$(ui_msg served_certificate)" "$(ui_msg match)"
          else
            warn "Served cert: MISMATCH — Nginx может отдавать старый/другой сертификат"
          fi
        fi
      else
        warn "Local Let's Encrypt certificate не найден: $local_cert"
      fi
      renew="$(certbot_auto_renew_source 2>/dev/null || true)"
      [[ -n "$renew" ]] || renew="$(ui_msg renew_disabled)"
      ;;
    nginx-custom)
      local_cert="${NGINX_CERT:-}"
      renew="$(ui_msg renew_custom)"
      if [[ -n "$local_cert" && -r "$local_cert" ]]; then
        local_days="$(cert_days_remaining_file "$local_cert" 2>/dev/null || echo '?')"
        local_fp="$(cert_fingerprint_file "$local_cert" 2>/dev/null || true)"
        printf '%s: %s (%s %s)\n' "$(ui_msg local_certificate)" "$local_cert" "$local_days" "$(ui_msg days_suffix)"
        if [[ -n "$public_fp" && -n "$local_fp" ]]; then
          if [[ "$public_fp" == "$local_fp" ]]; then
            printf '%s: %s\n' "$(ui_msg served_certificate)" "$(ui_msg match)"
          else
            warn "Served cert: MISMATCH — Nginx отдаёт не указанный custom certificate"
          fi
        fi
      fi
      ;;
    manual)
      renew="$(ui_msg renew_external)"
      ;;
  esac

  printf '%s: %s\n' "$(ui_msg renewal_management)" "$renew"
  if curl -fsS --max-time 10 --proto '=https' --tlsv1.2 -o /dev/null "https://$host/" >/dev/null 2>&1; then
    printf '%s: %s\n' "$(ui_msg strict_https)" "$(ui_msg status_ok)"
  else
    printf '%s: %s\n' "$(ui_msg strict_https)" "$(ui_msg status_error)"
  fi
  rm -f "$tmp"
}

cert_status_summary() {
  local host="$1" tmp days renew='external'
  load_instance "$host"
  tmp="$(mktemp /tmp/twebproxy-cert-summary.XXXXXX.pem)"
  if fetch_public_leaf_cert "$host" "$tmp"; then days="$(cert_days_remaining_file "$tmp" 2>/dev/null || echo '?')"; else days='?'; fi
  case "$TLS_MODE" in
    caddy) renew='Caddy auto';;
    nginx-le) renew="$(certbot_auto_renew_source 2>/dev/null || true)"; [[ -n "$renew" ]] || renew='OFF';;
    nginx-custom) renew='custom/manual';;
    manual) renew='external';;
  esac
  echo "TLS certificate: mode=$TLS_MODE | remaining=${days}d | renewal=$renew"
  rm -f "$tmp"
}

cert_status_cmd() {
  need_root; banner
  local host="${1:-}"
  [[ -n "$host" ]] || host="$(select_instance)"
  cert_status_impl "$host"
}

cert_renew_cmd() {
  need_root; need_systemd; banner
  local host="${1:-}" force="${2:-}"
  [[ -z "$force" || "$force" == --dry-run || "$force" == --force ]] || die "Использование: twebproxy cert-renew [hostname] [--dry-run|--force]"
  [[ -n "$host" ]] || host="$(select_instance)"
  require_instance "$host"
  load_instance "$host"

  case "$TLS_MODE" in
    nginx-le)
      command -v certbot >/dev/null 2>&1 || die "certbot не установлен. Запусти repair."
      instance_lock_acquire "$host" || die "Другая операция изменяет $host; повтори позже."
      le_cert_usable "$host" || die "Нет пригодного сертификата Let's Encrypt для $host; запусти 'twebproxy repair $host'."
      acme_webroot_prepare || die "Не удалось подготовить $ACME_WEBROOT."
      install_nginx_certbot_deploy_hook
      ensure_nginx_le_auto_renew
      log "Проверяю необходимость продления Let's Encrypt для $host..."
      # Certbot keeps the current lineage when a renewal fails; its deploy hook
      # reloads Nginx only after a renewal that succeeded and passed nginx -t.
      if [[ "$force" == "--dry-run" ]]; then
        certbot renew --cert-name "$host" --dry-run || die "Certbot dry-run для $host не прошёл; рабочий сертификат не менялся."
        ok "Certbot renewal dry-run PASS; рабочий сертификат не заменялся."
        instance_lock_release
        cert_status_impl "$host"
        return 0
      elif [[ "$force" == "--force" ]]; then
        warn "Force renewal может приблизить rate limit Let's Encrypt."
        certbot renew --cert-name "$host" --force-renewal ||
          die "Certbot не продлил сертификат $host; прежний сертификат сохранён и продолжает использоваться."
      else
        certbot renew --cert-name "$host" ||
          die "Certbot не продлил сертификат $host; прежний сертификат сохранён и продолжает использоваться."
      fi
      nginx_test || die "Сертификат $host продлён на диске, но nginx -t не проходит; Nginx не перезагружен и отдаёт прежний сертификат."
      if systemctl is-active --quiet nginx; then
        systemctl reload nginx || die "Сертификат $host продлён на диске, но reload Nginx не удался; Nginx отдаёт прежний сертификат."
      else
        die "Nginx не запущен; сертификат $host продлён на диске, но не применён."
      fi
      instance_lock_release
      if curl -fsS --max-time 10 --proto '=https' --tlsv1.2 -o /dev/null "https://$host/" >/dev/null 2>&1; then
        ok "Certificate renewal check завершён; strict HTTPS PASS."
      else
        die "После renewal/reload публичная TLS-проверка не прошла."
      fi
      cert_status_impl "$host"
      ;;
    caddy)
      ok "Caddy управляет выпуском и продлением сертификата автоматически; ручной Certbot renewal не нужен."
      cert_status_impl "$host"
      ;;
    nginx-custom)
      die "TLS mode nginx-custom: manager не может перевыпустить пользовательский сертификат. Замени cert/key у CA и запусти repair."
      ;;
    manual)
      die "TLS mode manual: lifecycle сертификата находится у внешнего frontend."
      ;;
    *) die "Неизвестный TLS_MODE=$TLS_MODE";;
  esac
}

restart_cmd() {
  need_root; need_systemd; banner
  local host="${1:-}" p
  [[ -n "$host" ]] || host="$(select_instance)"
  if bridge_managed "$host"; then foreign_node_cmd repair; return; fi
  require_instance "$host"
  instance_lock_acquire "$host" || die "Другая операция изменяет $host; повтори позже."
  instance_exists "$host" || die "Нет $host"
  relay_lock_acquire || die "Другая операция обновляет или перезапускает relay; повтори позже."
  while read -r p; do
    [[ -n "$p" ]] && start_profile_backend "$host" "$p"
  done < <(list_profiles_array "$host")
  restart_relay_wait_ready "$host"
  relay_lock_release; instance_lock_release
  ok "$host перезапущен и ready."
}

collect_status() {
  local host="$1" p unit state evidence summary health
  tcore_reset status "hostname:$host"
  TCORE_HOST="$host"
  if ! instance_exists "$host"; then
    tcore_add_check "instance.state.present" ERROR critical "hostname:$host" state absent present \
      "Instance state is missing" none
    tcore_finalize
    return 0
  fi
  load_instance "$host"
  TCORE_TLS_MODE="$TLS_MODE"

  tcore_add_check \
    "instance.state.loaded" OK info "hostname:$host" "state" \
    "$host" "configured instance" "Instance state loaded" none

  summary="$(cert_status_summary "$host" 2>&1 || true)"
  if [[ "$summary" == *'remaining=?d'* || -z "$summary" ]]; then
    tcore_add_check \
      "tls.certificate.summary" UNKNOWN warning "hostname:$host" "openssl/systemd" \
      "$summary" "readable public certificate" "TLS certificate summary is incomplete" plain "$summary"
  else
    tcore_add_check \
      "tls.certificate.summary" OK info "hostname:$host" "openssl/systemd" \
      "$summary" "readable public certificate" "TLS certificate summary collected" plain "$summary"
  fi

  unit="twebproxy@$host.service"
  state="$(diag_unit_state "$unit")"
  evidence="$(diag_run "$DIAG_TIMEOUT" systemctl --no-pager --full status "$unit" 2>&1 || true)"
  if [[ "$state" == active ]]; then
    tcore_add_check "relay.service.active" OK critical "hostname:$host" systemd "$state" active \
      "Relay service is active" service "" "$evidence"
  elif [[ "$state" == unknown ]]; then
    tcore_add_check "relay.service.active" UNKNOWN warning "hostname:$host" systemd unknown active \
      "Relay service state could not be determined" service "" "$evidence"
  else
    tcore_add_check "relay.service.active" ERROR critical "hostname:$host" systemd "${state:-unknown}" active \
      "Relay service is not active" service "" "$evidence"
  fi

  while read -r p; do
    [[ -n "$p" ]] || continue
    if bridge_managed "$host"; then
      unit="$(bridge_forward_unit "$host" 2>/dev/null)" || unit=bridge-state-unknown.service
      tcore_add_check "bridge.mtproto.probe" UNKNOWN warning "profile:$host/$p" bridge unknown "protocol evidence" "MTProto semantic status unavailable" none
      tcore_add_check "bridge.web.client" UNKNOWN warning "profile:$host/$p" bridge unknown "genuine client evidence" "Genuine Telegram client status unavailable" none
    else
    unit="twebproxy-mtproxy@$(backend_id "$host" "$p").service"
    fi
    state="$(diag_unit_state "$unit")"
    evidence="$(diag_run "$DIAG_TIMEOUT" systemctl --no-pager --full status "$unit" 2>&1 || true)"
    if [[ "$state" == active ]]; then
      tcore_add_check "profile.backend.service.active" OK critical "profile:$host/$p" systemd "$state" active \
        "$(bridge_backend_label "$host") service is active" service "" "$evidence"
    elif [[ "$state" == unknown ]]; then
      tcore_add_check "profile.backend.service.active" UNKNOWN warning "profile:$host/$p" systemd unknown active \
        "MTProxy backend service state could not be determined" service "" "$evidence"
    else
      tcore_add_check "profile.backend.service.active" ERROR critical "profile:$host/$p" systemd "${state:-unknown}" active \
        "$(bridge_backend_label "$host") service is not active" service "" "$evidence"
    fi
  done < <(list_profiles_array "$host")

  if health="$(curl -fsS --connect-timeout 2 --max-time 3 "http://127.0.0.1:$ADMIN_PORT/healthz" 2>/dev/null)"; then
    tcore_add_check "relay.healthz" OK critical "hostname:$host" http "$health" success \
      "Relay health endpoint responded" health healthz
  else
    tcore_add_check "relay.healthz" ERROR critical "hostname:$host" http unavailable success \
      "Relay health endpoint did not respond" health healthz
  fi
  if health="$(curl -fsS --connect-timeout 2 --max-time 3 "http://127.0.0.1:$ADMIN_PORT/readyz" 2>/dev/null)"; then
    tcore_add_check "relay.readyz" OK critical "hostname:$host" http "$health" success \
      "Relay readiness endpoint responded" ready readyz
  else
    tcore_add_check "relay.readyz" ERROR critical "hostname:$host" http unavailable success \
      "Relay readiness endpoint did not respond" ready readyz
  fi
  dpi_collect_host_check "$host"
  tcore_finalize
}

render_status_human() {
  local i first_service=1 health_printed=0
  banner
  echo "Host: $TCORE_HOST | TLS: $TCORE_TLS_MODE"
  for i in "${!TCORE_IDS[@]}"; do
    case "${TCORE_HUMAN_LEVELS[$i]}" in
      plain)
        [[ -n "${TCORE_HUMAN_TEXTS[$i]}" ]] && printf '%s\n' "$(ui_localize_legacy "${TCORE_HUMAN_TEXTS[$i]}")"
        ;;
      service)
        if (( first_service )); then first_service=0; else echo; fi
        [[ -n "${TCORE_EVIDENCE[$i]}" ]] && printf '%s\n' "${TCORE_EVIDENCE[$i]}"
        ;;
      health|ready)
        if (( health_printed == 0 )); then echo; health_printed=1; fi
        if [[ "${TCORE_STATUSES[$i]}" == OK ]]; then
          printf '%s <- %s\n' "${TCORE_OBSERVED[$i]}" "${TCORE_HUMAN_TEXTS[$i]}"
        fi
        ;;
    esac
  done
}

status_cmd() {
  need_root
  local host="${1:-}" detail="${2:-}"
  [[ "$host" == --verbose ]] && { detail=--verbose; host=""; }
  [[ -n "$host" ]] || host="$(select_instance)"
  if [[ "$OUTPUT_MODE" == human ]]; then instance_exists "$host" || die "Инстанс не найден: $host"; fi
  collect_status "$host"
  case "$OUTPUT_MODE" in
    human) if [[ "$detail" == --verbose ]]; then render_status_human; else tui_render_status "$host"; fi;;
    json) tcore_render_json;;
    raw) tcore_render_raw;;
  esac
  # Legacy status was observational and returned success even when individual
  # systemd/HTTP probes failed. Preserve that exit behavior in Stage 1.
  return 0
}

collect_statistics_state() {
  local host="$1" p relay_metrics mtstats available_sources=0 profile_sources=0
  tcore_reset stats "hostname:$host"
  TCORE_HOST="$host"
  if ! instance_exists "$host"; then
    tcore_add_check "instance.state.present" ERROR critical "hostname:$host" state absent present \
      "Instance state is missing" none
    tcore_finalize
    return 0
  fi
  load_instance "$host"
  TCORE_TLS_MODE="$TLS_MODE"
  relay_metrics="$(curl -fsS --max-time 4 "http://127.0.0.1:$ADMIN_PORT/metrics" 2>/dev/null || true)"
  if [[ -n "$relay_metrics" ]]; then
    available_sources=$((available_sources+1))
    tcore_add_check "statistics.relay.live" OK info "hostname:$host" relay-metrics available available \
      "Live relay metrics source responded" none "" "$relay_metrics"
  else
    tcore_add_check "statistics.relay.live" UNKNOWN warning "hostname:$host" relay-metrics unavailable available \
      "Live relay metrics source did not respond" none
  fi

  while read -r p; do
    [[ -n "$p" ]] || continue
    load_profile "$host" "$p"
    mtstats="$(curl -fsS --max-time 3 "http://127.0.0.1:$STATS_PORT/stats" 2>/dev/null || true)"
    if [[ -n "$mtstats" ]]; then
      profile_sources=$((profile_sources+1)); available_sources=$((available_sources+1))
      tcore_add_check "statistics.profile.live" OK info "profile:$host/$p" mtproxy-stats available available \
        "Live MTProxy statistics source responded" none "" "$mtstats"
    else
      tcore_add_check "statistics.profile.live" UNKNOWN warning "profile:$host/$p" mtproxy-stats unavailable available \
        "Live MTProxy statistics source did not respond" none
    fi
  done < <(list_profiles_array "$host")

  tcore_add_check "statistics.bandwidth.current" DISABLED info "hostname:$host" unavailable unavailable unavailable \
    "Current bandwidth is unavailable without a previous verified sample" none
  tcore_add_check "statistics.traffic.24h" DISABLED info "hostname:$host" unavailable unavailable unavailable \
    "24-hour traffic is unavailable without persistent counter history" none
  tcore_add_check "statistics.history" DISABLED info "hostname:$host" unavailable unavailable unavailable \
    "Statistics history is deferred; Stage 2 adds no persistent collector" none
  tcore_add_check "statistics.active_users" DISABLED info "hostname:$host" unavailable unavailable unavailable \
    "Active Telegram users cannot be derived from the available sources" none
  tcore_add_check "statistics.latency" DISABLED info "hostname:$host" unavailable unavailable unavailable \
    "No defined latency measurement source is configured" none
  TCORE_DATA_JSON="$(jq -cn --argjson available_sources "$available_sources" --argjson profile_sources "$profile_sources" \
    '{available_sources:$available_sources,profile_sources:$profile_sources,history_available:false}')"
  tcore_finalize
}

stats_cmd() {
  need_root
  local host="${1:-}" detail="${2:-}" p relay_metrics mtstats
  [[ "$host" == --verbose ]] && { detail=--verbose; host=""; }
  [[ -n "$host" ]] || host="$(select_instance)"
  if [[ "$OUTPUT_MODE" != human || "$detail" != --verbose ]]; then
    collect_statistics_state "$host"
    case "$OUTPUT_MODE" in
      json) tcore_render_json;;
      raw) tcore_render_raw;;
      human) tui_render_statistics "$host";;
    esac
    return 0
  fi
  banner; load_instance "$host"
  printf '== %s: %s ==\n' "$(ui_msg verbose_relay_metrics)" "$host"
  relay_metrics="$(curl -fsS --max-time 4 "http://127.0.0.1:$ADMIN_PORT/metrics" 2>/dev/null || true)"
  if [[ -n "$relay_metrics" ]]; then
    printf '%s\n' "$relay_metrics" | grep -Ev '^#|^$' | grep -Ei 'session|stream|backend|bootstrap|pending|byte|reject|error|limit' | head -n 80 || true
  else
    warn "Не удалось получить relay /metrics."
  fi
  echo
  printf '== %s ==\n' "$(ui_msg verbose_backend_stats)"
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
  printf '%b%s%b\n' "$C_DIM" "$(ui_msg verbose_stats_note)" "$C_RESET"
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

firewall_has_backend_port() { # 0 covered; 1 not covered or table absent; 2 nftables did not answer
  local port="$1" rules guard rc=0
  rules="$(diag_run "$DIAG_TIMEOUT" nft list table inet twebproxy_backend 2>/dev/null)" || rc=$?
  [[ "$rc" != 124 && "$rc" != 137 ]] || return 2
  [[ -n "$rules" ]] || return 1
  guard="$(grep -F 'iifname != "lo" tcp dport' <<<"$rules" || true)"
  [[ -n "$guard" ]] || return 1
  grep -Eq "(^|[^0-9])${port}([^0-9]|$)" <<<"$guard"
}

collect_audit() {
  local host="$1" p unit spec label port addrs cert_tmp cert_days cert_local
  local cert_public_fp cert_local_fp renew_source state rules nft_rc public_cert=0 fw_rc
  tcore_reset audit "hostname:$host"
  TCORE_HOST="$host"
  if ! instance_exists "$host"; then
    tcore_add_check "instance.state.present" ERROR critical "hostname:$host" state absent present \
      "Instance state is missing" warn "AUDIT FAIL: нет instance state для $host"
    tcore_finalize
    return 0
  fi
  load_instance "$host"
  TCORE_TLS_MODE="$TLS_MODE"

  tcore_add_check "instance.state.present" OK critical "hostname:$host" state present present \
    "Instance state exists" none

  state="$(diag_unit_state "twebproxy@$host.service")"
  if [[ "$state" == active ]]; then
    tcore_add_check "relay.service.active" OK critical "hostname:$host" systemd active active \
      "Relay service is active" ok "relay service active"
  elif [[ "$state" == unknown ]]; then
    tcore_add_check "relay.service.active" UNKNOWN warning "hostname:$host" systemd unknown active \
      "Relay service state could not be determined" warn "AUDIT WARN: состояние twebproxy@$host.service неизвестно (systemd недоступен или не ответил)"
  else
    tcore_add_check "relay.service.active" ERROR critical "hostname:$host" systemd "$state" active \
      "Relay service is not active" warn "AUDIT FAIL: relay service не active"
  fi

  for spec in "relay:$RELAY_PORT" "admin:$ADMIN_PORT"; do
    label="${spec%%:*}"; port="${spec##*:}"
    addrs="$(listener_addrs_for_port "$port")"
    if [[ -z "$addrs" ]]; then
      tcore_add_check "$label.listener.loopback" ERROR critical "hostname:$host" socket absent "loopback:$port" \
        "$label listener is absent" warn "AUDIT FAIL: $label port $port не слушается"
    elif port_has_only_loopback_listeners "$port"; then
      tcore_add_check "$label.listener.loopback" OK critical "hostname:$host" socket "$(paste -sd, <<<"$addrs")" "loopback only" \
        "$label listener is loopback-only" ok "$label $(paste -sd, <<<"$addrs") — loopback only"
    else
      tcore_add_check "$label.listener.loopback" ERROR critical "hostname:$host" socket "$(paste -sd, <<<"$addrs")" "loopback only" \
        "$label has a non-loopback listener" warn "AUDIT FAIL: $label port $port имеет non-loopback listener(s): $(paste -sd, <<<"$addrs")"
    fi
  done

  state="$(diag_unit_state twebproxy-firewall.service)"
  nft_rc=0; rules="$(diag_run "$DIAG_TIMEOUT" nft list table inet twebproxy_backend 2>/dev/null)" || nft_rc=$?
  if [[ "$state" == active && "$nft_rc" == 0 ]]; then
    tcore_add_check "firewall.backend.boundary" OK critical global nftables active active \
      "Backend firewall service and table are active" ok "backend firewall service/table active"
  elif [[ "$state" == unknown || "$nft_rc" == 124 || "$nft_rc" == 137 ]]; then
    tcore_add_check "firewall.backend.boundary" UNKNOWN warning global nftables unknown active \
      "Backend firewall state could not be determined" warn "AUDIT WARN: состояние backend firewall неизвестно (systemd или nftables не ответили)"
  else
    tcore_add_check "firewall.backend.boundary" ERROR critical global nftables missing active \
      "Backend firewall service or table is missing" warn "AUDIT FAIL: backend firewall service/table отсутствует"
  fi

  local guard_live guard_expected filter_evidence="" filter_rc=0 dc_outside=""
  guard_expected="$(BF_BACKENDS="$BACKENDS_DIR" backend_fw_collect 2>/dev/null)" || guard_expected="?"
  if guard_live="$(BF_NFT=nft BF_GUARD="$FW_GUARD_TABLE" fw_guard_live 2>/dev/null)" && [[ "$guard_live" == "$guard_expected" ]]; then
    tcore_add_check "firewall.guard.owned" OK critical global nftables "owned:${guard_live:-none}" "owned:${guard_expected:-none}" \
      "Owned guard table covers every backend port" ok "owned guard table inet $FW_GUARD_TABLE covers ${guard_live:-no ports}"
  else
    tcore_add_check "firewall.guard.owned" ERROR critical global nftables "${guard_live:-absent}" "owned:${guard_expected:-none}" \
      "Owned guard table is missing or does not cover the backend ports" warn "AUDIT FAIL: owned guard table inet $FW_GUARD_TABLE: ${guard_live:-absent} (expected ${guard_expected:-none})"
  fi

  if dc_outside="$(dc_addresses_outside_allowlist)"; then
    if [[ -z "$dc_outside" ]]; then
      tcore_add_check "backend.egress.dc_coverage" OK warning global configuration covered covered \
        "Every MTProxy DC address is inside the backend egress allowlist" none
    else
      tcore_add_check "backend.egress.dc_coverage" WARNING warning global configuration "$(paste -sd, <<<"$dc_outside")" covered \
        "Some MTProxy DC addresses are outside the backend egress allowlist" warn "AUDIT WARN: адреса DC вне allowlist backend (недоступны для MTProxy): $(paste -sd, <<<"$dc_outside"); обновите manager"
    fi
  else
    tcore_add_check "backend.egress.dc_coverage" UNKNOWN warning global configuration unknown covered \
      "MTProxy routing configuration could not be read" none
  fi

  case "$(proc_hardening_state)" in
    hidden) tcore_add_check "procfs.secret.protection" OK critical global procfs "$(proc_hidepid_value)" hidepid \
      "Other users' processes are hidden" ok "$(ui_msgf proc_status_hidden "$(proc_hidepid_value)")";;
    disabled) tcore_add_check "procfs.secret.protection" WARNING warning global procfs visible hidepid \
      "procfs hardening explicitly disabled by the operator" warn "$(ui_msg proc_status_disabled)";;
    *) tcore_add_check "procfs.secret.protection" ERROR critical global procfs visible hidepid \
      "MTProxy client secret readable through procfs" warn "$(ui_msg proc_status_exposed)";;
  esac

  if (( $(count_profiles "$host") == 0 )); then
    tcore_add_check "profiles.present" ERROR critical "hostname:$host" state 0 ">=1" \
      "No profiles/backends are configured" warn "AUDIT FAIL: у $host нет profiles/backends"
  else
    tcore_add_check "profiles.present" OK critical "hostname:$host" state "$(count_profiles "$host")" ">=1" \
      "At least one profile/backend is configured" none
  fi

  while read -r p; do
    [[ -n "$p" ]] || continue
    load_profile "$host" "$p"
    if bridge_managed "$host"; then
      tcore_add_check "bridge.mtproto.probe" UNKNOWN warning "profile:$host/$p" bridge unavailable "protocol probe" "MTProto semantic probe not executed by isolation audit" warn "Bridge: MTProto/client readiness UNKNOWN; use foreign-node diagnose."
      tcore_add_check "bridge.web.client" UNKNOWN warning "profile:$host/$p" bridge unavailable "genuine client evidence" "Genuine Telegram client result unavailable" none
      if port_has_only_loopback_listeners "$BACKEND_PORT"; then
        tcore_add_check "bridge.forwarder.loopback" OK critical "profile:$host/$p" socket "$BACKEND_PORT" loopback "Bridge forwarder listens on loopback" ok "Bridge loopback listener verified"
      else
        tcore_add_check "bridge.forwarder.loopback" ERROR critical "profile:$host/$p" socket absent loopback "Bridge loopback listener absent or exposed" warn "Bridge listener isolation failure"
      fi
      continue
    fi
    unit="twebproxy-mtproxy@$(backend_id "$host" "$p").service"

    state="$(diag_unit_state "$unit")"
    if [[ "$state" == active ]]; then
      tcore_add_check "profile.backend.service.active" OK critical "profile:$host/$p" systemd active active \
        "MTProxy backend is active" ok "$p: MTProxy backend active"
    elif [[ "$state" == unknown ]]; then
      tcore_add_check "profile.backend.service.active" UNKNOWN warning "profile:$host/$p" systemd unknown active \
        "MTProxy backend state could not be determined" warn "AUDIT WARN: состояние $unit неизвестно (systemd недоступен или не ответил)"
    else
      tcore_add_check "profile.backend.service.active" ERROR critical "profile:$host/$p" systemd "$state" active \
        "MTProxy backend is not active" warn "AUDIT FAIL: $p backend service не active"
    fi

    if diag_run "$DIAG_TIMEOUT" systemctl cat "$unit" 2>/dev/null | grep -Eq '^RestrictAddressFamilies=.*AF_NETLINK'; then
      tcore_add_check "profile.backend.sandbox.af_netlink" OK warning "profile:$host/$p" systemd present present \
        "MTProxy sandbox allows AF_NETLINK" ok "$p: MTProxy sandbox включает AF_NETLINK"
    else
      tcore_add_check "profile.backend.sandbox.af_netlink" WARNING warning "profile:$host/$p" systemd absent present \
        "MTProxy unit does not allow AF_NETLINK" warn "AUDIT WARN: $p unit без AF_NETLINK; запусти repair текущей версией manager"
    fi

    filter_rc=0; filter_evidence="$(backend_socket_filter_check "$unit" "$BACKEND_PORT")" || filter_rc=$?
    if (( filter_rc == 0 )); then
      tcore_add_check "profile.backend.socket_filter" OK critical "profile:$host/$p" systemd "$filter_evidence" enforced \
        "PID 1 socket filter isolates the backend independently of nftables" ok "$p: socket filter PID 1 (IPAddressDeny=any) активен независимо от nftables"
    elif (( filter_rc == 2 )); then
      tcore_add_check "profile.backend.socket_filter" UNKNOWN warning "profile:$host/$p" systemd unknown enforced \
        "Backend socket filter state could not be determined" warn "AUDIT WARN: состояние socket filter $unit неизвестно (systemd недоступен или не ответил)"
    else
      tcore_add_check "profile.backend.socket_filter" ERROR critical "profile:$host/$p" systemd "$filter_evidence" enforced \
        "Backend socket filter is missing or bypassed" warn "AUDIT FAIL: $p socket filter backend отсутствует или обходится ($filter_evidence); запусти repair текущей версией manager"
    fi

    for spec in "backend:$BACKEND_PORT" "stats:$STATS_PORT"; do
      label="${spec%%:*}"; port="${spec##*:}"
      addrs="$(listener_addrs_for_port "$port")"
      if [[ -z "$addrs" ]]; then
        tcore_add_check "profile.$label.listener.present" ERROR critical "profile:$host/$p" socket absent "port:$port" \
          "$label listener is absent" warn "AUDIT FAIL: $p $label port $port не слушается"
        continue
      fi

      fw_rc=0; firewall_has_backend_port "$port" || fw_rc=$?
      if (( fw_rc == 0 )); then
        tcore_add_check "profile.$label.firewall.coverage" OK critical "profile:$host/$p" nftables "$port" covered \
          "$label port is covered by the backend firewall" ok "$p: $label port $port покрыт nftables"
      elif (( fw_rc == 2 )); then
        tcore_add_check "profile.$label.firewall.coverage" UNKNOWN warning "profile:$host/$p" nftables unknown covered \
          "$label port coverage could not be determined" warn "AUDIT WARN: состояние backend firewall неизвестно (systemd или nftables не ответили)"
      else
        tcore_add_check "profile.$label.firewall.coverage" ERROR critical "profile:$host/$p" nftables "$port" covered \
          "$label port is missing from the backend firewall" warn "AUDIT FAIL: $p $label port $port не найден в backend firewall rule"
      fi

      if port_has_only_loopback_listeners "$port"; then
        tcore_add_check "profile.$label.listener.isolation" OK critical "profile:$host/$p" socket "$(paste -sd, <<<"$addrs")" "loopback only or firewall-isolated" \
          "$label listener is loopback-only" ok "$p: $label listener(s) $(paste -sd, <<<"$addrs") — loopback only"
      else
        tcore_add_check "profile.$label.listener.isolation" OK info "profile:$host/$p" socket "$(paste -sd, <<<"$addrs")" "firewall-isolated" \
          "$label listener relies on nftables isolation" info "$p: $label listener(s) $(paste -sd, <<<"$addrs"); external isolation обеспечивается nftables"
      fi
    done

    if curl -fsS --max-time 3 "http://127.0.0.1:$STATS_PORT/stats" >/dev/null 2>&1; then
      tcore_add_check "profile.stats.endpoint" OK warning "profile:$host/$p" http reachable reachable \
        "MTProxy stats endpoint responded on loopback" none
    else
      tcore_add_check "profile.stats.endpoint" WARNING warning "profile:$host/$p" http unavailable reachable \
        "MTProxy stats endpoint did not respond on loopback" warn "AUDIT WARN: $p stats endpoint не ответил на loopback"
    fi
  done < <(list_profiles_array "$host")

  cert_tmp="$(mktemp /tmp/twebproxy-audit-cert.XXXXXX.pem)"
  if fetch_public_leaf_cert "$host" "$cert_tmp"; then
    public_cert=1
    cert_days="$(cert_days_remaining_file "$cert_tmp" 2>/dev/null || true)"
    if [[ "$cert_days" =~ ^-?[0-9]+$ ]]; then
      if (( cert_days < 0 )); then
        tcore_add_check "tls.public.certificate.validity" ERROR critical "hostname:$host" tls "$cert_days" ">=7 days" \
          "Public TLS certificate is expired" warn "AUDIT FAIL: public TLS certificate expired (${cert_days}d)"
      elif (( cert_days < 7 )); then
        tcore_add_check "tls.public.certificate.validity" ERROR critical "hostname:$host" tls "$cert_days" ">=7 days" \
          "Public TLS certificate expires critically soon" warn "AUDIT FAIL: public TLS certificate expires in ${cert_days}d"
      elif (( cert_days < 15 )); then
        tcore_add_check "tls.public.certificate.validity" WARNING warning "hostname:$host" tls "$cert_days" ">=15 days" \
          "Public TLS certificate expires soon" warn "AUDIT WARN: public TLS certificate expires in ${cert_days}d"
      elif (( cert_days < 30 )); then
        tcore_add_check "tls.public.certificate.validity" OK info "hostname:$host" tls "$cert_days" ">=7 days" \
          "Public TLS certificate is valid" info "public TLS certificate expires in ${cert_days}d"
      else
        tcore_add_check "tls.public.certificate.validity" OK info "hostname:$host" tls "$cert_days" ">=7 days" \
          "Public TLS certificate is valid" ok "public TLS certificate valid for ${cert_days}d"
      fi
    else
      tcore_add_check "tls.public.certificate.validity" UNKNOWN warning "hostname:$host" tls unknown "numeric remaining days" \
        "Public TLS certificate validity could not be parsed" none
    fi
  else
    tcore_add_check "tls.public.certificate.available" WARNING warning "hostname:$host" tls unavailable readable \
      "Public leaf certificate could not be read" warn "AUDIT WARN: не удалось отдельно прочитать public leaf certificate"
  fi

  case "$TLS_MODE" in
    nginx-le)
      cert_local="/etc/letsencrypt/live/$host/fullchain.pem"
      if [[ -r "$cert_local" ]]; then
        cert_local_fp="$(cert_fingerprint_file "$cert_local" 2>/dev/null || true)"
        cert_public_fp="$(cert_fingerprint_file "$cert_tmp" 2>/dev/null || true)"
        if (( ! public_cert )); then
          tcore_add_check "tls.certificate.match" UNKNOWN warning "hostname:$host" tls unverified match \
            "Public certificate unavailable; local/public match not verified" warn "AUDIT WARN: публичный сертификат недоступен, совпадение с локальным не проверено"
        elif [[ -n "$cert_local_fp" && -n "$cert_public_fp" && "$cert_local_fp" == "$cert_public_fp" ]]; then
          tcore_add_check "tls.certificate.match" OK critical "hostname:$host" tls match match \
            "Local and public Let's Encrypt certificates match" ok "Let's Encrypt local/public certificate MATCH"
        else
          tcore_add_check "tls.certificate.match" ERROR critical "hostname:$host" tls mismatch match \
            "Local and public Let's Encrypt certificates do not match" warn "AUDIT FAIL: Let's Encrypt local/public certificate MISMATCH"
        fi
      else
        tcore_add_check "tls.local.certificate.present" ERROR critical "hostname:$host" filesystem "$cert_local" readable \
          "Let's Encrypt certificate file is missing" warn "AUDIT FAIL: Let's Encrypt certificate file missing: $cert_local"
      fi
      renew_source="$(certbot_auto_renew_source 2>/dev/null || true)"
      if [[ -n "$renew_source" && "$renew_source" != disabled ]]; then
        tcore_add_check "tls.renewal.active" OK critical "hostname:$host" systemd "$renew_source" active \
          "Let's Encrypt auto-renew is active" ok "Let's Encrypt auto-renew active: $renew_source"
      else
        tcore_add_check "tls.renewal.active" ERROR critical "hostname:$host" systemd disabled active \
          "Let's Encrypt auto-renew timer is inactive" warn "AUDIT FAIL: Let's Encrypt auto-renew timer inactive"
      fi
      ;;
    caddy)
      state="$(diag_unit_state caddy.service)"
      if [[ "$state" == active ]]; then
        tcore_add_check "tls.manager.active" OK critical "hostname:$host" systemd active active \
          "Caddy automatic TLS manager is active" ok "Caddy automatic TLS manager active"
      elif [[ "$state" == unknown ]]; then
        tcore_add_check "tls.manager.active" UNKNOWN warning "hostname:$host" systemd unknown active \
          "Caddy service state could not be determined" warn "AUDIT WARN: состояние caddy.service неизвестно (systemd недоступен или не ответил)"
      else
        tcore_add_check "tls.manager.active" ERROR critical "hostname:$host" systemd inactive active \
          "Caddy service is inactive" warn "AUDIT FAIL: Caddy service inactive"
      fi
      ;;
    nginx-custom)
      cert_local="${NGINX_CERT:-}"
      if [[ -n "$cert_local" && -r "$cert_local" ]]; then
        cert_local_fp="$(cert_fingerprint_file "$cert_local" 2>/dev/null || true)"
        cert_public_fp="$(cert_fingerprint_file "$cert_tmp" 2>/dev/null || true)"
        if (( ! public_cert )); then
          tcore_add_check "tls.certificate.match" UNKNOWN warning "hostname:$host" tls unverified match \
            "Public certificate unavailable; local/public match not verified" warn "AUDIT WARN: публичный сертификат недоступен, совпадение с локальным не проверено"
        elif [[ -n "$cert_local_fp" && -n "$cert_public_fp" && "$cert_local_fp" == "$cert_public_fp" ]]; then
          tcore_add_check "tls.certificate.match" OK critical "hostname:$host" tls match match \
            "Local and public custom certificates match" ok "custom TLS local/public certificate MATCH"
        else
          tcore_add_check "tls.certificate.match" ERROR critical "hostname:$host" tls mismatch match \
            "Local and public custom certificates do not match" warn "AUDIT FAIL: custom TLS local/public certificate MISMATCH"
        fi
      else
        tcore_add_check "tls.local.certificate.present" ERROR critical "hostname:$host" filesystem "${cert_local:-unset}" readable \
          "Custom TLS certificate is missing or unreadable" warn "AUDIT FAIL: custom TLS certificate file missing/unreadable: ${cert_local:-unset}"
      fi
      tcore_add_check "tls.renewal.managed" DISABLED info "hostname:$host" tls external external \
        "Custom certificate re-issuance is not managed" info "custom TLS: expiry monitored; automatic re-issuance is not managed"
      ;;
    manual)
      tcore_add_check "tls.lifecycle.managed" DISABLED info "hostname:$host" tls external external \
        "Certificate lifecycle belongs to the external frontend" info "manual TLS: certificate lifecycle belongs to external frontend"
      ;;
  esac
  rm -f "$cert_tmp"

  if [[ "$TLS_MODE" != manual ]]; then
    if curl -fsS --max-time 10 --proto '=https' --tlsv1.2 -o /dev/null "https://$host/" >/dev/null 2>&1; then
      tcore_add_check "https.public.strict" OK critical "hostname:$host" https pass pass \
        "Public HTTPS and TLS verification passed" ok "public HTTPS + TLS verification PASS"
    else
      tcore_add_check "https.public.strict" ERROR critical "hostname:$host" https fail pass \
        "Public HTTPS/TLS verification failed" warn "AUDIT FAIL: public HTTPS/TLS verification failed (DNS, certificate chain, hostname or frontend)"
    fi
  else
    tcore_add_check "https.public.strict" DISABLED info "hostname:$host" https external external \
      "Strict public HTTPS is managed externally" none
  fi
  dpi_collect_host_check "$host"
  tcore_finalize
}

render_audit_human() {
  local i failures warnings status unknown=0
  failures="$(tcore_error_count)"; warnings="$(tcore_warning_count)"
  for status in "${TCORE_STATUSES[@]}"; do [[ "$status" == UNKNOWN ]] && unknown=$((unknown+1)); done
  if [[ "${TCORE_IDS[0]:-}" == "instance.state.present" && "${TCORE_STATUSES[0]:-}" == ERROR ]]; then
    warn "${TCORE_HUMAN_TEXTS[0]}"
    return 0
  fi
  printf '== %s ==\n' "$(ui_msgf audit_heading "$TCORE_HOST")"
  for i in "${!TCORE_IDS[@]}"; do
    case "${TCORE_HUMAN_LEVELS[$i]}" in
      ok) ok "${TCORE_HUMAN_TEXTS[$i]}";;
      warn) warn "${TCORE_HUMAN_TEXTS[$i]}";;
      info) log "${TCORE_HUMAN_TEXTS[$i]}";;
    esac
  done
  if (( failures > 0 )); then
    warn "AUDIT RESULT: FAIL ($failures critical, $warnings warnings)"
  elif (( unknown > 0 )); then
    warn "AUDIT RESULT: INCOMPLETE ($unknown not verified, $warnings warnings)"
  else
    ok "AUDIT RESULT: PASS ($warnings warnings)"
  fi
}

audit_instance_impl() {
  local host="$1" failures
  collect_audit "$host"
  render_audit_human
  failures="$(tcore_error_count)"
  (( failures == 0 ))
}

audit_cmd() {
  need_root; need_systemd
  local host="${1:-}" failures
  [[ -n "$host" ]] || host="$(select_instance)"
  collect_audit "$host"
  case "$OUTPUT_MODE" in
    human) banner; render_audit_human;;
    json) tcore_render_json;;
    raw) tcore_render_raw;;
  esac
  failures="$(tcore_error_count)"
  (( failures == 0 ))
}

diagnose_cmd() {
  need_root; banner
  local host="${1:-}" p
  [[ -n "$host" ]] || host="$(select_instance)"; load_instance "$host"
  echo "== systemd =="
  printf '%s\n' "$(diag_unit_state "twebproxy@$host.service")"
  while read -r p; do [[ -n "$p" ]] && printf '%s\n' "$(diag_unit_state "twebproxy-mtproxy@$(backend_id "$host" "$p").service")"; done < <(list_profiles_array "$host")
  echo; printf '== %s ==\n' "$(ui_msg diag_listeners)"
  ss -lntp | grep -E ":(80|443|${RELAY_PORT}|${ADMIN_PORT})([[:space:]]|$)" || true
  while read -r p; do
    [[ -n "$p" ]] || continue; load_profile "$host" "$p"
    ss -lntp | grep -E ":(${BACKEND_PORT}|${STATS_PORT})([[:space:]]|$)" || true
  done < <(list_profiles_array "$host")
  echo; printf '== %s ==\n' "$(ui_msg diag_health)"
  curl -v --max-time 5 "http://127.0.0.1:$ADMIN_PORT/healthz" 2>&1 || true
  curl -v --max-time 5 "http://127.0.0.1:$ADMIN_PORT/readyz" 2>&1 || true
  echo; printf '== %s ==\n' "$(ui_msg diag_public_surface)"
  curl -I --max-time 5 -H "Host: $host" "http://127.0.0.1:$RELAY_PORT/" || true
  echo; echo "== DNS =="
  diag_show dig +time=2 +tries=1 +short A "$host"; diag_show dig +time=2 +tries=1 +short AAAA "$host"
  echo; printf '== %s ==\n' "$(ui_msg diag_public_https)"
  curl -I --max-time 10 "https://$host/" || true
  echo; printf '== %s ==\n' "$(ui_msg diag_certificate)"
  timeout 10 openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates || true
  echo; printf '== %s ==\n' "$(ui_msg diag_backend_firewall)"
  diag_show nft list table inet twebproxy_backend
  echo; printf '== %s ==\n' "$(ui_msg dpi_title)"
  diag_show "$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE"
  diag_show systemctl --no-pager --full status "$DPI_FIREWALL_UNIT" "$DPI_NFQWS_UNIT"
  echo
  audit_instance_impl "$host" || true
  echo; printf '== %s ==\n' "$(ui_msg diag_recent_logs)"
  diag_show journalctl -u "twebproxy@$host.service" --since '20 minutes ago' --no-pager -n 120
  while read -r p; do [[ -n "$p" ]] && diag_show journalctl -u "twebproxy-mtproxy@$(backend_id "$host" "$p").service" --since '20 minutes ago' --no-pager -n 60; done < <(list_profiles_array "$host")
}

delete_instance_cmd() {
  need_root; banner
  local host="${1:-}" p id kind old_ip="" ambiguous=0 frontend_note=""; local -a ids=()
  [[ -n "$host" ]] || host="$(select_instance)"; require_instance "$host"
  warn "Будет удалён hostname $host, все его secrets/backends и управляемый reverse-proxy block."
  yesno "Удалить $host?" n || exit 0
  instance_lock_acquire "$host" || die "Другая операция изменяет $host; повтори позже."
  bridge_reject_profile_change "$host"
  require_instance "$host"
  require_unshared_backends "$host"
  old_ip="$(dpi_resolve_ipv4 "$host" 2>/dev/null || true)"
  load_instance "$host"
  while read -r p; do [[ -n "$p" ]] && ids+=("$(backend_id "$host" "$p")"); done < <(list_profiles_array "$host")
  while read -r kind id; do
    [[ -n "$id" ]] || continue
    if [[ "$kind" == orphan ]]; then ids+=("$id"); continue; fi
    warn "Backend env $id нельзя однозначно отнести к $host: имя может принадлежать другому инстансу; файл и защита firewall сохранены."
    ambiguous=1
  done < <(orphan_backend_ids "$host")
  (( ambiguous == 0 )) || die "Для $host есть backend env, который нельзя однозначно отнести к этому инстансу; ничего не удалено."
  # Outermost layer first: if the frontend cannot be removed, nothing else is
  # touched and the instance keeps serving.
  remove_reverse_proxy_for_instance "$host" ||
    die "Frontend для $host не удалён; ничего не удалено, инстанс продолжает работать."
  [[ "$TLS_MODE" == manual ]] || frontend_note="Frontend $host уже отключён; 'twebproxy repair $host' вернёт его."
  # Held until the instance files are gone: a concurrent relay update must not
  # restart this relay in between.
  relay_lock_acquire || { [[ -z "$frontend_note" ]] || warn "$frontend_note"; die "Другая операция обновляет или перезапускает relay; повтори позже."; }
  stop_relay_unit "$host" || {
    [[ -z "$frontend_note" ]] || warn "$frontend_note"
    die "Relay twebproxy@$host.service не остановлен или его состояние неизвестно; ничего не удалено. Проверь его (systemctl status twebproxy@$host.service) и повтори."
  }
  # Every backend of the instance (profiles and orphans) must be proven down
  # before any record or env file is removed; otherwise nothing is deleted and
  # the firewall keeps protecting their ports.
  for id in "${ids[@]}"; do
    stop_backend_unit "$id" && continue
    [[ -z "$frontend_note" ]] || warn "$frontend_note"
    warn "Часть сервисов $host могла быть остановлена; 'twebproxy repair $host' снова запустит их."
    die "Backend twebproxy-mtproxy@$id.service не остановлен или его состояние неизвестно; ничего не удалено, защита firewall сохранена. Проверь его (systemctl status twebproxy-mtproxy@$id.service) и повтори."
  done
  for id in "${ids[@]}"; do rm -f -- "$BACKENDS_DIR/$id.env"; done
  rm -rf "$(instance_dir "$host")" "$(site_dir "$host")"
  relay_lock_release
  rebuild_firewall
  dpi_with_mutation_lock dpi_remove_host_state_if_orphaned "$old_ip" || warn "$(ui_msg dpi_repair_warning)"
  instance_lock_release
  ok "$host удалён."
}

update_cmd() {
  need_root; need_systemd; check_platform; banner; ensure_core
  local update_fd work candidate prev host rc=0
  local -a hosts=()
  # One relay update at a time (it also owns the upstream checkout).
  state_lock_path relay-update && exec {update_fd}>>"$STATE_LOCK_PATH" &&
    flock -w "$STATE_LOCK_WAIT_SECONDS" "$update_fd" ||
    die "Другая операция обновляет или перезапускает relay; повтори позже."
  install_base_deps; ensure_go; sync_tproxy_upstream latest
  work="$(mktemp -d /tmp/twebproxy-relay-update.XXXXXX)" || die "Не удалось собрать candidate tproxy-server; update отменён."
  candidate="$work/tproxy-server"
  if ! (umask 022; cd "$TPROXY_SRC" && "$GO_BIN" test ./...); then
    rm -rf -- "$work"
    die "Upstream test suite tproxy-server не прошёл; update отменён до замены binary."
  fi
  if ! (umask 022; cd "$TPROXY_SRC" && "$GO_BIN" build -trimpath -ldflags='-s -w' -o "$candidate" ./cmd/tproxy-server); then
    rm -rf -- "$work"
    die "Не удалось собрать candidate tproxy-server; update отменён."
  fi
  chmod 0755 "$candidate"
  if ! relay_lock_acquire; then
    rm -rf -- "$work"; die "Другая операция обновляет или перезапускает relay; повтори позже."
  fi
  while read -r host; do [[ -n "$host" ]] && hosts+=("$host"); done < <(list_hosts_array)
  for host in "${hosts[@]}"; do
    if ! "$candidate" -config "$(instance_dir "$host")/config.json" -profiles-file "$(profiles_json "$host")" -check >/dev/null; then
      rm -rf -- "$work"; die "Новая версия не проходит config check для $host"
    fi
  done
  if ! prev="$(relay_previous_save)"; then
    rm -rf -- "$work"; die "Не удалось сохранить текущий relay binary; update отменён до замены binary."
  fi
  # From the binary swap until the outcome is known an interruption only marks
  # the update as failed; relay_update_apply then rolls back (bounded waits).
  RELAY_UPDATE_INTERRUPTED=0
  trap 'RELAY_UPDATE_INTERRUPTED=1' INT TERM HUP
  relay_update_apply "$candidate" "$prev" "${hosts[@]}" || rc=$?
  trap - INT TERM HUP
  rm -rf -- "$work"
  case "$rc" in
    0) ;;
    1) die "Update откатан.";;
    2) die "Откат relay неполный: прежний binary восстановлен, но не ready: $RELAY_UPDATE_NOTREADY. Проверь их и выполни 'twebproxy restart <hostname>'.";;
    3) die "Откат relay не удался: прежний binary не восстановлен, его копия: $prev. Relays, перезапущенные с новым binary: ${RELAY_UPDATE_NOTREADY:--}.";;
    *) die "Не удалось записать новый relay binary; прежний binary и relays не изменены.";;
  esac
  relay_lock_release
  write_global_env; install_manager_copy
  ok "Relay обновлён до $UPSTREAM_COMMIT."
}

core_uninstall_cmd() {
  need_root; banner
  (( $(count_instances) == 0 )) || die "Сначала удали все hostname через 'twebproxy delete'."
  warn "Удалится база TWebProxy, systemd templates, relay binary и официальный MTProxy build."
  yesno "Удалить core?" n || exit 0
  local dpi_rc=0
  dpi_with_mutation_lock dpi_full_uninstall || dpi_rc=$?
  (( dpi_rc == DPI_LOCK_BUSY_RC )) && die "$(ui_msg dpi_mutation_busy)"
  # One unit at a time while its file still exists: a single "disable --now A B C"
  # fails as a whole when one file is missing, leaving active units and dangling
  # .wants symlinks behind. Stopping the firewall ends the owned guard session.
  local unit
  for unit in twebproxy-refresh-mtproxy.timer twebproxy-cert-renew.timer twebproxy-firewall.service; do
    [[ -e "$SYSTEMD_DIR/$unit" ]] || continue
    systemctl disable --now "$unit" >/dev/null 2>&1 || systemctl stop "$unit" >/dev/null 2>&1 || true
  done
  find "$SYSTEMD_DIR" -xtype l -name 'twebproxy*' -delete 2>/dev/null || true
  rm -f -- "$SYSTEMD_DIR/nftables.service.d/$FW_NFT_DROPIN"
  rmdir "$SYSTEMD_DIR/nftables.service.d" 2>/dev/null || true
  if nft list table inet twebproxy_backend >/dev/null 2>&1; then nft delete table inet twebproxy_backend || true; fi
  rm -f "$SYSTEMD_DIR/twebproxy@.service" "$SYSTEMD_DIR/twebproxy-mtproxy@.service" "$SYSTEMD_DIR/twebproxy-firewall.service" "$SYSTEMD_DIR/twebproxy-refresh-mtproxy.service" "$SYSTEMD_DIR/twebproxy-refresh-mtproxy.timer" "$SYSTEMD_DIR/twebproxy-cert-renew.service" "$SYSTEMD_DIR/twebproxy-cert-renew.timer"
  rm -f /etc/letsencrypt/renewal-hooks/deploy/twebproxy-nginx-reload
  rm -rf "$BASE_DIR" "$TPROXY_SRC" "$MTPROXY_SRC"
  rm -f "$MTPROXY_BIN" "$LIBEXEC_DIR/run-mtproxy" "$LIBEXEC_DIR/apply-firewall" "$LIBEXEC_DIR/firewall-guard" "$LIBEXEC_DIR/backend-start-check" "$LIBEXEC_DIR/refresh-mtproxy-config"
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
  since="$(diag_run "$DIAG_TIMEOUT" systemctl show "$unit" -p ActiveEnterTimestamp --value 2>/dev/null || true)"
  if [[ -n "$since" && "$since" != "n/a" ]]; then
    diag_show journalctl -u "$unit" --since "$since" -n "$max_lines" --no-pager -o short-iso-precise
  else
    diag_show journalctl -u "$unit" -n "$max_lines" --no-pager -o short-iso-precise
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
      diag_show journalctl -u "twebproxy@$host.service" --since '24 hours ago' -n 160 --no-pager -o short-iso-precise
      while read -r p; do
        [[ -n "$p" ]] || continue
        unit="twebproxy-mtproxy@$(backend_id "$host" "$p").service"
        echo "-- backend journal: $p / last 24h / max 120 --"
        diag_show journalctl -u "$unit" --since '24 hours ago' -n 120 --no-pager -o short-iso-precise
      done < <(list_profiles_array "$host")
      echo
    done < <(list_hosts_array)
  } 2>&1 | $filter_cmd > "$out"
  chmod 0600 "$out"
  printf '%s' "$out"
}

# Copies $1 to $2 (0600); "redact" re-applies the current redaction (safe
# bundles), anything else copies as is. Fails, leaving nothing, when the source
# vanished or cannot be read.
logs_copy_file() { # $1=src $2=dst $3=redact|""
  if [[ "$3" == redact ]]; then
    if cat -- "$1" | sanitize_log_stream > "$2" && chmod 0600 -- "$2"; then return 0; fi
  elif cp -a -- "$1" "$2"; then
    return 0
  fi
  rm -f -- "$2"; return 1
}

copy_recent_files() { # $1=src $2=dst $3=pattern $4=limit [$5 $6=excluded files] [$7=redact]
  local src="$1" dst="$2" pattern="$3" limit="$4" exclude1="${5:-}" exclude2="${6:-}" filter="${7:-}" f count=0
  local files=()
  [[ -d "$src" ]] || return 0
  install -d -m 0700 "$dst"
  mapfile -t files < <(find "$src" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
  for f in "${files[@]}"; do
    [[ -n "$f" ]] || continue
    [[ -n "$exclude1" && "$f" == "$exclude1" ]] && continue
    [[ -n "$exclude2" && "$f" == "$exclude2" ]] && continue
    # A log can be rotated away or unreadable meanwhile: note it and go on.
    if ! logs_copy_file "$f" "$dst/${f##*/}" "$filter"; then
      printf 'skipped %s: removed or unreadable\n' "${f##*/}" >> "$dst/SKIPPED.txt"
      continue
    fi
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
    echo "manager_version=$MANAGER_RELEASE_VERSION"
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
    diag_run "$DIAG_TIMEOUT" hostnamectl 2>/dev/null || hostname || true
    echo
    echo "== network addresses/routes =="
    ip -br addr 2>/dev/null || true
    ip route show 2>/dev/null || true
    ip -6 route show 2>/dev/null || true
    echo
    echo "== listeners =="
    ss -lntp 2>/dev/null || true
    echo
    echo "== firewall =="
    diag_show nft list table inet twebproxy_backend
    diag_show "$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE"
    echo
    echo "== optional network compatibility =="
    find "$DPI_STATE_DIR" -maxdepth 1 -type f -name '*.env' -print -exec sed -n '1,20p' {} \; 2>/dev/null || true
    diag_show systemctl --no-pager --full status "$DPI_FIREWALL_UNIT" "$DPI_NFQWS_UNIT"
    [[ -f "$DPI_NFQWS_BIN" ]] && sha256sum "$DPI_NFQWS_BIN" || true
    command -v ufw >/dev/null 2>&1 && diag_show ufw status verbose
    echo
    echo "== binaries / source =="
    [[ -x "$TPROXY_BIN" ]] && { ls -l "$TPROXY_BIN"; sha256sum "$TPROXY_BIN"; } || true
    [[ -x "$MTPROXY_BIN" ]] && { ls -l "$MTPROXY_BIN"; sha256sum "$MTPROXY_BIN"; } || true
    [[ -e "$MTPROXY_SRC/objs/bin/mtproto-proxy" ]] && { echo "-- MTProxy build artifact (source tree) --"; ls -l "$MTPROXY_SRC/objs/bin/mtproto-proxy"; } || true
    stat "$MTPROXY_DATA_DIR" "$MTPROXY_DATA_DIR/proxy-secret" "$MTPROXY_DATA_DIR/proxy-multi.conf" 2>/dev/null || true
    [[ -d "$TPROXY_SRC/.git" ]] && { diag_show git -C "$TPROXY_SRC" status --short --branch; diag_show git -C "$TPROXY_SRC" rev-parse HEAD; } || true
    [[ -d "$MTPROXY_SRC/.git" ]] && { diag_show git -C "$MTPROXY_SRC" status --short --branch; diag_show git -C "$MTPROXY_SRC" rev-parse HEAD; } || true
    echo
    echo "== systemd templates =="
    diag_show systemctl cat twebproxy@.service 2>/dev/null
    diag_show systemctl cat twebproxy-mtproxy@.service 2>/dev/null
    diag_show systemctl cat twebproxy-firewall.service 2>/dev/null
    diag_show systemctl cat twebproxy-refresh-mtproxy.service 2>/dev/null
    diag_show systemctl cat twebproxy-refresh-mtproxy.timer 2>/dev/null
    echo

    while read -r host; do
      [[ -n "$host" ]] || continue
      echo "################################################################"
      echo "HOST: $host"
      echo "################################################################"
      echo "-- DNS --"
      diag_show getent ahosts "$host" 2>/dev/null
      command -v dig >/dev/null 2>&1 && { diag_show dig +time=2 +tries=1 +short A "$host"; diag_show dig +time=2 +tries=1 +short AAAA "$host"; } || true
      echo "-- isolation audit --"
      audit_instance_impl "$host" || true
      echo
      echo "-- certificate status --"
      cert_status_impl "$host" || true
      echo "-- relay status --"
      diag_show systemctl --no-pager --full status "twebproxy@$host.service"
      echo "-- relay properties --"
      diag_show systemctl show "twebproxy@$host.service" -p Id -p LoadState -p ActiveState -p SubState -p MainPID -p ExecMainStatus -p FragmentPath -p DropInPaths -p User -p Group -p LimitNOFILE -p Restart
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
        diag_show systemctl --no-pager --full status "$unit"
        diag_show systemctl show "$unit" -p Id -p LoadState -p ActiveState -p SubState -p MainPID -p ExecMainStatus -p FragmentPath -p User -p Group -p LimitNOFILE -p Restart
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

# ---------------------------------------------------------------------------
# Field diagnostics.  One command that captures a bounded, shareable picture of
# a single field test.  Strictly observational: it never repairs, restarts,
# reloads or mutates proxy, firewall or DPI state, and its only side effects are
# the diagnostic files it writes plus its own temporary tcpdump process.
# ---------------------------------------------------------------------------

FIELD_CAPTURE_SECONDS=90          # reproduction window; fixtures shorten this
FIELD_INSTANT_JOURNAL_WINDOW="20 min ago"
FIELD_TCPDUMP_SNAPLEN=128         # headers + TCP options only, never full payload
FIELD_TCPDUMP_PID=""
FIELD_STAGING=""
FIELD_BUNDLE_PARTIAL=""   # set only while the archive is being written

field_safe_label() { printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_'; }

# Units worth reading for this host: relay, every MTProxy backend of the host,
# plus the shared firewall/DPI units when they exist.
field_units_for_host() {
  local host="$1" p
  printf '%s\n' "twebproxy@$host.service"
  while read -r p; do
    [[ -n "$p" ]] || continue
    printf '%s\n' "twebproxy-mtproxy@$(backend_id "$host" "$p").service"
  done < <(list_profiles_array "$host" 2>/dev/null || true)
  printf '%s\n' "twebproxy-firewall.service"
  [[ -f "$SYSTEMD_DIR/$DPI_FIREWALL_UNIT" ]] && printf '%s\n' "$DPI_FIREWALL_UNIT"
  [[ -f "$SYSTEMD_DIR/$DPI_NFQWS_UNIT" ]] && printf '%s\n' "$DPI_NFQWS_UNIT"
  return 0
}

# Exact-window journals for the selected host only.  Bounded, sanitized, and
# never a system-wide dump.
field_collect_journal_window() {
  local host="$1" out="$2" since="$3" until_ts="$4" unit
  {
    echo "TWebProxy field journal window"
    echo "host=$host"
    echo "since=$since"
    echo "until=${until_ts:-now}"
    echo
    if ! command -v journalctl >/dev/null 2>&1; then
      echo "journalctl_unavailable=yes"
    else
      while read -r unit; do
        [[ -n "$unit" ]] || continue
        echo "== $unit =="
        if [[ -n "$until_ts" ]]; then
          diag_show journalctl -u "$unit" --since "$since" --until "$until_ts" \
            -n 2000 --no-pager -o short-iso-precise 2>&1
        else
          diag_show journalctl -u "$unit" --since "$since" \
            -n 2000 --no-pager -o short-iso-precise 2>&1
        fi
        echo
      done < <(field_units_for_host "$host")
    fi
  } 2>&1 | sanitize_log_stream > "$out"
  chmod 0600 "$out" 2>/dev/null || true
  return 0
}

# Read-only nftables evidence.  `-a` keeps handles and counters so before/after
# can be compared.  Never mutates or resets anything.
field_collect_nft() {
  local out="$1" label="$2"
  {
    echo "TWebProxy field nftables evidence ($label)"
    echo "collected_at=$(date -Is)"
    echo
    if ! command -v "$DPI_NFT_BIN" >/dev/null 2>&1 && [[ ! -x "$DPI_NFT_BIN" ]]; then
      echo "nft_unavailable=yes"
    else
      echo "== table inet twebproxy_backend =="
      if diag_run "$DIAG_TIMEOUT" "$DPI_NFT_BIN" -a list table inet twebproxy_backend 2>/dev/null; then :; else
        echo "table_absent_or_unreadable=yes"
      fi
      echo
      echo "== table ip $DPI_NFT_TABLE =="
      if diag_run "$DIAG_TIMEOUT" "$DPI_NFT_BIN" -a list table ip "$DPI_NFT_TABLE" 2>/dev/null; then :; else
        echo "table_absent_or_unreadable=yes"
      fi
    fi
  } 2>&1 | sanitize_log_stream > "$out"
  chmod 0600 "$out" 2>/dev/null || true
  return 0
}

# Best effort.  Sets FIELD_TCPDUMP_PID only when a capture is actually running.
field_trace_start() {
  local pcap="$1" rc=0
  FIELD_TCPDUMP_PID=""
  command -v tcpdump >/dev/null 2>&1 || return 1
  tcpdump -i any -n -s "$FIELD_TCPDUMP_SNAPLEN" -w "$pcap" \
    'tcp port 443' >/dev/null 2>&1 &
  FIELD_TCPDUMP_PID=$!
  sleep 1
  if ! kill -0 "$FIELD_TCPDUMP_PID" 2>/dev/null; then
    wait "$FIELD_TCPDUMP_PID" 2>/dev/null || rc=$?
    FIELD_TCPDUMP_PID=""
    return 1
  fi
  return 0
}

# Stops only the capture this invocation started.  Never pkill.
field_trace_stop() {
  local pid="${FIELD_TCPDUMP_PID:-}" i=0
  [[ -n "$pid" ]] || return 0
  FIELD_TCPDUMP_PID=""
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while (( i < 30 )); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1; i=$((i+1))
    done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
  fi
  wait "$pid" 2>/dev/null || true
  return 0
}

# Text summary only.  Deliberately no -X/-A/payload hexdump; -v keeps TCP flags,
# options, MSS, window, seq/ack and length, which is what TCP diagnosis needs.
field_render_trace_text() {
  local pcap="$1" out="$2" rc=0
  {
    echo "TWebProxy field packet trace (text summary)"
    echo "filter=tcp port 443"
    echo "snaplen=$FIELD_TCPDUMP_SNAPLEN"
    echo "note=headers and TCP options only; no payload bytes are rendered"
    echo
    if [[ ! -s "$pcap" ]]; then
      echo "capture_empty=yes"
    else
      tcpdump -nn -tttt -v -r "$pcap" 2>/dev/null || rc=$?
      (( rc == 0 )) || echo "render_failed_rc=$rc"
    fi
  } 2>&1 | sanitize_log_stream > "$out"
  chmod 0600 "$out" 2>/dev/null || true
  return 0
}

# Best-effort wrapper around the existing snapshot collector. That collector runs
# many optional probes and can return non-zero on a degraded host, so field
# diagnostics must not treat a partial snapshot as a fatal error. The artifact it
# writes is recovered from its own log directory even when it exits non-zero.
field_capture_runtime() {
  local label="$1" dest="$2" snap=""
  snap="$(collect_runtime_snapshot safe "$label" 2>/dev/null || true)"
  if [[ -z "$snap" || ! -f "$snap" ]]; then
    snap="$(find "$LOG_RUNTIME_DIR" -maxdepth 1 -type f -name "*-${label}.log" \
      -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2- || true)"
  fi
  if [[ -n "$snap" && -f "$snap" ]] && cp -a "$snap" "$dest" 2>/dev/null; then
    chmod 0600 "$dest" 2>/dev/null || true
    return 0
  fi
  { echo "TWebProxy runtime snapshot"
    echo "runtime_snapshot=unavailable"
    echo "collected_at=$(date -Is)"; } > "$dest"
  chmod 0600 "$dest" 2>/dev/null || true
  return 1
}

# A Bash INT/TERM trap does NOT terminate the interrupted command: without an
# explicit exit the handler returns and the command resumes, which would carry
# on collecting and packaging after the staging directory had been removed. The
# handler therefore cancels the whole field report.
field_report_on_signal() {
  local rc="$1"
  trap - EXIT INT TERM          # never re-enter while cleaning up
  field_report_cleanup
  warn "$(ui_msg field_cancelled)"
  exit "$rc"
}

field_report_cleanup() {
  field_trace_stop
  if [[ -n "${FIELD_STAGING:-}" && -d "${FIELD_STAGING:-}" ]]; then
    rm -rf --one-file-system -- "$FIELD_STAGING" 2>/dev/null || true
  fi
  FIELD_STAGING=""
  # An archive interrupted mid-write is truncated and must not be left behind
  # looking like a finished report.
  if [[ -n "${FIELD_BUNDLE_PARTIAL:-}" && -f "${FIELD_BUNDLE_PARTIAL:-}" ]]; then
    rm -f -- "$FIELD_BUNDLE_PARTIAL" 2>/dev/null || true
  fi
  FIELD_BUNDLE_PARTIAL=""
  return 0
}

field_report_cmd() {
  need_root
  local host="" instant=0 keep_pcap=0 arg
  for arg in "$@"; do
    case "$arg" in
      --instant)   instant=1 ;;
      --keep-pcap) keep_pcap=1 ;;
      -*)          die "$(ui_msg field_usage)" ;;
      *)           [[ -z "$host" ]] || die "$(ui_msg field_usage)"; host="$arg" ;;
    esac
  done
  [[ -n "$host" ]] || host="$(select_instance)"
  [[ -n "$host" ]] || die "$(ui_msg field_usage)"
  require_instance "$host"

  local safe_host row ip_scope dpi_before dpi_after ts bundle
  safe_host="$(field_safe_label "$host")"
  row="$(dpi_mode_for_host "$host" || true)"
  ip_scope="${row%%$'\t'*}"; dpi_before="${row#*$'\t'}"
  [[ -n "$ip_scope" ]] || ip_scope=unknown
  [[ -n "$dpi_before" ]] || dpi_before=unknown

  banner
  printf '%s\n\n' "$(ui_msg field_title)"
  tui_kv "$(ui_msg field_host)" "$host"
  tui_kv "$(ui_msg field_dpi)" "$dpi_before"
  tui_kv "$(ui_msg field_ipv4)" "$ip_scope"
  echo

  # Staging failure is fatal: without it there is no report at all.
  FIELD_STAGING="$(mktemp -d /tmp/twebproxy-field.XXXXXX)" \
    || die "$(ui_msg field_staging_failed)"
  chmod 0700 "$FIELD_STAGING" || die "$(ui_msg field_staging_failed)"
  trap 'field_report_cleanup' EXIT
  trap 'field_report_on_signal 130' INT
  trap 'field_report_on_signal 143' TERM

  local started_at ended_at duration=0 observation packet_trace=unavailable snapshot_status=ok
  local pcap="$FIELD_STAGING/.raw.pcap" trace_started=0
  started_at="$(date -Is)"

  if (( instant )); then
    observation=not_recorded
    log "$(ui_msg field_collecting)"
    field_capture_runtime field-current "$FIELD_STAGING/current-runtime.log" || snapshot_status=degraded
    field_collect_nft "$FIELD_STAGING/nft-current.txt" current
    ended_at="$(date -Is)"
    field_collect_journal_window "$host" "$FIELD_STAGING/journal-window.log" \
      "$FIELD_INSTANT_JOURNAL_WINDOW" ""
    dpi_after="$dpi_before"
    packet_trace=not_applicable
  else
    field_capture_runtime field-before "$FIELD_STAGING/before-runtime.log" || snapshot_status=degraded
    field_collect_nft "$FIELD_STAGING/nft-before.txt" before
    ok "$(ui_msg field_initial_captured)"
    echo

    if (( keep_pcap )); then warn "$(ui_msg field_pcap_warning)"; fi
    if command -v tcpdump >/dev/null 2>&1; then
      if field_trace_start "$pcap"; then
        trace_started=1; packet_trace=captured
      else
        packet_trace=start_failed; warn "$(ui_msg field_trace_failed)"
      fi
    else
      packet_trace=unavailable; warn "$(ui_msg field_trace_unavailable)"
    fi

    started_at="$(date -Is)"
    printf '%s\n%s\n%s\n' "$(ui_msg field_reproduce)" "$(ui_msg field_press_enter)" \
      "$(ui_msgf field_max_window "$FIELD_CAPTURE_SECONDS")"
    # A timed-out read returns non-zero; that is a normal completion here and
    # must never reach errexit.
    local _reply=""
    read -r -t "$FIELD_CAPTURE_SECONDS" _reply || true
    ended_at="$(date -Is)"
    # If anything removed staging while we waited, stop here rather than letting
    # "$FIELD_STAGING/..." collapse to a root-level path.
    [[ -n "${FIELD_STAGING:-}" && -d "$FIELD_STAGING" ]] || die "$(ui_msg field_cancelled)"

    (( trace_started )) && field_trace_stop
    log "$(ui_msg field_collecting)"

    if (( trace_started )); then
      field_render_trace_text "$pcap" "$FIELD_STAGING/packet-trace.txt"
      if (( keep_pcap )); then
        mv -f "$pcap" "$FIELD_STAGING/packet-trace.pcap" 2>/dev/null || true
        chmod 0600 "$FIELD_STAGING/packet-trace.pcap" 2>/dev/null || true
      fi
    else
      { echo "TWebProxy field packet trace (text summary)"
        echo "packet_trace=$packet_trace"; } > "$FIELD_STAGING/packet-trace.txt"
      chmod 0600 "$FIELD_STAGING/packet-trace.txt"
    fi
    # Raw capture never survives unless explicitly requested.
    rm -f -- "$pcap" 2>/dev/null || true

    field_capture_runtime field-after "$FIELD_STAGING/after-runtime.log" || snapshot_status=degraded
    field_collect_nft "$FIELD_STAGING/nft-after.txt" after
    field_collect_journal_window "$host" "$FIELD_STAGING/journal-window.log" \
      "$started_at" "$ended_at"

    row="$(dpi_mode_for_host "$host" || true)"; dpi_after="${row#*$'\t'}"
    [[ -n "$dpi_after" ]] || dpi_after=unknown

    observation=not_tested
    if [[ -t 0 && -t 1 ]]; then
      local choice=""
      choice="$(choose "$(ui_msg field_observation_q)" \
        "$(ui_msg field_obs_connected)" "$(ui_msg field_obs_disconnected)" \
        "$(ui_msg field_obs_unstable)" "$(ui_msg field_obs_not_tested)" || true)"
      case "$choice" in
        1) observation=connected ;;
        2) observation=disconnected ;;
        3) observation=unstable ;;
        *) observation=not_tested ;;
      esac
    fi
  fi

  duration=0
  local t0 t1
  t0="$(date -d "$started_at" +%s 2>/dev/null || printf '')"
  t1="$(date -d "$ended_at" +%s 2>/dev/null || printf '')"
  if [[ "$t0" =~ ^[0-9]+$ && "$t1" =~ ^[0-9]+$ ]]; then duration=$((t1 - t0)); fi

  if [[ -n "${CURRENT_LOG:-}" && -f "${CURRENT_LOG:-}" ]]; then
    cp -a "$CURRENT_LOG" "$FIELD_STAGING/manager-session.log" 2>/dev/null || true
    chmod 0600 "$FIELD_STAGING/manager-session.log" 2>/dev/null || true
  fi

  local raw_included=no
  [[ -f "$FIELD_STAGING/packet-trace.pcap" ]] && raw_included=yes
  {
    echo "manager_version=$MANAGER_RELEASE_VERSION"
    echo "created_at=$(date -Is)"
    echo "hostname=$host"
    echo "capture_mode=$( ((instant)) && printf instant || printf reproduction )"
    echo "started_at=$started_at"
    echo "ended_at=$ended_at"
    echo "duration_seconds=$duration"
    echo "client_observation=$observation"
    echo "dpi_mode_before=$dpi_before"
    echo "dpi_mode_after=$dpi_after"
    echo "ipv4_scope=$ip_scope"
    echo "packet_trace=$packet_trace"
    echo "raw_pcap_included=$raw_included"
    echo "runtime_snapshot=$snapshot_status"
    echo "environment_notes=$(uname -sr 2>/dev/null || printf unknown)"
    echo
    echo "note=Client-side Telegram success or failure is reported by the operator."
    echo "note=It is NOT inferred from server logs; server evidence alone cannot confirm it."
    echo "note=Safe bundle: WEB/MTProxy secrets are redacted; TLS/SSH private keys and root credentials are not collected."
  } > "$FIELD_STAGING/FIELD-TEST.txt"
  chmod 0600 "$FIELD_STAGING/FIELD-TEST.txt"

  install -d -o root -g root -m 0700 "$LOG_BUNDLE_DIR" || die "$(ui_msg field_archive_failed)"
  ts="$(date '+%Y%m%d-%H%M%S')"
  bundle="$LOG_BUNDLE_DIR/twebproxy-field-${safe_host}-${ts}.tar.gz"

  ( cd "$FIELD_STAGING" && find . -type f ! -name MANIFEST.sha256 -print0 \
      | sort -z | xargs -0 sha256sum > MANIFEST.sha256 ) \
    || die "$(ui_msg field_manifest_failed)"
  chmod 0600 "$FIELD_STAGING/MANIFEST.sha256"
  # Build under a temporary name and rename into place. Cleanup only ever knows
  # about the temporary name, so a signal can never delete a completed archive:
  # after the rename the tracked path no longer exists and removing it is a
  # harmless no-op, which leaves no window where a finished report is discarded.
  local building="$LOG_BUNDLE_DIR/.$(basename "$bundle").partial"
  FIELD_BUNDLE_PARTIAL="$building"
  tar -czf "$building" -C "$FIELD_STAGING" . || die "$(ui_msg field_archive_failed)"
  chmod 0600 "$building" || die "$(ui_msg field_archive_failed)"
  mv -f "$building" "$bundle" || die "$(ui_msg field_archive_failed)"
  FIELD_BUNDLE_PARTIAL=""

  field_report_cleanup
  trap - EXIT INT TERM

  local digest
  digest="$(sha256sum "$bundle" | awk '{print $1}')"
  echo
  ok "$(ui_msg field_ready)"
  printf '%s\n\n' "$bundle"
  printf 'SHA-256:\n%s\n\n' "$digest"
  printf '%s\n' "$(ui_msg field_upload_hint)"
  printf '%s\n  scp root@SERVER:%s .\n' "$(ui_msg field_scp_hint)" "$bundle"
  if [[ "$raw_included" == yes ]]; then warn "$(ui_msg field_pcap_warning)"; fi
  return 0
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

logs_pack_cleanup() {
  if [[ -n "${LOGS_STAGING:-}" && -d "${LOGS_STAGING:-}" ]]; then
    rm -rf --one-file-system -- "$LOGS_STAGING" 2>/dev/null || true
  fi
  LOGS_STAGING=""
  # An archive interrupted mid-write must not be left looking like a report.
  if [[ -n "${LOGS_PARTIAL:-}" && -f "${LOGS_PARTIAL:-}" ]]; then rm -f -- "$LOGS_PARTIAL" 2>/dev/null || true; fi
  LOGS_PARTIAL=""
  return 0
}

logs_pack_on_signal() {
  trap - EXIT INT TERM
  logs_pack_cleanup
  warn "Сбор пакета логов прерван; временные файлы удалены."
  exit "$1"
}

logs_pack_cmd() {
  need_root; banner
  local mode="safe" filter=redact snap history ts bundle staging building upstream_commit="unknown"
  [[ "${1:-}" == "--full" ]] && { mode="full"; filter=""; }
  [[ -z "${1:-}" || "${1:-}" == "--full" ]] || die "Использование: twebproxy logs-pack [--full]"
  snap="$(collect_runtime_snapshot "$mode" current)"
  history="$(collect_history_snapshot "$mode" history)"
  log "Current runtime snapshot: $snap"
  log "Bounded history snapshot: $history"
  install -d -o root -g root -m 0700 "$LOG_BUNDLE_DIR" || die "Не удалось записать пакет логов в $LOG_BUNDLE_DIR."
  ts="$(date '+%Y%m%d-%H%M%S')"
  if [[ "$mode" == "full" ]]; then
    bundle="$LOG_BUNDLE_DIR/twebproxy-FULL-report-${ts}.tar.gz"
  else
    bundle="$LOG_BUNDLE_DIR/twebproxy-logs-${ts}.tar.gz"
  fi

  # Staging and a half-written archive are removed on any exit or signal.
  LOGS_STAGING="$(mktemp -d /tmp/twebproxy-bundle.XXXXXX)" || die "Не удалось записать пакет логов в $LOG_BUNDLE_DIR."
  staging="$LOGS_STAGING"
  trap 'logs_pack_cleanup' EXIT
  trap 'logs_pack_on_signal 130' INT
  trap 'logs_pack_on_signal 143' TERM
  install -d -m 0700 \
    "$staging/current" \
    "$staging/history" \
    "$staging/history/manager" \
    "$staging/history/runtime"

  # A safe bundle re-applies the current redaction to everything it carries,
  # including logs written by older versions.
  logs_copy_file "$snap" "$staging/current/runtime.log" "$filter" ||
    printf 'skipped runtime.log: removed or unreadable\n' >> "$staging/current/SKIPPED.txt"
  logs_copy_file "$history" "$staging/history/service-history.log" "$filter" ||
    printf 'skipped service-history.log: removed or unreadable\n' >> "$staging/history/SKIPPED.txt"
  if [[ -n "${CURRENT_LOG:-}" && -f "$CURRENT_LOG" ]]; then
    logs_copy_file "$CURRENT_LOG" "$staging/current/manager.log" "$filter" ||
      printf 'skipped manager.log: removed or unreadable\n' >> "$staging/current/SKIPPED.txt"
  fi

  # Keep reports compact and useful: persistent /opt logs retain everything, while
  # the shareable bundle carries recent context plus an activation-bounded current state.
  copy_recent_files "$LOG_MANAGER_DIR" "$staging/history/manager" '*.log' 12 "${CURRENT_LOG:-}" "" "$filter"
  copy_recent_files "$LOG_RUNTIME_DIR" "$staging/history/runtime" '*.log' 6 "$snap" "$history" "$filter"
  if [[ "$mode" == "full" ]]; then
    install -d -m 0700 "$staging/history/full"
    copy_recent_files "$LOG_FULL_DIR" "$staging/history/full" '*.log' 4 "$snap" "$history"
  fi

  write_security_notice "$staging/SECURITY-NOTICE.txt" "$mode"
  if [[ -f "$GLOBAL_ENV" ]]; then
    upstream_commit="$( (unset TPROXY_UPSTREAM_COMMIT; source "$GLOBAL_ENV"; printf '%s' "${TPROXY_UPSTREAM_COMMIT:-unknown}") )"
  fi
  {
    echo "manager_version=$MANAGER_RELEASE_VERSION"
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
  building="$LOG_BUNDLE_DIR/.${bundle##*/}.partial"
  LOGS_PARTIAL="$building"
  tar -czf "$building" -C "$staging" . && chmod 0600 "$building" && mv -f "$building" "$bundle" ||
    die "Не удалось записать пакет логов в $LOG_BUNDLE_DIR."
  LOGS_PARTIAL=""
  logs_pack_cleanup
  trap - EXIT INT TERM
  ok "Пакет логов готов: $bundle"
  if [[ "$mode" == "full" ]]; then
    warn "FULL TEST REPORT содержит WEB/MTProxy secrets. Приватные TLS/SSH ключи и root/sudo credentials не включаются."
  else
    [[ "$UI_LANGUAGE" == en ]] && echo "The safe bundle contains current state plus bounded redacted history. WEB/MTProxy secrets become [REDACTED]." \
      || echo "Безопасный пакет содержит текущее состояние и ограниченную обезличенную историю. WEB/MTProxy secrets заменяются на [REDACTED]."
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
  printf '%s:\n' "$(ui_msg logs_recent_manager)"
  find "$LOG_MANAGER_DIR" -maxdepth 1 -type f -name '*.log' -printf '%TY-%Tm-%Td %TH:%TM:%TS  %9s B  %f\n' 2>/dev/null | sort -r | head -n 30 || true
  echo
  printf '%s:\n' "$(ui_msg logs_runtime_snapshots)"
  find "$LOG_RUNTIME_DIR" -maxdepth 1 -type f -name '*.log' -printf '%TY-%Tm-%Td %TH:%TM:%TS  %9s B  %f\n' 2>/dev/null | sort -r | head -n 20 || true
  echo
  printf '%s:\n' "$(ui_msg logs_full_snapshots)"
  find "$LOG_FULL_DIR" -maxdepth 1 -type f -name '*.log' -printf '%TY-%Tm-%Td %TH:%TM:%TS  %9s B  %f\n' 2>/dev/null | sort -r | head -n 20 || true
  echo
  printf '%s:\n' "$(ui_msg logs_bundles)"
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

# Stage 2 presentation layer. These functions consume the typed records above;
# they do not probe systemd, network, firewall or configuration on their own.
tui_terminal_width() {
  local width="${COLUMNS:-}"
  if [[ ! "$width" =~ ^[0-9]+$ ]]; then width="$(tput cols 2>/dev/null || true)"; fi
  [[ "$width" =~ ^[0-9]+$ ]] || width=80
  (( width < 28 )) && width=28
  (( width > 120 )) && width=120
  printf '%s' "$width"
}

tui_rule() {
  local width rule; width="$(tui_terminal_width)"
  printf -v rule '%*s' "$width" ''
  printf '%s\n' "${rule// /-}"
}

tui_title() {
  local title="$1"
  printf '%b%s%b\n' "$C_BOLD" "$title" "$C_RESET"
  tui_rule
}

tui_section() { printf '\n%b%s%b\n' "$C_CYAN" "$1" "$C_RESET"; }

tui_text() {
  local width; width="$(tui_terminal_width)"
  printf '%s\n' "$*" | fold -s -w "$width"
}

tui_kv() {
  local key="$1" value="$2" width; width="$(tui_terminal_width)"
  if (( width < 52 )); then
    printf '%b%s%b\n' "$C_DIM" "$key" "$C_RESET"
    printf '  %s\n' "$value" | fold -s -w "$width"
  else
    printf '%-22s %s\n' "$key" "$value" | fold -s -w "$width"
  fi
}

tui_state_text() {
  case "$1" in
    OK) printf '%b[%s]%b' "$C_GREEN" "$(ui_msg status_ok)" "$C_RESET";;
    WARNING) printf '%b[%s]%b' "$C_YELLOW" "$(ui_msg status_warning)" "$C_RESET";;
    ERROR) printf '%b[%s]%b' "$C_RED" "$(ui_msg status_error)" "$C_RESET";;
    DISABLED) printf '%b[%s]%b' "$C_DIM" "$(ui_msg status_disabled)" "$C_RESET";;
    UNKNOWN) printf '%b[%s]%b' "$C_YELLOW" "$(ui_msg status_unknown)" "$C_RESET";;
    *) printf '%b[%s]%b' "$C_YELLOW" "$(ui_msg status_unknown)" "$C_RESET";;
  esac
}

tui_human_bytes() {
  local bytes="$1"
  [[ "$bytes" =~ ^[0-9]+$ ]] || { ui_msg unavailable; return; }
  awk -v n="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB", u, " "); i=1;
    while (n >= 1024 && i < 5) { n/=1024; i++ }
    if (i == 1) printf "%d %s", n, u[i]; else printf "%.1f %s", n, u[i]
  }'
}

tui_human_duration() {
  local seconds="$1" days hours minutes
  [[ "$seconds" =~ ^[0-9]+$ ]] || { ui_msg unavailable; return; }
  days=$((seconds/86400)); hours=$(((seconds%86400)/3600)); minutes=$(((seconds%3600)/60))
  if (( days > 0 )); then printf '%sd %sh' "$days" "$hours"
  elif (( hours > 0 )); then printf '%sh %sm' "$hours" "$minutes"
  elif (( minutes > 0 )); then printf '%sm %ss' "$minutes" "$((seconds%60))"
  else printf '%ss' "$seconds"
  fi
}

# Presentation-only extraction from evidence already collected by
# collect_statistics_state(). Only exact, documented scalar names are accepted;
# labels, expressions and unknown counters are intentionally ignored.
tui_live_scalar() {
  local evidence="$1" key="$2" line value="" found=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^${key}[[:space:]]+([0-9]+)(\.0+)?$ ]]; then
      ((found+=1))
      value="${BASH_REMATCH[1]}"
    fi
  done <<< "$evidence"
  (( found == 1 )) || return 1
  printf '%s' "$value"
}

tui_record_index() {
  local id="$1" scope="${2:-}" i
  for i in "${!TCORE_IDS[@]}"; do
    [[ "${TCORE_IDS[$i]}" == "$id" ]] || continue
    [[ -z "$scope" || "${TCORE_SCOPES[$i]}" == "$scope" ]] || continue
    printf '%s' "$i"; return 0
  done
  return 1
}

tui_render_record() {
  local i="$1" status text
  status="${TCORE_STATUSES[$i]:-UNKNOWN}"
  text="$(tui_state_text "$status") ${TCORE_MESSAGES[$i]:-No details}"
  [[ -n "${TCORE_OBSERVED[$i]:-}" ]] && text+=" — ${TCORE_OBSERVED[$i]}"
  tui_text "$text"
}

tui_render_matching_records() {
  local pattern="$1" i matched=0
  for i in "${!TCORE_IDS[@]}"; do
    [[ "${TCORE_IDS[$i]}" =~ $pattern ]] || continue
    matched=1
    tui_text "$(tui_state_text "${TCORE_STATUSES[$i]}") ${TCORE_SCOPES[$i]} · ${TCORE_MESSAGES[$i]} — ${TCORE_OBSERVED[$i]}"
  done
  (( matched )) || tui_text "$(tui_state_text UNKNOWN) Нет доступных typed records."
}

tui_status_counts() {
  local status ok_count=0 warning_count=0 error_count=0 disabled_count=0 unknown_count=0
  for status in "${TCORE_STATUSES[@]}"; do
    case "$status" in
      OK) ok_count=$((ok_count+1));;
      WARNING) warning_count=$((warning_count+1));;
      ERROR) error_count=$((error_count+1));;
      DISABLED) disabled_count=$((disabled_count+1));;
      *) unknown_count=$((unknown_count+1));;
    esac
  done
  ui_msgf counts "$ok_count" "$warning_count" "$error_count" "$disabled_count" "$unknown_count"
}

tui_render_dashboard() {
  local host scope i host_count profile_count state tls profiles relay frontend backend dpi
  local -A seen_hosts=()
  local -a typed_hosts=()
  host_count="$(jq -r '.hostnames // 0' <<<"$TCORE_DATA_JSON" 2>/dev/null || printf 0)"
  profile_count="$(jq -r '.profiles // 0' <<<"$TCORE_DATA_JSON" 2>/dev/null || printf 0)"
  tui_title "$(ui_msgf dashboard_title "$MANAGER_RELEASE_VERSION")"
  tui_text "$(ui_msg product_subtitle)"
  tui_kv "$(ui_msg language)" "$([[ "$UI_LANGUAGE" == en ]] && ui_msg english || ui_msg russian)"
  tui_kv "$(ui_msg system)" "$(tui_state_text "$TCORE_OVERALL")"
  tui_kv "$(ui_msg hostnames) / $(ui_msg profiles_count)" "$host_count / $profile_count"

  for scope in "${TCORE_SCOPES[@]}"; do
    case "$scope" in
      hostname:*) host="${scope#hostname:}";;
      profile:*) host="${scope#profile:}"; host="${host%%/*}";;
      *) continue;;
    esac
    [[ -n "$host" && -z "${seen_hosts[$host]:-}" ]] || continue
    seen_hosts["$host"]=1; typed_hosts+=("$host")
  done
  ((${#typed_hosts[@]} > 0)) || { tui_section "$(ui_msg instances_section)"; tui_text "$(ui_msg no_instances)"; return; }
  tui_section "$(ui_msg instances_section)"
  for host in "${typed_hosts[@]}"; do
    scope="hostname:$host"; state=OK; tls="$(ui_msg unavailable)"; profiles=0
    relay=UNKNOWN; frontend=UNKNOWN; backend=OK; dpi=STOCK
    for i in "${!TCORE_IDS[@]}"; do
      case "${TCORE_IDS[$i]}:${TCORE_SCOPES[$i]}" in
        relay.service.active:"$scope") relay="${TCORE_STATUSES[$i]}";;
        frontend.service.active:"$scope") frontend="${TCORE_STATUSES[$i]}";;
        tls.mode:"$scope") tls="${TCORE_OBSERVED[$i]}";;
        anti_dpi.mode:"$scope") dpi="${TCORE_OBSERVED[$i]%%@*}";;
        profiles.present:"$scope") profiles="${TCORE_OBSERVED[$i]}";;
        profile.backend.service.active:profile:"$host"/*)
          [[ "${TCORE_STATUSES[$i]}" == OK ]] || backend="${TCORE_STATUSES[$i]}";;
      esac
    done
    # The host's worst observed state across all of its checks (DISABLED aside).
    state=OK
    for i in "${!TCORE_IDS[@]}"; do
      case "${TCORE_SCOPES[$i]}" in "$scope"|"profile:$host"/*) ;; *) continue;; esac
      case "${TCORE_STATUSES[$i]}" in
        ERROR) state=ERROR;;
        WARNING) [[ "$state" == ERROR ]] || state=WARNING;;
        UNKNOWN) [[ "$state" == ERROR || "$state" == WARNING ]] || state=UNKNOWN;;
      esac
    done
    printf '%b%-30s%b %s\n' "$C_BOLD" "$host" "$C_RESET" "$(tui_state_text "$state")"
    tui_text "  $(ui_msg profiles_count): $profiles  TLS: $tls  $(ui_msg dpi_mode): $dpi"
  done
}

# The operator's next step for a status check (human output only; --json and
# --raw keep their schema).
tui_check_hint() { # $1=check id $2=hostname
  local h="$2"
  case "$1" in
    relay.*|*.listener.loopback) ui_msgf hint_relay "$h" "$h";;
    frontend.*) ui_msgf hint_frontend "$h";;
    tls.*|https.*) ui_msgf hint_tls "$h";;
    profiles.present|inventory.profiles) ui_msgf hint_no_profile "$h";;
    firewall.*|profile.*.firewall.*) ui_msgf hint_firewall "$h" "$h";;
    profile.*) ui_msgf hint_profile "$h";;
    *) ui_msgf hint_generic "$h" "$h";;
  esac
}

tui_render_status() {
  local host="$1" i problems=0 dpi=STOCK hint shown=$'\n'
  tui_title "$(ui_msg status_title) · $host"
  tui_kv "$(ui_msg overall)" "$(tui_state_text "$TCORE_OVERALL")"
  tui_kv "$(ui_msg checks)" "$(tui_status_counts)"
  for i in "${!TCORE_IDS[@]}"; do
    [[ "${TCORE_IDS[$i]}" == anti_dpi.mode ]] && dpi="${TCORE_OBSERVED[$i]}"
  done
  tui_kv "$(ui_msg dpi_mode)" "$dpi"
  for i in "${!TCORE_IDS[@]}"; do
    case "${TCORE_STATUSES[$i]}" in ERROR|WARNING|UNKNOWN)
      (( problems == 0 )) && tui_section "$(ui_msg attention)"
      problems=$((problems+1))
      tui_text "$(tui_state_text "${TCORE_STATUSES[$i]}") ${TCORE_IDS[$i]} — ${TCORE_OBSERVED[$i]}"
      # One next step per kind of problem, not one per check.
      hint="$(tui_check_hint "${TCORE_IDS[$i]}" "$host")"
      if [[ "$shown" != *$'\n'"$hint"$'\n'* ]]; then
        printf '  -> %s\n' "$hint"; shown+="$hint"$'\n'
      fi;; esac
  done
  (( problems > 0 )) || tui_text "$(tui_state_text OK) $(ui_msg healthy)"
  printf '\n'; tui_text "$(ui_msg raw_diagnostics_hint)"
}

tui_render_profiles() {
  local host="$1" scope p i status carrier backend_port stats_port secret_state
  local -A seen_profiles=()
  local -a typed_profiles=()
  tui_title "Profiles · $host"
  if [[ "${TCORE_IDS[0]:-}" == profiles.present && "${TCORE_STATUSES[0]:-}" == ERROR ]]; then
    tui_text "$(tui_state_text ERROR) ${TCORE_MESSAGES[0]}"
    return
  fi
  for scope in "${TCORE_SCOPES[@]}"; do
    [[ "$scope" == "profile:$host/"* ]] || continue
    p="${scope#profile:$host/}"
    [[ -n "$p" && -z "${seen_profiles[$p]:-}" ]] || continue
    seen_profiles["$p"]=1; typed_profiles+=("$p")
  done
  for p in "${typed_profiles[@]}"; do
    scope="profile:$host/$p"; status=UNKNOWN; carrier=unavailable
    backend_port=unavailable; stats_port=unavailable; secret_state=UNKNOWN
    for i in "${!TCORE_IDS[@]}"; do
      [[ "${TCORE_SCOPES[$i]}" == "$scope" ]] || continue
      case "${TCORE_IDS[$i]}" in
        profile.backend.service.active) status="${TCORE_STATUSES[$i]}";;
        profile.carrier) carrier="${TCORE_OBSERVED[$i]}";;
        profile.backend.port) backend_port="${TCORE_OBSERVED[$i]}";;
        profile.stats.port) stats_port="${TCORE_OBSERVED[$i]}";;
        profile.secret.configured) secret_state="${TCORE_STATUSES[$i]}";;
      esac
    done
    tui_section "$p"
    tui_kv "$(ui_msg backend)" "$(tui_state_text "$status")"
    tui_kv "$(ui_msg carrier)" "$carrier"
    tui_kv "$(ui_msg ports)" "backend $backend_port / stats $stats_port"
    tui_kv "$(ui_msg secret)" "$(tui_state_text "$secret_state") $(ui_msg hidden)"
  done
}

tui_render_statistics() {
  local host="$1" i profile_total=0 profile_ok=0 relay_state=UNKNOWN
  local relay_evidence="" sessions="" streams="" relay_bytes=""
  local connections="" profile_connections=0 connections_seen=0 value=""
  tui_title "$(ui_msg statistics_title) · $host"
  tui_text "$(ui_msg stats_scope_note)"
  for i in "${!TCORE_IDS[@]}"; do
    case "${TCORE_IDS[$i]}" in
      statistics.relay.live)
        relay_state="${TCORE_STATUSES[$i]}"
        [[ "${TCORE_STATUSES[$i]}" == OK ]] && relay_evidence="${TCORE_EVIDENCE[$i]}"
        ;;
      statistics.profile.live)
        profile_total=$((profile_total+1))
        if [[ "${TCORE_STATUSES[$i]}" == OK ]]; then
          profile_ok=$((profile_ok+1))
          if value="$(tui_live_scalar "${TCORE_EVIDENCE[$i]}" connections 2>/dev/null)"; then
            profile_connections=$((profile_connections + value)); connections_seen=$((connections_seen+1))
          elif value="$(tui_live_scalar "${TCORE_EVIDENCE[$i]}" active_connections 2>/dev/null)"; then
            profile_connections=$((profile_connections + value)); connections_seen=$((connections_seen+1))
          fi
        fi
        ;;
    esac
  done
  sessions="$(tui_live_scalar "$relay_evidence" twebproxy_sessions 2>/dev/null || true)"
  streams="$(tui_live_scalar "$relay_evidence" twebproxy_streams 2>/dev/null || true)"
  relay_bytes="$(tui_live_scalar "$relay_evidence" twebproxy_bytes_total 2>/dev/null || true)"
  if (( profile_total > 0 && profile_ok == profile_total && connections_seen == profile_total )); then
    connections="$profile_connections"
  fi

  tui_section "$(ui_msg live_values)"
  tui_kv "$(ui_msg relay_sessions)" "${sessions:-$(ui_msg metric_unavailable)}"
  tui_kv "$(ui_msg relay_streams)" "${streams:-$(ui_msg metric_unavailable)}"
  if [[ -n "$relay_bytes" ]]; then
    tui_kv "$(ui_msg relay_bytes_total)" "$(tui_human_bytes "$relay_bytes") ($relay_bytes B)"
  else
    tui_kv "$(ui_msg relay_bytes_total)" "$(ui_msg metric_unavailable)"
  fi
  tui_kv "$(ui_msg backend_connections)" "${connections:-$(ui_msg metric_unavailable)}"

  tui_section "$(ui_msg live_sources)"
  tui_kv "$(ui_msg source_relay)" "$(tui_state_text "$relay_state")"
  tui_kv "$(ui_msg source_profiles)" "$(ui_msgf profile_sources_value "$profile_ok" "$profile_total")"
  tui_section "$(ui_msg unavailable_design)"
  tui_kv "$(ui_msg history)" "$(ui_msg unavailable)"
  printf '\n'; tui_text "$(ui_msg raw_diagnostics_hint)"
}

tui_render_tls() {
  local host="$1" i
  tui_title "TLS · $host"
  for i in "${!TCORE_IDS[@]}"; do
    [[ "${TCORE_IDS[$i]}" =~ ^(frontend|tls|certificate|https) ]] || continue
    tui_text "$(tui_state_text "${TCORE_STATUSES[$i]}") ${TCORE_IDS[$i]} — ${TCORE_OBSERVED[$i]}"
  done
  tui_text "$(ui_msg tls_actions_note)"
}

tui_render_anti_dpi() {
  local i
  tui_title "$(ui_msg dpi_title)"
  for i in "${!TCORE_IDS[@]}"; do
    [[ "${TCORE_IDS[$i]}" == anti_dpi.mode ]] && tui_render_record "$i"
  done
  tui_text "$(ui_msg dpi_stock_note)"
  tui_kv "nfqws" "$(ui_msgf dpi_nfqws_provenance "$DPI_NFQWS_VERSION" "$DPI_NFQWS_COMMIT")"
}

tui_render_update_recovery() {
  tui_title "$(ui_msg update_recovery)"
  tui_kv "$(ui_msg manager)" "v$MANAGER_RELEASE_VERSION"
  tui_kv "$(ui_msg manager_update)" "$(ui_msg verified_update_workflow)"
  tui_kv "$(ui_msg local_backups)" "$(stage4_backup_tui_summary)"
  if stage4_install_restore_helper no >/dev/null 2>&1; then
    tui_kv "$(ui_msg offline_helper)" "$(ui_msg helper_available)"
  else
    tui_kv "$(ui_msg offline_helper)" "$(ui_msg helper_unavailable)"
  fi
}

tui_render_settings() {
  tui_title "$(ui_msg settings)"
  tui_kv "$(ui_msg language)" "$([[ "$UI_LANGUAGE" == en ]] && ui_msg english || ui_msg russian)"
  tui_kv "$(ui_msg terminal_width)" "$(tui_terminal_width)"
  if [[ -n "$C_RESET" ]]; then tui_kv "$(ui_msg color)" "$(ui_msg enabled_session)"
  else tui_kv "$(ui_msg color)" "$(ui_msg disabled_session)"; fi
  tui_kv "$(ui_msg machine_output)" "$(ui_msg machine_output_value)"
  tui_text "$(ui_msg settings_note)"
}

# A fresh Bash process keeps errexit/ERR semantics inside service-changing
# functions. Putting a whole Bash mutator in `if fn` would disable errexit in it.
tui_run() {
  local rc no_color="${NO_COLOR:-}"
  [[ -n "$C_RESET" ]] || no_color=1
  if TWEBPROXY_UI_LANGUAGE="$UI_LANGUAGE" TWEBPROXY_NO_LOG=1 \
     NO_COLOR="$no_color" bash "${BASH_SOURCE[0]}" tui-internal "$@"; then return 0
  else rc=$?; fi
  if (( rc == 130 )); then warn "$(ui_msg smart_cancelled)" >&2
  else warn "$(ui_msgf smart_failure "$rc")" >&2; fi
  return 0
}

tui_internal_cmd() {
  need_root; TUI_ACTIVE=1
  [[ -z "${NO_COLOR:-}" ]] || disable_colors
  export TWEBPROXY_ERROR_SNAPSHOT=1 TWEBPROXY_NO_LOG=1
  trap 'exit $?' ERR
  local action="${1:-}" label target="${2:-Manager}"; shift || return 64
  case "$action" in
    quick-add|advanced-add)
      local TUI_SETUP_KIND=quick
      [[ "$action" != advanced-add ]] || TUI_SETUP_KIND=advanced
      add_instance_cmd; return;;
    restart|repair|core-install|update|manager-update|cert-renew|report)
      case "$action" in
        restart) label="$(ui_msg restart_instance)";; repair) label="$(ui_msg repair_instance)";;
        core-install) label="$(ui_msg smart_core_confirm)";; update) label="$(ui_msg relay_update)";;
        manager-update) label="$(ui_msg manager_install_update)";; cert-renew) label="$(ui_msg cert_renew)";;
        report) label="$(ui_msg smart_full_report)";;
      esac
      if [[ "$action" != cert-renew || "${2:-}" != --dry-run ]]; then
        tui_text "$label"
        [[ "$action" == report ]] || tui_text "$(ui_msgf smart_impact "$target")"
        yesno "$(ui_msg smart_apply)" n || { log "$(ui_msg smart_cancelled)"; return 0; }
      fi;;
    view-overview) collect_overview; tui_render_dashboard; return;;
    view-profiles) collect_profiles_state "$target"; tui_render_profiles "$target"; return;;
    view-tls) collect_audit "$target"; tui_render_tls "$target"; return;;
    view-status) collect_status "$target"; tui_render_status "$target"; return;;
    view-stats) collect_statistics_state "$target"; tui_render_statistics "$target"; return;;
    view-updates) tui_render_update_recovery; return;;
    dpi|show|manual-snippet|status|stats|audit|diagnose|cert-status|profile-list|profile-show|profile-add|profile-rotate|profile-carrier|profile-delete|delete|core-uninstall|check-update|manager-backup-list|manager-rollback|logs|logs-tail|logs-collect|logs-pack|field-report) ;;
    *) return 64;;
  esac
  main "$action" "$@"
}

menu_add_instance() {
  local choice
  choice="$(menu_choose "$(ui_msg add_instance)" "$(ui_msg back)" "$(ui_msg smart_quick)" "$(ui_msg smart_advanced)")"
  case "$choice" in 1) tui_run quick-add;; 2) tui_run advanced-add;; esac
}

menu_logs() {
  while true; do
    clear 2>/dev/null || true; tui_title "$(ui_msg logs_reports)"; tui_kv "Logs" "$LOG_DIR"; echo
    local c; c="$(menu_choose "$(ui_msg logs_reports):" "$(ui_msg back)" \
      "$(ui_msg list_logs)" "$(ui_msg tail_log)" "$(ui_msg runtime_snapshot)" \
      "$(ui_msg safe_bundle)" "$(ui_msg full_report)")"
    case "$c" in
      1) tui_run logs; pause;;
      2) tui_run logs-tail 200; pause;;
      3) tui_run logs-collect; pause;;
      4) tui_run logs-pack; pause;;
      5) tui_run report; pause;;
      0) return;;
    esac
  done
}

menu_profiles() {
  local host p; host="$(select_instance)" || return 0
  while true; do
    clear 2>/dev/null || true
    tui_run view-profiles "$host"; echo
    local c; c="$(menu_choose "$(ui_msg profiles):" "$(ui_msg back)" \
      "$(ui_msg add_profile)" "$(ui_msg show_profile)" "$(ui_msg rotate_profile)" \
      "$(ui_msg carrier_profile)" "$(ui_msg delete_profile)")"
    case "$c" in
      1) tui_run profile-add "$host"; pause;;
      2) p="$(select_profile "$host")" && { warn "$(ui_msg secret_warning)"; tui_run profile-show "$host" "$p"; }; pause;;
      3) p="$(select_profile "$host")" && tui_run profile-rotate "$host" "$p"; pause;;
      4) p="$(select_profile "$host")" && tui_run profile-carrier "$host" "$p"; pause;;
      5) p="$(select_profile "$host")" && tui_run profile-delete "$host" "$p"; pause;;
      0) return;;
    esac
  done
}

menu_certificates() {
  local host; host="$(select_instance)" || return 0
  while true; do
    clear 2>/dev/null || true
    tui_run view-tls "$host"
    echo
    local c; c="$(menu_choose "$(ui_msg tls_certificates):" "$(ui_msg back)" \
      "$(ui_msg cert_details)" "$(ui_msg cert_dry_run)" "$(ui_msg cert_renew)" "$(ui_msg cert_force)")"
    case "$c" in
      1) tui_run cert-status "$host"; pause;;
      2) tui_run cert-renew "$host" --dry-run; pause;;
      3) tui_run cert-renew "$host"; pause;;
      4) tui_run cert-renew "$host" --force; pause;;
      0) return;;
    esac
  done
}

menu_web_proxy() {
  local host
  while true; do
    clear 2>/dev/null || true
    tui_run view-overview; echo
    local c; c="$(menu_choose "$(ui_msg instances):" "$(ui_msg back)" \
      "$(ui_msg add_instance)" "$(ui_msg show_connection)" "$(ui_msg manual_snippet)" \
      "$(ui_msg restart_instance)" "$(ui_msg repair_instance)" "$(ui_msg delete_instance)" \
      "$(ui_msg uninstall_core)")"
    case "$c" in
      1) menu_add_instance; pause;;
      2) host="$(select_instance)" && tui_run show "$host"; pause;;
      3) host="$(select_instance)" && tui_run manual-snippet "$host"; pause;;
      4) host="$(select_instance)" && tui_run restart "$host"; pause;;
      5) host="$(select_instance)" && tui_run repair "$host"; pause;;
      6) host="$(select_instance)" && tui_run delete "$host"; pause;;
      7) tui_run core-uninstall; pause;;
      0) return;;
    esac
  done
}

menu_status_statistics() {
  local host; host="$(select_instance)" || return 0
  while true; do
    clear 2>/dev/null || true; tui_run view-status "$host"; echo
    local c; c="$(menu_choose "$(ui_msg status_stats):" "$(ui_msg back)" \
      "$(ui_msg compact_status)" "$(ui_msg compact_statistics)" \
      "$(ui_msg detailed_status)" "$(ui_msg raw_statistics)")"
    case "$c" in
      1) clear 2>/dev/null || true; tui_run view-status "$host"; pause;;
      2) clear 2>/dev/null || true; tui_run view-stats "$host"; pause;;
      3) tui_run status "$host" --verbose; pause;;
      4) tui_run stats "$host" --verbose; pause;;
      0) return;;
    esac
  done
}

menu_update_recovery() {
  while true; do
    clear 2>/dev/null || true; tui_run view-updates; echo
    local c; c="$(menu_choose "$(ui_msg update_recovery):" "$(ui_msg back)" \
      "$(ui_msg manager_check_update)" "$(ui_msg manager_install_update)" \
      "$(ui_msg backup_list)" "$(ui_msg rollback_latest)" "$(ui_msg relay_update)")"
    case "$c" in
      1) tui_run check-update; pause;;
      2) tui_run manager-update; pause;;
      3) tui_run manager-backup-list; pause;;
      4) tui_run manager-rollback latest; pause;;
      5) tui_run update; pause;;
      0) return;;
    esac
  done
}

menu_maintenance() {
  while true; do
    clear 2>/dev/null || true; tui_title "$(ui_msg maintenance)"; echo
    local c; c="$(menu_choose "$(ui_msg maintenance):" "$(ui_msg back)" \
      "$(ui_msg tls_certificates)" "$(ui_msg update_recovery)")"
    case "$c" in 1) menu_certificates;; 2) menu_update_recovery;; 0) return;; esac
  done
}

menu_diagnostics() {
  local host="" c
  while true; do
    clear 2>/dev/null || true; tui_title "$(ui_msg diagnostics_logs)"; echo
    c="$(menu_choose "$(ui_msg diagnostics_logs):" "$(ui_msg back)" \
      "$(ui_msg full_diagnose)" "$(ui_msg isolation_audit)" "$(ui_msg typed_json)" \
      "$(ui_msg typed_raw)" "$(ui_msg field_diagnostics)" "$(ui_msg logs_reports)" "$(ui_msg select_hostname)")"
    case "$c" in 1|2|3|4|5) [[ -n "$host" ]] || host="$(select_instance)" || continue;; esac
    case "$c" in
      1) tui_run diagnose "$host"; pause;;
      2) tui_run audit "$host"; pause;;
      3) tui_run audit "$host" --json; pause;;
      4) tui_run audit "$host" --raw; pause;;
      5) tui_run field-report "$host"; pause;;
      6) menu_logs;;
      7) host="$(select_instance)" || host="";;
      0) return;;
    esac
  done
}

# DPI-only reader: the shared legacy chooser does not distinguish EOF from an
# invalid choice in conditional contexts. Do not change other menus here.
dpi_tui_choose() {
  local prompt="$1" zero="$2" choice i; shift 2
  local options=("$@")
  printf '%s\n' "$prompt" >&2
  for i in "${!options[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${options[$i]}" >&2; done
  printf '  [0] %s\n' "$zero" >&2
  while true; do
    IFS= read -r -p '> ' choice || return 1
    [[ "$choice" =~ ^[0-9]$ ]] || { warn "$(ui_msg enter_number)" >&2; continue; }
    (( choice <= ${#options[@]} )) || { warn "$(ui_msg unknown_option)" >&2; continue; }
    printf '%s' "$choice"; return 0
  done
}

dpi_tui_confirm_scope() {
  local host="$1" ip shared reply
  ip="$(dpi_resolve_ipv4 "$host" 2>/dev/null)" || { warn "$(ui_msgf dpi_resolution_failed "$host")"; return 1; }
  [[ -n "$ip" ]] || { warn "$(ui_msgf dpi_resolution_failed "$host")"; return 1; }
  printf '%s\n' "$(ui_msgf dpi_tui_scope "$host" "$ip")"
  warn "$(ui_msgf dpi_scope_warning "$ip" "$host")"
  shared="$(dpi_hosts_for_ipv4 "$ip" | paste -sd, -)" || return 1
  [[ -z "$shared" ]] || printf '%s: %s\n' "$(ui_msg dpi_shared_hosts)" "$shared"
  printf '%s\n' "$(ui_msg dpi_dedicated_unknown)"
  printf '%s [y/N]: ' "$(ui_msg dpi_confirm_scope)" >&2
  IFS= read -r reply || return 1
  case "$reply" in y|Y|yes|YES|Yes|д|Д|да|Да|ДА) return 0;; *) return 1;; esac
}

dpi_tui_stock_confirm() {
  local host="$1" file
  tui_text "$(ui_msgf smart_stock_scope "$host")"
  # Show stored scopes as well: DNS may have moved since activation.
  for file in "$DPI_STATE_DIR"/*.env; do
    [[ -e "$file" || -L "$file" ]] || continue
    dpi_load_scope_file "$file" || { warn "$(ui_msg dpi_tui_failed)"; return 1; }
    [[ "$DPI_SCOPE_HOST" != "$host" ]] || printf '%s: %s (%s)\n' "$(ui_msg dpi_scope)" "$DPI_SCOPE_IPV4" "$DPI_SCOPE_MODE"
  done
  tui_text "$(ui_msg dpi_footer_scope)"
  yesno "$(ui_msg dpi_confirm_scope)" n
}

dpi_tui_apply() {
  local host="$1" method="$2"
  dpi_mode_valid "$method" || return 1
  if [[ "$method" == stock ]]; then
    if dpi_tui_stock_confirm "$host"; then tui_run dpi disable "$host"
    else log "$(ui_msg dpi_tui_cancelled)"; fi
  elif dpi_tui_confirm_scope "$host"; then
    tui_run dpi set "$host" "$method" --accept-shared-scope
  else log "$(ui_msg dpi_tui_cancelled)"; fi
}

menu_dpi_guided() {
  local host selected method
  tui_text "$(ui_msg smart_dpi_limits)"
  selected="$(dpi_tui_choose "$(ui_msg smart_dpi_guided)" "$(ui_msg back)" \
    "$(ui_msg smart_dpi_keep)" "$(ui_msg smart_dpi_window)" "$(ui_msg smart_dpi_mss)" "$(ui_msg smart_dpi_nfqws)")" || return 0
  case "$selected" in 0|1) return 0;; 2) method=window1152;; 3) method=mss88;; 4) method=nfqws;; esac
  host="$(select_instance)" || return 0
  dpi_tui_apply "$host" "$method"
}

menu_dpi_advanced() {
  local host selected method
  dpi_list_methods_cmd
  selected="$(dpi_tui_choose "$(ui_msg smart_advanced)" "$(ui_msg back)" \
    "$(ui_msg dpi_choice_window)" "$(ui_msg dpi_choice_mss)" "$(ui_msg dpi_choice_nfqws)" \
    "$(ui_msg dpi_choice_window_nfqws)" "$(ui_msg dpi_choice_mss_nfqws)" "$(ui_msg smart_dpi_stock)")" || return 0
  case "$selected" in 0) return 0;; 1) method=window1152;; 2) method=mss88;; 3) method=nfqws;; 4) method=window1152_nfqws;; 5) method=mss88_nfqws;; 6) method=stock;; esac
  host="$(select_instance)" || return 0
  dpi_tui_apply "$host" "$method"
}

menu_network_compatibility() {
  local c host
  while true; do
    clear 2>/dev/null || true; tui_text "$(ui_msg dpi_intro)"; tui_run dpi status; echo
    c="$(dpi_tui_choose "$(ui_msg dpi_title):" "$(ui_msg back)" \
      "$(ui_msg dpi_status)" "$(ui_msg smart_dpi_guided)" "$(ui_msg smart_dpi_stock)" "$(ui_msg smart_advanced)")" || return 0
    case "$c" in
      1) host="$(select_instance)" && tui_run dpi status "$host"; pause;;
      2) menu_dpi_guided; pause;;
      3) host="$(select_instance)" && dpi_tui_apply "$host" stock; pause;;
      4) menu_dpi_advanced; pause;;
      0) return;;
    esac
  done
}

menu_settings() {
  while true; do
    clear 2>/dev/null || true; tui_render_settings; echo
    local c lang; c="$(menu_choose "$(ui_msg settings):" "$(ui_msg back)" \
      "$(ui_msg change_language)" "$(ui_msg enable_color)" "$(ui_msg disable_color)")"
    case "$c" in
      1) lang="$(choose "$(ui_msg change_language):" "$(ui_msg english)" "$(ui_msg russian)")" || continue
         [[ "$lang" == 1 ]] && ui_language_store en || ui_language_store ru
         ok "$(ui_msg language_saved)";;
      2) enable_colors;;
      3) disable_colors;;
      0) return;;
    esac
  done
}

# Connection details and client help for one hostname (secrets are shown).
menu_connect() {
  local host; host="$(select_instance)" || return 0
  clear 2>/dev/null || true
  warn "$(ui_msg secret_warning)"
  tui_run show "$host"
  pause
}

first_run_prerequisites() {
  tui_section "$(ui_msg prereq_title)"
  printf '  - %s\n' "$(ui_msg prereq_dns)" "$(ui_msg prereq_ports)" "$(ui_msg prereq_system)" "$(ui_msg prereq_defaults)"
  echo
}

menu() {
  need_root; need_systemd; ui_language_load; TUI_ACTIVE=1
  while true; do
    if core_installed; then
      clear 2>/dev/null || true
      tui_run view-overview; echo
      # Everyday tasks first; advanced network compatibility and settings last.
      local c; c="$(menu_choose "$(ui_msg main_menu):" "$(ui_msg exit)" \
        "$(ui_msg connect_telegram)" "$(ui_msg status_stats)" "$(ui_msg instances)" \
        "$(ui_msg profiles)" "$(ui_msg diagnostics_logs)" "$(ui_msg maintenance)" \
        "$(ui_msg network_compatibility_advanced)" "$(ui_msg settings)" "$(ui_msg foreign_nodes)")"
      case "$c" in
        1) menu_connect;;
        2) menu_status_statistics;;
        3) menu_web_proxy;;
        4) menu_profiles;;
        5) menu_diagnostics;;
        6) menu_maintenance;;
        7) menu_network_compatibility;;
        8) menu_settings;;
        9) menu_foreign_nodes;;
        0) exit 0;;
      esac
    else
      ui_language_ensure_interactive_install
      clear 2>/dev/null || true; banner; echo
      first_run_prerequisites
      local c; c="$(menu_choose "$(ui_msg first_action):" "$(ui_msg exit)" \
        "$(ui_msg first_quick_setup)" "$(ui_msg first_core_only)" "$(ui_msg foreign_nodes)" "$(ui_msg smart_advanced)")"
      case "$c" in 1) tui_run quick-add; pause;; 2) tui_run core-install; pause;; 3) menu_foreign_nodes;; 4) tui_run advanced-add; pause;; 0) exit 0;; esac
    fi
  done
}

usage() {
  if [[ "$UI_LANGUAGE" == en ]]; then
    cat <<EOF
TWebProxy Manager v$MANAGER_RELEASE_VERSION

Usage: twebproxy [--json|--raw] [--no-color] [command] [args]

Quick start: run "sudo twebproxy" and choose Quick setup, or "sudo twebproxy add".
Then "twebproxy show HOSTNAME" prints the Telegram links and connection help,
and "twebproxy status HOSTNAME" the state. Guide: docs/SETUP.md

Manager / Core:
  check-update                 check for a new Manager version
  manager-update [--force] [--sha256 HEX]
                               verified release, backup, health gate and exact rollback
  manager-backup-list          list verified local update backups
  manager-rollback [latest|id] restore both Manager copies from a local backup
  core-install                 install dependencies, relay and MTProxy
  update                       update tproxy-server with config-check and rollback
  core-uninstall               remove the core when no instances exist

Instances:
  overview                     read-only overview; supports --json/--raw
  add | list | show [hostname] | manual-snippet [hostname]
  restart [hostname] | repair [hostname] | delete [hostname]
  status [hostname] [--verbose]  compact status; verbose keeps detailed evidence
  stats [hostname] [--verbose]   compact trusted sources; verbose keeps raw live data
  cert-status [hostname]
  cert-renew [hostname] [--dry-run|--force]
  audit [hostname] | diagnose [hostname]
  proc-hardening [status|enable|disable]
                               hide other users' processes (protects MTProxy secrets)

Optional network compatibility (IPv4; STOCK remains default):
  dpi status [hostname] | dpi list-methods
  dpi set HOST MODE [--accept-shared-scope] | dpi disable HOST

Profiles:
  profile-list | profile-add | profile-show | profile-rotate
  profile-carrier | profile-delete

Logs:
  logs | logs-tail [lines] | logs-collect [--full]
  logs-pack [--full] | report
  field-report HOST [--instant] [--keep-pcap]
                               one-shot field diagnostics archive

Interactive:
  menu                         bilingual task-oriented interface

Output options may precede or follow the command. --json and --raw are mutually
exclusive, non-interactive and intentionally use stable, non-localized fields.
Telegram WEB Proxy always uses public HTTPS port 443.
EOF
  else
    cat <<EOF
TWebProxy Manager v$MANAGER_RELEASE_VERSION

Использование: twebproxy [--json|--raw] [--no-color] [команда] [аргументы]

Быстрый старт: запустите «sudo twebproxy» и выберите быструю настройку
или выполните «sudo twebproxy add». Затем «twebproxy show HOSTNAME» покажет
ссылки для Telegram и помощь по подключению, а «twebproxy status HOSTNAME» —
состояние. Руководство: docs/SETUP.md

TWebProxy Manager / основа:
  check-update                 проверить новую версию TWebProxy Manager
  manager-update [--force] [--sha256 HEX]
                               проверенный релиз, резервная копия, проверка и точный откат
  manager-backup-list          показать проверенные локальные резервные копии обновлений
  manager-rollback [latest|id] восстановить обе копии TWebProxy Manager из резервной копии
  core-install                 установить зависимости, relay и MTProxy
  update                       обновить tproxy-server с проверкой конфигурации и откатом
  core-uninstall               удалить основу, когда нет инстансов

Инстансы:
  overview                     сводка только для чтения; поддерживает --json/--raw
  add | list | show [hostname] | manual-snippet [hostname]
  restart [hostname] | repair [hostname] | delete [hostname]
  status [hostname] [--verbose]  краткий статус; --verbose показывает подробности
  stats [hostname] [--verbose]   краткая статистика; --verbose показывает raw данные
  cert-status [hostname]
  cert-renew [hostname] [--dry-run|--force]
  audit [hostname] | diagnose [hostname]
  proc-hardening [status|enable|disable]
                               скрыть процессы других пользователей (защита secrets MTProxy)

Дополнительная совместимость сети (IPv4; по умолчанию STOCK):
  dpi status [hostname] | dpi list-methods
  dpi set HOST MODE [--accept-shared-scope] | dpi disable HOST

Профили:
  profile-list | profile-add | profile-show | profile-rotate
  profile-carrier | profile-delete

Логи:
  logs | logs-tail [строки] | logs-collect [--full]
  logs-pack [--full] | report
  field-report HOST [--instant] [--keep-pcap]
                               полевой диагностический архив одной командой

Интерактивный режим:
  connection-link HOST [PROFILE]  показать одну приватную WEB-ссылку (только в терминале)
  foreign-node add|status|diagnose|repair|remove
                               автоматическое управление одним зарубежным узлом
  menu                         двуязычный интерфейс по задачам

Флаги вывода можно указывать до или после команды. --json и --raw взаимно
исключаются, не задают вопросов и используют стабильные нелокализованные поля.
Telegram WEB Proxy всегда использует публичный HTTPS-порт 443.
EOF
  fi
}

# Optional Bridge bundle: normal single-file/local installations do not import it.
BRIDGE_MANIFEST_SHA256="080fdbeedfbc65aa6a3b136a327dbd62ed7ab610c88ff8799eb160869d3bdc37"
BRIDGE_LAUNCHER_SHA256="22b591b3312a8d62c9c30f1872a128bd45645563820c1f37889c61431c6bc30a"
bridge_bundle_dir() {
  local adjacent="$(dirname "${BASH_SOURCE[0]}")/bridge" installed="$PROJECT_DIR/bridge-$BRIDGE_MANIFEST_SHA256"
  if [[ -f "$adjacent/launcher.py" ]]; then printf '%s' "$adjacent"; else printf '%s' "$installed"; fi
}
bridge_launcher() {
  local bundle; bundle="$(bridge_bundle_dir)"
  [[ -f "$bundle/launcher.py" && ! -L "$bundle/launcher.py" ]] || die "$(ui_msg bridge_bundle_missing)"
  [[ "$(sha256sum "$bundle/launcher.py" | awk '{print $1}')" == "$BRIDGE_LAUNCHER_SHA256" ]] || die "$(ui_msg bridge_launcher_mismatch)"
  TWEBPROXY_BRIDGE_LANG="$UI_LANGUAGE" TWEBPROXY_BRIDGE_INTERACTIVE="$TUI_ACTIVE" TWEBPROXY_MANAGER="${BASH_SOURCE[0]}" /usr/bin/python3 -I "$bundle/launcher.py" "$BRIDGE_MANIFEST_SHA256" "$@"
}
install_bridge_bundle() {
  local bundle; bundle="$(bridge_bundle_dir)"
  [[ -f "$bundle/launcher.py" ]] || return 0
  bridge_launcher --install "$PROJECT_DIR/bridge-$BRIDGE_MANIFEST_SHA256"
}
bridge_managed() {
  [[ -e "$(instance_dir "$1")/bridge.json" || -e "$(instance_dir "$1")/bridge.owner" ]]
}
bridge_backend_label() {
  if bridge_managed "$1"; then printf 'Bridge loopback forwarder'; else printf 'MTProxy backend'; fi
}
bridge_runtime_unit() {
  if bridge_managed "$1"; then bridge_forward_unit "$1" 2>/dev/null || printf 'twebproxy-bridge-state-unknown.service'
  else printf 'twebproxy-mtproxy@%s.service' "$(backend_id "$1" "$2")"; fi
}
bridge_forward_unit() {
  python3 -c 'import json,re,sys
s=json.load(open(sys.argv[1])); i=s["id"]
assert s["schema"]=="twebproxy.bridge.instance.v1" and re.fullmatch("[0-9a-f]{32}",i)
print("twb-"+i[:12]+"-forward.service")' "$(instance_dir "$1")/bridge.json"
}
bridge_reject_profile_change() {
  bridge_managed "$1" && die "$(ui_msg bridge_profile_attached)"; return 0
}
connection_link_cmd() {
  need_root
  local host="${1:-}" profile="${2:-default}"
  [[ -n "$host" ]] || die "$(ui_msg bridge_link_usage)"
  require_instance "$host"; require_profile "$host" "$profile"; load_profile "$host" "$profile"
  printf 'tg://webproxy?server=%s&secret=%s\n' "$host" "$SECRET"
}
foreign_node_cmd() { need_root; if (( $# == 0 )); then menu_foreign_nodes; else bridge_launcher "$@"; fi; }
bridge_internal_cmd() {
  need_root
  local action="${1:-}" host="${2:-}" profile="${3:-}" port="${4:-}" old unit i
  case "$action" in
    quick-setup) local TUI_SETUP_KIND=quick; TUI_ACTIVE=1; add_instance_cmd;;
    prepare-runtime)
      stage4_acquire_update_lock || die "$(ui_msg bridge_update_busy)"
      stage4_install_restore_helper refresh || die "$(ui_msg bridge_restore_guard_failed)"
      install_manager_copy
      stage4_release_update_lock
      return;;
    allocate)
      port_lock_acquire || die "$(ui_msg bridge_ports_busy)"
      next_free_port 24000 27999
      port_lock_release; return;;
    inspect)
      require_instance "$host"
      local list='[]' p entry
      while read -r p; do
        load_profile "$host" "$p"
        entry="$(jq -cn --arg n "$p" --argjson b "$BACKEND_PORT" '{name:$n,backend_port:$b}')"
        list="$(jq -c --argjson e "$entry" '.+[$e]' <<< "$list")"
      done < <(list_profiles_array "$host")
      jq -cn --argjson p "$list" '{profiles:$p}'; return;;
    credential)
      require_instance "$host"; load_profile "$host" "$profile"
      jq -cn --arg s "$SECRET" '{secret:$s}'; return;;
    show) show_instance_cmd "$host"; return;;
  esac
  require_instance "$host"
  instance_lock_acquire "$host" || die "$(ui_msg bridge_instance_busy)"
  case "$action" in
    activate)
      is_valid_port "$port" || die "$(ui_msg bridge_invalid_forward)"
      load_profile "$host" "$profile"
      old="$BACKEND_PORT"; BACKEND_PORT="$port"
      save_profile "$host" "$profile" && rebuild_profiles_json "$host" && validate_instance "$host" || die "$(ui_msg bridge_commit_failed)"
      restart_relay_wait_ready "$host"
      stop_backend_unit "$(backend_id "$host" "$profile")" || die "$(ui_msg bridge_backend_stop_failed)"
      ;;
    detach)
      is_valid_port "$port" || die "$(ui_msg bridge_invalid_prior_port)"
      load_profile "$host" "$profile"
      if [[ "$BACKEND_PORT" == "$port" && ! -e "$(instance_dir "$host")/bridge.json" ]]; then
        rm -f "$(instance_dir "$host")/bridge.owner"
        instance_lock_release; return
      fi
      unit="twebproxy-mtproxy@$(backend_id "$host" "$profile").service"
      proc_secret_safe || proc_fail_closed
      systemctl enable --now "$unit" >/dev/null
      for i in {1..15}; do systemctl is-active --quiet "$unit" && port_listening "$port" && break; sleep 1; done
      systemctl is-active --quiet "$unit" && port_listening "$port" || die "$(ui_msg bridge_local_not_ready)"
      BACKEND_PORT="$port"; save_profile "$host" "$profile"
      rebuild_profiles_json "$host" && validate_instance "$host" || die "$(ui_msg bridge_local_validation_failed)"
      restart_relay_wait_ready "$host"
      rm -f "$(instance_dir "$host")/bridge.json" "$(instance_dir "$host")/bridge.owner"
      instance_derive_state "$host"; rebuild_firewall
      ;;
    refresh) rebuild_profiles_json "$host" && validate_instance "$host"; restart_relay_wait_ready "$host";;
    *) die "$(ui_msg bridge_unknown_internal)";;
  esac
  instance_lock_release
}
foreign_node_menu_run() {
  # Only the interactive boundary consumes a failure. Keep stderr and the exact
  # status visible; CLI foreign-node continues to propagate it to the caller.
  # Isolate explicit die/exit in launcher preflight from the containing menu.
  local rc
  if [[ "${1:-}" == repair ]]; then
    tui_text "$(ui_msgf smart_impact "$(ui_msg foreign_nodes)")"
    yesno "$(ui_msg smart_apply)" n || { log "$(ui_msg smart_cancelled)"; return 0; }
  fi
  if ( foreign_node_cmd "$@" ); then
    return 0
  else
    rc=$?
    warn "$(ui_msgf foreign_operation_failed "$rc")" >&2
  fi
  return 0
}

bridge_menu_state() {
  local state="$BASE_DIR/bridge/node.json" marker
  if [[ ! -e "$state" && ! -L "$state" ]]; then
    for marker in "$INSTANCES_DIR"/*/bridge.owner "$INSTANCES_DIR"/*/bridge.json; do
      [[ ! -e "$marker" && ! -L "$marker" ]] || { printf pending; return 0; }
    done
    printf none; return 0
  fi
  python3 - "$state" <<'PY_MENU_STATE'
import json,pathlib,sys
try:
 p=pathlib.Path(sys.argv[1]);s=json.loads(p.read_text()) if not p.is_symlink() else {}
 print('active' if s.get('schema')==1 and s.get('phase')=='active' and not s.get('cleanup_debt') else 'pending')
except Exception:print('pending')
PY_MENU_STATE
}

menu_foreign_nodes() {
  local c state; TUI_ACTIVE=1
  while true; do
    state="$(bridge_menu_state)" || state=pending
    if [[ "$state" == none ]]; then
      c="$(menu_choose "$(ui_msg foreign_nodes)" "$(ui_msg back)" "$(ui_msg foreign_add)")"
      case "$c" in 1) foreign_node_menu_run add; pause;; 0) return;; esac
    else
      [[ "$state" != active ]] && tui_text "$(ui_msg smart_bridge_pending)" || tui_text "$(ui_msg smart_bridge_active)"
      c="$(menu_choose "$(ui_msg foreign_nodes)" "$(ui_msg back)" "$(ui_msg status)" "$(ui_msg diagnostics_logs)" "$(ui_msg repair)" "$(ui_msg delete)")"
      case "$c" in
        1) foreign_node_menu_run status; pause;; 2) foreign_node_menu_run diagnose; pause;;
        3) foreign_node_menu_run repair; pause;; 4) foreign_node_menu_run remove; pause;; 0) return;;
      esac
    fi
  done
}

main() {
  local cmd arg
  local -a positional=()
  OUTPUT_MODE="human"
  OUTPUT_NO_COLOR=0
  ui_language_load

  for arg in "$@"; do
    case "$arg" in
      --json)
        [[ "$OUTPUT_MODE" == human || "$OUTPUT_MODE" == json ]] || die "--json и --raw взаимоисключающие."
        OUTPUT_MODE="json"
        ;;
      --raw)
        [[ "$OUTPUT_MODE" == human || "$OUTPUT_MODE" == raw ]] || die "--json и --raw взаимоисключающие."
        OUTPUT_MODE="raw"
        ;;
      --no-color) OUTPUT_NO_COLOR=1;;
      *) positional+=("$arg");;
    esac
  done
  set -- "${positional[@]}"
  cmd="${1:-menu}"; shift || true

  if [[ "$OUTPUT_MODE" != human ]]; then
    case "$cmd" in overview|status|audit|stats|profile-list) ;; foreign-node) case "${1:-}" in status|diagnose) ;; *) die "$(ui_msg bridge_json_verbs)";; esac;; *) die "$cmd пока не поддерживает --$OUTPUT_MODE.";; esac
    # Machine-readable stdout must contain only the selected renderer payload.
    export TWEBPROXY_NO_LOG=1
    disable_colors
  elif (( OUTPUT_NO_COLOR )) || [[ -n "${NO_COLOR:-}" ]]; then
    disable_colors
  fi

  case "$cmd" in foreign-node|bridge-internal|connection-link) export TWEBPROXY_NO_LOG=1;; esac
  setup_logging "$cmd"
  case "$cmd" in
    check-update) manager_check_update_cmd ;;
    manager-update) manager_update_cmd "$@" ;;
    manager-backup-list) manager_backup_list_cmd ;;
    manager-rollback) rollback_rc=0; manager_restore_backup_cmd "${1:-latest}" || rollback_rc=$?; exit "$rollback_rc" ;;
    connection-link) connection_link_cmd "$@" ;;
    foreign-node) foreign_node_cmd "$@" ;;
    bridge-internal) bridge_internal_cmd "$@" ;;
    core-install) core_install_cmd ;;
    add) add_instance_cmd ;;
    overview) overview_cmd ;;
    list) list_cmd ;;
    show) show_instance_cmd "${1:-}" ;;
    manual-snippet) manual_snippet_cmd "${1:-}" ;;
    restart) restart_cmd "${1:-}" ;;
    repair) repair_instance_cmd "${1:-}" ;;
    status) status_cmd "${1:-}" "${2:-}" ;;
    cert-status) cert_status_cmd "${1:-}" ;;
    cert-renew) cert_renew_cmd "${1:-}" "${2:-}" ;;
    stats) stats_cmd "${1:-}" "${2:-}" ;;
    diagnose) diagnose_cmd "${1:-}" ;;
    audit) audit_cmd "${1:-}" ;;
    proc-hardening) proc_hardening_cmd "${1:-status}" ;;
    logs) logs_list_cmd ;;
    logs-tail) logs_tail_cmd "${1:-200}" ;;
    logs-collect) logs_collect_cmd "${1:-}" ;;
    logs-pack) logs_pack_cmd "${1:-}" ;;
    report) report_cmd ;;
    field-report) field_report_cmd "$@" ;;
    delete) delete_instance_cmd "${1:-}" ;;
    profile-list) profiles_list_cmd "${1:-}" ;;
    profile-add) profile_add_cmd "${1:-}" ;;
    profile-show) show_profile_cmd "${1:-}" "${2:-}" ;;
    profile-rotate) profile_rotate_cmd "${1:-}" "${2:-}" ;;
    profile-carrier) profile_carrier_cmd "${1:-}" "${2:-}" ;;
    profile-delete) profile_delete_cmd "${1:-}" "${2:-}" ;;
    dpi) dpi_cmd "$@" ;;
    update) update_cmd ;;
    core-uninstall) core_uninstall_cmd ;;
    menu) menu ;;
    -h|--help|help) usage ;;
    *) usage; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1:-}" == tui-internal ]]; then
    shift; ui_language_load; tui_internal_cmd "$@"
  else
    main "$@"
  fi
fi
