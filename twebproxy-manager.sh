#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# TWebProxy Manager v0.2.8-dpi-beta
# Multi-instance / multi-secret manager for telegramdesktop/tproxy-server.
# Target: Debian 12+ / Ubuntu 22.04+, x86_64, systemd.

APP="twebproxy"
MANAGER_VERSION="0.2.8"
MANAGER_RELEASE_VERSION="0.2.8-dpi-beta"
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
LANGUAGE_FILE="${TWEBPROXY_LANGUAGE_FILE:-$BASE_DIR/ui-language}"

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
UPDATE_BACKUP_RETENTION=4
CURRENT_LOG=""
MANAGER_UPDATE_HINT_ATTEMPTED=0
OUTPUT_MODE="human"
OUTPUT_NO_COLOR=0
UI_LANGUAGE="ru"

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
    'Текущие manager-копии не образуют точное безопасное состояние; обновление остановлено до создания backup.') printf 'The current Manager copies do not form an exact safe state; the update stopped before backup creation.'; return;;
    'Не удалось проверить обновление manager на '*) printf 'Failed to check for a Manager update at %s' "${text#Не удалось проверить обновление manager на }"; return;;
    'Не удалось получить информацию об обновлении с '*) printf 'Failed to obtain update information from %s' "${text#Не удалось получить информацию об обновлении с }"; return;;
    'Доступна новая версия TWebProxy Manager:'*) printf 'A new TWebProxy Manager version is available:%s' "${text#*:}"; return;;
    Локальная\ версия\ *\ новее\ опубликованной\ *) value="${text#Локальная версия }"; printf 'Local version %s is newer than published version %s' "${value%% новее опубликованной *}" "${value#* новее опубликованной }"; return;;
    TWebProxy\ Manager\ *\ —\ актуальная\ версия.) value="${text#TWebProxy Manager }"; printf 'TWebProxy Manager %s is up to date.' "${value% — актуальная версия.}"; return;;
    TWebProxy\ Manager\ *\ уже\ актуален.) value="${text#TWebProxy Manager }"; printf 'TWebProxy Manager %s is already up to date.' "${value% уже актуален.}"; return;;
    Опубликованная\ версия\ *) value="${text#Опубликованная версия }"; value2="${value#* не новее локальной }"; printf 'Published version %s is not newer than local version %s. To force installation, run: manager-update --force' "${value%% не новее локальной *}" "${value2%%. Для принудительной*}"; return;;
    'Скачиваю TWebProxy Manager '*) printf 'Downloading %s' "${text#Скачиваю }"; return;;
    В\ *\ нет\ SHA256SUMS.*) value="${text#В }"; printf '%s does not contain SHA256SUMS. Automatic Manager update stopped because the release must publish a checksum.' "${value%% нет SHA256SUMS.*}"; return;;
    'SHA256SUMS не содержит корректный hash для twebproxy-manager.sh') printf 'SHA256SUMS does not contain a valid hash for twebproxy-manager.sh.'; return;;
    'SHA-256 manager candidate не совпал с SHA256SUMS') printf 'The Manager candidate SHA-256 does not match SHA256SUMS.'; return;;
    'Скачанный manager не проходит bash -n') printf 'The downloaded Manager fails bash -n.'; return;;
    'Не удалось создать и проверить локальный pre-update backup; manager не изменён.') printf 'Failed to create and verify the local pre-update backup; the Manager was not changed.'; return;;
    'Проверенный pre-update backup:'*) printf 'Verified pre-update backup:%s' "${text#*:}"; return;;
    'Не удалось подготовить/установить первую manager-копию; проверенный backup сохранён:'*) printf 'Failed to prepare or install the first Manager copy; the verified backup was retained:%s' "${text#*:}"; return;;
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
    read -r -p "$(ui_msg choice): " choice
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
    -e 's/("secret"[[:space:]]*:[[:space:]]*")(dd)?[0-9A-Fa-f]{32}(")/\1[REDACTED]\3/g'
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
  return "$rc"
}

trap 'rc=$?; on_error "$rc" "$LINENO" "$BASH_COMMAND"' ERR

banner() {
  printf "%bTWebProxy Manager v%s%b\n" "$C_BOLD" "$MANAGER_RELEASE_VERSION" "$C_RESET"
  printf '%s\n' "$(ui_msg product_subtitle)"
}

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запусти от root: sudo $0"; }
need_systemd() { command -v systemctl >/dev/null 2>&1 || die "Нужен systemd."; }

ask() {
  local prompt="$1" default="${2:-}" value
  prompt="$(ui_localize_legacy "$prompt")"
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
  prompt="$(ui_localize_legacy "$prompt")"
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
  echo "$(ui_localize_legacy "$prompt")" >&2
  for i in "${!options[@]}"; do printf "  [%d] %s\n" "$((i+1))" "$(ui_localize_legacy "${options[$i]}")" >&2; done
  while true; do
    read -r -p "> " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "$(ui_msg enter_number)" >&2; continue; }
    (( choice >= 1 && choice <= ${#options[@]} )) || { warn "$(ui_msg unknown_option)" >&2; continue; }
    printf '%s' "$choice"
    return 0
  done
}

menu_choose() {
  local prompt="$1" zero="$2"; shift 2
  local options=("$@") i choice
  printf '%s\n' "$prompt" >&2
  for i in "${!options[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${options[$i]}" >&2; done
  printf '  [0] %s\n' "$zero" >&2
  while true; do
    read -r -p "> " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "$(ui_msg enter_number)" >&2; continue; }
    (( choice >= 0 && choice <= ${#options[@]} )) || { warn "$(ui_msg unknown_option)" >&2; continue; }
    printf '%s' "$choice"; return 0
  done
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
PartOf=nftables.service
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
  [[ -s "$rules" ]] && "$DPI_NFT_BIN" -f "$rules" >/dev/null
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
  rm -f -- "$DPI_DOC_DIR/nfqws-LICENSE.txt"
  id twebproxy-dpi >/dev/null 2>&1 && userdel twebproxy-dpi >/dev/null 2>&1 || true
  return "$rc"
}

dpi_cleanup_stock_runtime() {
  local rc=0
  dpi_cleanup_nfqws_runtime || rc=1
  dpi_unit_teardown "$DPI_FIREWALL_UNIT" || rc=1
  dpi_apply_rules_file /dev/null || true
  rm -f -- "$LIBEXEC_DIR/apply-dpi-firewall" "$DPI_NFT_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  # Fail closed: STOCK is only reached when no DPI unit is active any more.
  if ! dpi_runtime_units_inactive; then
    dpi_stage_fail 'cleanup stock runtime' dpi_cleanup_stock_runtime 1 "a TWebProxy DPI unit is still active"
    rc=1
  fi
  return "$rc"
}

dpi_verify_runtime() {
  local need_nfqws="$1" file
  [[ -s "$DPI_NFT_FILE" ]] || return 1
  "$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE" >/dev/null 2>&1 || return 1
  while IFS= read -r file; do
    dpi_load_scope_file "$file" || return 1
    "$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE" 2>/dev/null | grep -Fq "$DPI_SCOPE_IPV4" || return 1
  done < <(find "$DPI_STATE_DIR" -mindepth 1 -maxdepth 1 -print | sort)
  if (( need_nfqws )); then
    [[ -f "$DPI_NFQWS_BIN" && ! -L "$DPI_NFQWS_BIN" ]] || return 1
    [[ "$(sha256sum "$DPI_NFQWS_BIN" | awk '{print $1}')" == "$DPI_NFQWS_SHA256" ]] || return 1
    systemctl is-active --quiet "$DPI_NFQWS_UNIT" || return 1
  fi
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
  local prev_phase="${DPI_DIAG_PHASE:-}"
  rm -rf "$DPI_DIR"
  if [[ -d "$snapshot/dpi" ]]; then cp -a "$snapshot/dpi" "$DPI_DIR"; fi
  unset TWEBPROXY_DPI_TEST_FAIL_POINT
  DPI_DIAG_PHASE=rollback
  if dpi_reconcile_runtime >/dev/null 2>&1; then
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

dpi_commit_candidate_state() {
  local proposed="$1" snapshot="$2"
  dpi_stage_reset
  DPI_LAST_STAGE='commit state'
  install -d -o root -g root -m 0700 "$DPI_DIR"
  rm -rf "$DPI_STATE_DIR"
  cp -a "$proposed" "$DPI_STATE_DIR"
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
  DPI_LAST_STAGE="$stage"; DPI_LAST_STAGE_OP="$op"
  DPI_LAST_STAGE_RC="$rc"; DPI_LAST_STAGE_REASON="$reason"
  dpi_diag_log "stage=$stage op=$op status=$rc result=failed reason=$reason rollback=$rollback"
  [[ "$rollback" == restored ]]
}

# The concise TUI line for a failed compatibility change, naming the stage that
# failed when one was recorded.
dpi_transaction_failure_message() {
  local mode="${1:-}"
  if [[ -n "${DPI_LAST_STAGE:-}" && -n "$mode" ]]; then
    ui_msgf dpi_transaction_failed_stage "$mode" "$DPI_LAST_STAGE"
  elif [[ -n "${DPI_LAST_STAGE:-}" ]]; then
    ui_msgf dpi_transaction_failed_at_stage "$DPI_LAST_STAGE"
  else
    ui_msg dpi_transaction_failed
  fi
}

dpi_transaction_set() {
  local ip="$1" mode="$2" host="$3" work snapshot proposed
  dpi_stage_reset
  # Fail closed before any state is touched: an unmatchable scope must never be
  # committed, and a previously working mode must survive the refusal.
  dpi_scope_locally_configured "$ip" || return 1
  work="$(mktemp -d /tmp/twebproxy-dpi.XXXXXX)" || return 1
  snapshot="$work/snapshot"; proposed="$work/proposed"
  mkdir -p "$snapshot" "$proposed"
  [[ -d "$DPI_DIR" ]] && cp -a "$DPI_DIR" "$snapshot/dpi"
  [[ -d "$DPI_STATE_DIR" ]] && cp -a "$DPI_STATE_DIR/." "$proposed/"
  find "$proposed" -maxdepth 1 -type f -name '*.env' -exec chmod 0600 {} + 2>/dev/null || true
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
  local ip="$1" work snapshot proposed
  dpi_stage_reset
  work="$(mktemp -d /tmp/twebproxy-dpi.XXXXXX)" || return 1
  snapshot="$work/snapshot"; proposed="$work/proposed"
  mkdir -p "$snapshot" "$proposed"
  [[ -d "$DPI_DIR" ]] && cp -a "$DPI_DIR" "$snapshot/dpi"
  [[ -d "$DPI_STATE_DIR" ]] && cp -a "$DPI_STATE_DIR/." "$proposed/"
  rm -f "$(dpi_state_path "$proposed" "$ip")"
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
  printf '%-22s %s\n' window1152 "$(ui_msg dpi_method_window)"
  printf '%-22s %s\n' mss88 "$(ui_msg dpi_method_mss)"
  printf '%-22s %s\n' nfqws "$(ui_msg dpi_method_nfqws)"
  printf '%-22s %s\n' window1152_nfqws "$(ui_msg dpi_method_window_nfqws)"
  printf '%-22s %s\n' mss88_nfqws "$(ui_msg dpi_method_mss_nfqws)"
  printf '\n%s\n' "$(ui_msgf dpi_nfqws_provenance "$DPI_NFQWS_VERSION" "$DPI_NFQWS_COMMIT")"
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
  instance_exists "$host" || die "Нет $host"
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
  if dpi_transaction_set "$ip" "$mode" "$host"; then
    ok "$(ui_msgf dpi_applied "$mode" "$host" "$ip")"
  else
    die "$(dpi_transaction_failure_message "$mode")"
  fi
}

dpi_disable_cmd() {
  need_root; need_systemd
  local host="${1:-}" ip file
  [[ -n "$host" ]] || die "Usage: twebproxy dpi disable HOST"
  instance_exists "$host" || die "Нет $host"
  ip="$(dpi_resolve_ipv4 "$host" 2>/dev/null || true)"
  if [[ -z "$ip" && -d "$DPI_STATE_DIR" ]]; then
    while IFS= read -r file; do
      dpi_load_scope_file "$file" || continue
      [[ "$DPI_SCOPE_HOST" == "$host" ]] && { ip="$DPI_SCOPE_IPV4"; break; }
    done < <(find "$DPI_STATE_DIR" -maxdepth 1 -type f -name '*.env' -print | sort)
  fi
  [[ -n "$ip" ]] || die "$(ui_msgf dpi_resolution_failed "$host")"
  if [[ ! -f "$(dpi_state_path "$DPI_STATE_DIR" "$ip")" ]]; then
    ok "$(ui_msgf dpi_disabled "$host")"; return 0
  fi
  dpi_transaction_disable_ip "$ip" || die "$(dpi_transaction_failure_message)"
  ok "$(ui_msgf dpi_disabled "$host")"
}

dpi_prune_orphan_state() {
  local file hosts
  [[ -d "$DPI_STATE_DIR" ]] || return 0
  while IFS= read -r file; do
    dpi_load_scope_file "$file" || { warn "Unsafe DPI state: $file"; return 1; }
    hosts="$(dpi_hosts_for_ipv4 "$DPI_SCOPE_IPV4" 2>/dev/null || true)"
    [[ -n "$hosts" ]] || rm -f "$file"
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
  local old_ip="$1"
  [[ -n "$old_ip" ]] || return 0
  [[ -n "$(dpi_hosts_for_ipv4 "$old_ip" 2>/dev/null || true)" ]] || rm -f "$(dpi_state_path "$DPI_STATE_DIR" "$old_ip")"
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
  local ports=() f pair client stats
  shopt -s nullglob
  for f in "$BACKENDS_DIR"/*.env; do
    # Each backend is parsed in its own subshell with the fields unset first, so
    # a truncated file can never inherit the previous backend's ports and leave
    # a real port out of the isolation set. Same discipline as port_registered.
    pair="$(
      unset MTPROXY_CLIENT_PORT MTPROXY_STATS_PORT
      # shellcheck disable=SC1090
      source "$f" >/dev/null 2>&1 || exit 1
      [[ -n "${MTPROXY_CLIENT_PORT:-}" && -n "${MTPROXY_STATS_PORT:-}" ]] || exit 1
      printf '%s %s' "$MTPROXY_CLIENT_PORT" "$MTPROXY_STATS_PORT"
    )" || { shopt -u nullglob; die "$(ui_msgf firewall_backend_state_invalid "$f")"; }
    client="${pair%% *}"; stats="${pair##* }"
    if ! is_valid_port "$client" || ! is_valid_port "$stats"; then
      shopt -u nullglob; die "$(ui_msgf firewall_backend_state_invalid "$f")"
    fi
    ports+=("$client" "$stats")
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
  local self="${BASH_SOURCE[0]}" target
  [[ -f "$self" ]] || return 0
  install -d -o root -g root -m 0700 "$PROJECT_DIR" "$LOG_DIR" "$LOG_MANAGER_DIR" "$LOG_RUNTIME_DIR" "$LOG_BUNDLE_DIR" "$LOG_FULL_DIR" || return 1
  # Each destination is handled independently: when the manager runs from one of
  # its own installed paths that destination is already the running file (GNU
  # install refuses an identical source and destination), but the other copy
  # must still be synchronised.
  for target in "$MANAGER_BIN" "$PROJECT_MANAGER_COPY"; do
    if same_underlying_file "$self" "$target"; then
      chown root:root -- "$target" || return 1
      chmod 0755 -- "$target" || return 1
    else
      install -o root -g root -m 0755 "$self" "$target" || return 1
    fi
  done
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

s4_backup_root_safe() {
  s4_safe_dir "$UPDATE_BACKUP_PARENT" 700 && s4_safe_dir "$UPDATE_BACKUP_ROOT" 700
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

s4_manager_health() {
  local expected_hash="$1" expected_version="$2" target hash output
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  s4_valid_version "$expected_version" || return 1
  for target in "$MANAGER_BIN" "$PROJECT_MANAGER_COPY"; do
    s4_target_parent_safe "$target" || return 1
    s4_manager_file_safe "$target" || return 1
    hash="$(sha256sum "$target" | awk '{print $1}')"
    [[ "$hash" == "$expected_hash" ]] || return 1
    bash -n "$target" || return 1
    output="$(TWEBPROXY_NO_LOG=1 timeout 15 "$target" --help 2>/dev/null)" || return 1
    grep -Fq "TWebProxy Manager v$expected_version" <<< "$output" || return 1
    output="$(TWEBPROXY_NO_LOG=1 timeout 20 "$target" --json overview 2>/dev/null)" || return 1
    jq -e --arg version "$expected_version" '
      type == "object" and .schema_version == "twebproxy.output.v1" and
      .command == "overview" and .data.manager_version == $version
    ' <<< "$output" >/dev/null || return 1
  done
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
  exec {S4_LOCK_FD}>"$UPDATE_LOCK_FILE" || return 1
  s4_safe_file "$UPDATE_LOCK_FILE" 600 || return 1
  flock -n "$S4_LOCK_FD"
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

stage4_install_restore_helper() {
  local allow_bootstrap="${1:-no}" dir dir_parent tmp output first
  dir="$(dirname -- "$UPDATE_RESTORE_HELPER")"
  stage4_no_symlink_components "$dir" || return 1
  if [[ ! -e "$dir" ]]; then
    [[ "$allow_bootstrap" == yes ]] || return 1
    dir_parent="$(dirname -- "$dir")"
    stage4_no_symlink_components "$dir_parent" || return 1
    [[ -d "$dir_parent" && ! -L "$dir_parent" && "$(stat -c '%u:%g' -- "$dir_parent" 2>/dev/null)" == 0:0 ]] || return 1
    install -d -o root -g root -m 0755 "$dir" || return 1
  fi
  [[ -d "$dir" && ! -L "$dir" && "$(stat -c '%u:%g' -- "$dir" 2>/dev/null)" == 0:0 ]] || return 1
  if [[ -e "$UPDATE_RESTORE_HELPER" || -L "$UPDATE_RESTORE_HELPER" ]]; then
    stage4_safe_root_file "$UPDATE_RESTORE_HELPER" 755 || return 1
    bash -n "$UPDATE_RESTORE_HELPER" || return 1
    bash -c '
      source "$1"
      [[ "$UPDATE_BACKUP_FORMAT" == "$2" && "$UPDATE_BACKUP_PARENT" == "$3" &&
         "$UPDATE_BACKUP_ROOT" == "$4" && "$UPDATE_LOCK_FILE" == "$5" &&
         "$MANAGER_BIN" == "$6" && "$PROJECT_MANAGER_COPY" == "$7" ]]
      declare -F s4_verify_backup_dir s4_manager_health s4_restore_id s4_prune_verified >/dev/null
    ' _ "$UPDATE_RESTORE_HELPER" "$UPDATE_BACKUP_FORMAT" "$UPDATE_BACKUP_PARENT" \
      "$UPDATE_BACKUP_ROOT" "$UPDATE_LOCK_FILE" "$MANAGER_BIN" "$PROJECT_MANAGER_COPY" || return 1
    output="$(TWEBPROXY_NO_LOG=1 timeout 10 "$UPDATE_RESTORE_HELPER" list 2>/dev/null)" || return 1
    first="${output%%$'\n'*}"
    [[ "$first" == "format=$UPDATE_BACKUP_FORMAT" ]]
    return
  fi
  [[ "$allow_bootstrap" == yes ]] || return 1
  tmp="$(mktemp "$dir/.restore-update-backup.XXXXXX")" || return 1
  trap 'rm -f -- "$tmp"' RETURN
  stage4_render_restore_helper > "$tmp"
  chmod 0755 "$tmp"
  chown root:root "$tmp"
  bash -n "$tmp" || return 1
  mv -fT -- "$tmp" "$UPDATE_RESTORE_HELPER" || return 1
  tmp=""
  stage4_safe_root_file "$UPDATE_RESTORE_HELPER" 755 || return 1
  trap - RETURN
  stage4_install_restore_helper no
}

stage4_verify_backup() {
  local dir="$1" id="$2" state="${3:-published}"
  bash -c 'source "$1"; s4_verify_backup_dir "$2" "$3" "$4"' _ \
    "$UPDATE_RESTORE_HELPER" "$dir" "$id" "$state"
}

stage4_prune_backups() {
  local protect="${1:-}"
  bash -c 'source "$1"; s4_prune_verified "$2"' _ "$UPDATE_RESTORE_HELPER" "$protect"
}

stage4_prepare_backup_root() {
  local parent_parent
  parent_parent="$(dirname -- "$UPDATE_BACKUP_PARENT")"
  stage4_no_symlink_components "$parent_parent" || return 1
  [[ -d "$parent_parent" && ! -L "$parent_parent" ]] || return 1
  if [[ ! -e "$UPDATE_BACKUP_PARENT" ]]; then
    install -d -o root -g root -m 0700 "$UPDATE_BACKUP_PARENT" || return 1
  fi
  stage4_no_symlink_components "$UPDATE_BACKUP_PARENT" || return 1
  [[ -d "$UPDATE_BACKUP_PARENT" && ! -L "$UPDATE_BACKUP_PARENT" ]] || return 1
  [[ "$(stat -c '%u:%g:%a' -- "$UPDATE_BACKUP_PARENT" 2>/dev/null)" == 0:0:700 ]] || return 1
  if [[ ! -e "$UPDATE_BACKUP_ROOT" ]]; then
    install -d -o root -g root -m 0700 "$UPDATE_BACKUP_ROOT" || return 1
  fi
  stage4_no_symlink_components "$UPDATE_BACKUP_ROOT" || return 1
  [[ -d "$UPDATE_BACKUP_ROOT" && ! -L "$UPDATE_BACKUP_ROOT" ]] || return 1
  [[ "$(stat -c '%u:%g:%a' -- "$UPDATE_BACKUP_ROOT" 2>/dev/null)" == 0:0:700 ]]
}

STAGE4_UPDATE_LOCK_FD=""
stage4_acquire_update_lock() {
  local parent
  parent="$(dirname -- "$UPDATE_LOCK_FILE")"
  stage4_no_symlink_components "$parent" || return 1
  [[ -d "$parent" && ! -L "$parent" ]] || return 1
  if [[ ! -e "$UPDATE_LOCK_FILE" ]]; then
    ( set -o noclobber; : > "$UPDATE_LOCK_FILE" ) 2>/dev/null || true
  fi
  stage4_safe_root_file "$UPDATE_LOCK_FILE" 600 || return 1
  # Use a fixed non-logging descriptor: Bash dynamic descriptors may be marked
  # close-on-exec, while the offline helper must inherit this exact locked open
  # file description for rollback without dropping the lock.
  STAGE4_UPDATE_LOCK_FD=9
  exec 9>"$UPDATE_LOCK_FILE" || return 1
  stage4_safe_root_file "$UPDATE_LOCK_FILE" 600 || return 1
  flock -n "$STAGE4_UPDATE_LOCK_FD"
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
  bash -c 'source "$1"; s4_manager_health "$2" "$3"' _ "$UPDATE_RESTORE_HELPER" "$first_hash" "$MANAGER_VERSION"
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
  trap 'rm -f -- "$tmp"' RETURN
  install -o root -g root -m 0755 "$candidate" "$tmp" || return 1
  stage4_safe_root_file "$tmp" 755 || return 1
  hash="$(sha256sum "$tmp" | awk '{print $1}')"
  [[ "$hash" == "$expected_hash" ]] || return 1
  bash -n "$tmp" || return 1
  mv -fT -- "$tmp" "$target" || return 1
  tmp=""
  trap - RETURN
}

stage4_manager_health() {
  local expected_hash="$1" expected_version="$2"
  bash -c 'source "$1"; s4_manager_health "$2" "$3"' _ \
    "$UPDATE_RESTORE_HELPER" "$expected_hash" "$expected_version"
}

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
  need_root; banner
  local selector="${1:-latest}"
  stage4_install_restore_helper no || die "Offline rollback helper отсутствует или небезопасен: $UPDATE_RESTORE_HELPER"
  if [[ "$selector" == latest ]]; then
    yesno "Восстановить самый новый проверенный manager backup?" n || return 0
    "$UPDATE_RESTORE_HELPER" restore-latest
  else
    [[ "$selector" =~ ^update-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$ ]] || die "Некорректный backup ID."
    yesno "Восстановить manager из $selector?" n || return 0
    "$UPDATE_RESTORE_HELPER" restore "$selector"
  fi
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
  local force=0 candidate="" checksums="" expected actual embedded ref script_url checksum_url
  local backup_id="" rollback_rc=0
  [[ "${1:-}" == "--force" ]] && force=1

  stage4_acquire_update_lock || die "Manager update уже выполняется или lock небезопасен: $UPDATE_LOCK_FILE"
  stage4_install_restore_helper yes || die "Offline rollback helper отсутствует или небезопасен; обновление остановлено до создания backup."
  stage4_current_manager_preflight || die "Текущие manager-копии не образуют точное безопасное состояние; обновление остановлено до создания backup."

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
  chmod 0600 "$candidate"

  # The downloaded script has not executed at this point.  Publish and verify
  # the exact pre-update payload before the first target mutation.
  backup_id="$(stage4_create_backup "$REMOTE_MANAGER_VERSION")" \
    || die "Не удалось создать и проверить локальный pre-update backup; manager не изменён."
  log "Проверенный pre-update backup: $backup_id"

  if ! stage4_install_candidate_target "$candidate" "$MANAGER_BIN" "$actual"; then
    die "Не удалось подготовить/установить первую manager-копию; проверенный backup сохранён: $backup_id"
  fi
  if ! stage4_install_candidate_target "$candidate" "$PROJECT_MANAGER_COPY" "$actual" \
     || ! stage4_manager_health "$actual" "$REMOTE_MANAGER_VERSION"; then
    warn "Установка или bounded health-check не завершились. Выполняю один exact rollback: $backup_id"
    if stage4_rollback_exact "$backup_id"; then rollback_rc=0; else rollback_rc=$?; fi
    stage4_prune_backups "$backup_id" || warn "Не удалось выполнить retention проверенных backup; содержимое оставлено без изменений."
    trap - RETURN
    rm -f -- "$candidate" "$checksums"
    if (( rollback_rc == 0 )); then
      printf 'UPDATE_FAILED_ROLLBACK_SUCCESS backup_id=%s\n' "$backup_id"
      return 1
    fi
    printf 'UPDATE_FAILED_ROLLBACK_FAILED backup_id=%s\n' "$backup_id" >&2
    return 1
  fi

  if ! set_global_manager_version "$REMOTE_MANAGER_VERSION"; then
    warn "Manager обновлён, но не удалось обновить metadata в global.env; следующий repair исправит metadata."
  fi
  rm -f "$UPDATE_CACHE_FILE" || warn "Manager обновлён, но update cache не удалён."
  stage4_prune_backups "$backup_id" || warn "Manager обновлён, но retention проверенных backup не выполнен."
  trap - RETURN
  rm -f -- "$candidate" "$checksums"
  ok "TWebProxy Manager обновлён: $MANAGER_VERSION -> $REMOTE_MANAGER_VERSION"
  printf 'UPDATE_SUCCESS backup_id=%s\n' "$backup_id"
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
  install_base_deps
  prepare_users_and_dirs
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

install_nginx_certbot_deploy_hook() {
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/twebproxy-nginx-reload <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if systemctl is-active --quiet nginx.service; then
  nginx -t
  systemctl reload nginx.service
fi
EOF
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/twebproxy-nginx-reload
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
  certbot certonly --webroot -w /var/lib/twebproxy/acme --cert-name "$host" -d "$host" --non-interactive --agree-tos --email "$email" --keep-until-expiring
  install_nginx_certbot_deploy_hook
  ensure_nginx_le_auto_renew
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
  if [[ "$UI_LANGUAGE" == en ]]; then
    printf "%bWEB Proxy uses public HTTPS/443; the client does not specify a port.%b\n" "$C_YELLOW" "$C_RESET"
  else
    printf "%bWEB Proxy использует публичный HTTPS/443 — порт в клиенте не задаётся.%b\n" "$C_YELLOW" "$C_RESET"
  fi
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
    read -r -s -p "$([[ "$UI_LANGUAGE" == en ]] && printf 'Secret (32 hex or dd+32 hex): ' || printf 'Secret (32 hex либо dd+32 hex): ')" SECRET; echo
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
  [[ "$UI_LANGUAGE" == en ]] && printf "%bFirst profile for %s%b\n" "$C_BOLD" "$HOSTNAME" "$C_RESET" \
    || printf "%bПервый профиль для %s%b\n" "$C_BOLD" "$HOSTNAME" "$C_RESET"
  local host="$HOSTNAME"
  collect_profile_settings "$host" default

  echo
  if [[ "$UI_LANGUAGE" == en ]]; then cat <<EOF
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
EOF
  fi
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
  dpi_repair_all || true
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
  stage4_install_restore_helper yes || die "Не удалось установить безопасный offline rollback helper."
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
  dpi_repair_all || true
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
    read -r -s -p "$([[ "$UI_LANGUAGE" == en ]] && printf 'New secret: ' || printf 'Новый secret: ')" new_secret; echo; is_valid_secret "$new_secret" || die "Некорректный secret."
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
  ((${#hosts[@]} > 0)) || die "$(ui_msg no_hostnames)"
  if ((${#hosts[@]} == 1)); then printf '%s' "${hosts[0]}"; return; fi
  n="$(choose "$(ui_msg select_hostname):" "${hosts[@]}")"; printf '%s' "${hosts[$((n-1))]}"
}

select_profile() {
  local host="$1" profiles=() p n
  while read -r p; do [[ -n "$p" ]] && profiles+=("$p"); done < <(list_profiles_array "$host")
  ((${#profiles[@]} > 0)) || die "$(ui_msgf no_profiles "$host")"
  if ((${#profiles[@]} == 1)); then printf '%s' "${profiles[0]}"; return; fi
  n="$(choose "$(ui_msg select_profile):" "${profiles[@]}")"; printf '%s' "${profiles[$((n-1))]}"
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
    state="$(systemctl is-active "twebproxy-mtproxy@$(backend_id "$host" "$p").service" 2>/dev/null || true)"
    printf "%-18s %-18s %-16s %-9s %-9s %-12s\n" "$p" "$CARRIER_MODE" "$masked" "$BACKEND_PORT" "$STATS_PORT" "$state"
  done < <(list_profiles_array "$host")
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
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    if [[ "$state" == active ]]; then
      tcore_add_check "relay.service.active" OK critical "hostname:$host" systemd active active \
        "Relay service is active" none
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
      state="$(systemctl is-active "$frontend_unit" 2>/dev/null || true)"
      if [[ "$state" == active ]]; then
        tcore_add_check "frontend.service.active" OK critical "hostname:$host" systemd active active \
          "Managed frontend service is active" none
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
      state="$(systemctl is-active "twebproxy-mtproxy@$(backend_id "$host" "$p").service" 2>/dev/null || true)"
      if [[ "$state" == active ]]; then
        tcore_add_check "profile.backend.service.active" OK critical "profile:$host/$p" systemd active active \
          "MTProxy backend service is active" none
      else
        tcore_add_check "profile.backend.service.active" ERROR critical "profile:$host/$p" systemd "${state:-unknown}" active \
          "MTProxy backend service is not active" none
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
    state="$(systemctl is-active "twebproxy-mtproxy@$(backend_id "$host" "$p").service" 2>/dev/null || true)"
    if [[ "$state" == active ]]; then
      tcore_add_check "profile.backend.service.active" OK critical "profile:$host/$p" systemd active active \
        "MTProxy backend service is active" none
    else
      tcore_add_check "profile.backend.service.active" ERROR critical "profile:$host/$p" systemd "${state:-unknown}" active \
        "MTProxy backend service is not active" none
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
  [[ -n "$host" ]] || host="$(select_instance)"
  instance_exists "$host" || die "Нет $host"
  load_instance "$host"

  case "$TLS_MODE" in
    nginx-le)
      command -v certbot >/dev/null 2>&1 || die "certbot не установлен. Запусти repair."
      install_nginx_certbot_deploy_hook
      ensure_nginx_le_auto_renew
      log "Проверяю необходимость продления Let's Encrypt для $host..."
      if [[ "$force" == "--dry-run" ]]; then
        certbot renew --cert-name "$host" --dry-run
        ok "Certbot renewal dry-run PASS; рабочий сертификат не заменялся."
        cert_status_impl "$host"
        return 0
      elif [[ "$force" == "--force" ]]; then
        warn "Force renewal может приблизить rate limit Let's Encrypt."
        certbot renew --cert-name "$host" --force-renewal
      elif [[ -n "$force" ]]; then
        die "Использование: twebproxy cert-renew [hostname] [--dry-run|--force]"
      else
        certbot renew --cert-name "$host"
      fi
      nginx -t
      systemctl reload nginx
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
  instance_exists "$host" || die "Нет $host"
  while read -r p; do
    [[ -n "$p" ]] && start_profile_backend "$host" "$p"
  done < <(list_profiles_array "$host")
  restart_relay_wait_ready "$host"
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
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  evidence="$(systemctl --no-pager --full status "$unit" 2>&1 || true)"
  if [[ "$state" == active ]]; then
    tcore_add_check "relay.service.active" OK critical "hostname:$host" systemd "$state" active \
      "Relay service is active" service "" "$evidence"
  else
    tcore_add_check "relay.service.active" ERROR critical "hostname:$host" systemd "${state:-unknown}" active \
      "Relay service is not active" service "" "$evidence"
  fi

  while read -r p; do
    [[ -n "$p" ]] || continue
    unit="twebproxy-mtproxy@$(backend_id "$host" "$p").service"
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    evidence="$(systemctl --no-pager --full status "$unit" 2>&1 || true)"
    if [[ "$state" == active ]]; then
      tcore_add_check "profile.backend.service.active" OK critical "profile:$host/$p" systemd "$state" active \
        "MTProxy backend service is active" service "" "$evidence"
    else
      tcore_add_check "profile.backend.service.active" ERROR critical "profile:$host/$p" systemd "${state:-unknown}" active \
        "MTProxy backend service is not active" service "" "$evidence"
    fi
  done < <(list_profiles_array "$host")

  if health="$(curl -fsS "http://127.0.0.1:$ADMIN_PORT/healthz" 2>/dev/null)"; then
    tcore_add_check "relay.healthz" OK critical "hostname:$host" http "$health" success \
      "Relay health endpoint responded" health healthz
  else
    tcore_add_check "relay.healthz" ERROR critical "hostname:$host" http unavailable success \
      "Relay health endpoint did not respond" health healthz
  fi
  if health="$(curl -fsS "http://127.0.0.1:$ADMIN_PORT/readyz" 2>/dev/null)"; then
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

firewall_has_backend_port() {
  local port="$1" rules guard
  rules="$(nft list table inet twebproxy_backend 2>/dev/null || true)"
  [[ -n "$rules" ]] || return 1
  guard="$(grep -F 'iifname != "lo" tcp dport' <<<"$rules" || true)"
  [[ -n "$guard" ]] || return 1
  grep -Eq "(^|[^0-9])${port}([^0-9]|$)" <<<"$guard"
}

collect_audit() {
  local host="$1" p unit spec label port addrs cert_tmp cert_days cert_local
  local cert_public_fp cert_local_fp renew_source
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

  if systemctl is-active --quiet "twebproxy@$host.service"; then
    tcore_add_check "relay.service.active" OK critical "hostname:$host" systemd active active \
      "Relay service is active" ok "relay service active"
  else
    tcore_add_check "relay.service.active" ERROR critical "hostname:$host" systemd inactive active \
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

  if systemctl is-active --quiet twebproxy-firewall.service && nft list table inet twebproxy_backend >/dev/null 2>&1; then
    tcore_add_check "firewall.backend.boundary" OK critical global nftables active active \
      "Backend firewall service and table are active" ok "backend firewall service/table active"
  else
    tcore_add_check "firewall.backend.boundary" ERROR critical global nftables missing active \
      "Backend firewall service or table is missing" warn "AUDIT FAIL: backend firewall service/table отсутствует"
  fi

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
    unit="twebproxy-mtproxy@$(backend_id "$host" "$p").service"

    if systemctl is-active --quiet "$unit"; then
      tcore_add_check "profile.backend.service.active" OK critical "profile:$host/$p" systemd active active \
        "MTProxy backend is active" ok "$p: MTProxy backend active"
    else
      tcore_add_check "profile.backend.service.active" ERROR critical "profile:$host/$p" systemd inactive active \
        "MTProxy backend is not active" warn "AUDIT FAIL: $p backend service не active"
    fi

    if systemctl cat "$unit" 2>/dev/null | grep -Eq '^RestrictAddressFamilies=.*AF_NETLINK'; then
      tcore_add_check "profile.backend.sandbox.af_netlink" OK warning "profile:$host/$p" systemd present present \
        "MTProxy sandbox allows AF_NETLINK" ok "$p: MTProxy sandbox включает AF_NETLINK"
    else
      tcore_add_check "profile.backend.sandbox.af_netlink" WARNING warning "profile:$host/$p" systemd absent present \
        "MTProxy unit does not allow AF_NETLINK" warn "AUDIT WARN: $p unit без AF_NETLINK; запусти repair текущей версией manager"
    fi

    for spec in "backend:$BACKEND_PORT" "stats:$STATS_PORT"; do
      label="${spec%%:*}"; port="${spec##*:}"
      addrs="$(listener_addrs_for_port "$port")"
      if [[ -z "$addrs" ]]; then
        tcore_add_check "profile.$label.listener.present" ERROR critical "profile:$host/$p" socket absent "port:$port" \
          "$label listener is absent" warn "AUDIT FAIL: $p $label port $port не слушается"
        continue
      fi

      if firewall_has_backend_port "$port"; then
        tcore_add_check "profile.$label.firewall.coverage" OK critical "profile:$host/$p" nftables "$port" covered \
          "$label port is covered by the backend firewall" ok "$p: $label port $port покрыт nftables"
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
    cert_days="$(cert_days_remaining_file "$cert_tmp" 2>/dev/null || echo -9999)"
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
        if [[ -n "$cert_local_fp" && -n "$cert_public_fp" && "$cert_local_fp" == "$cert_public_fp" ]]; then
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
      if systemctl is-active --quiet caddy.service; then
        tcore_add_check "tls.manager.active" OK critical "hostname:$host" systemd active active \
          "Caddy automatic TLS manager is active" ok "Caddy automatic TLS manager active"
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
        if [[ -n "$cert_local_fp" && -n "$cert_public_fp" && "$cert_local_fp" == "$cert_public_fp" ]]; then
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
  local i failures warnings
  failures="$(tcore_error_count)"; warnings="$(tcore_warning_count)"
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
  systemctl is-active "twebproxy@$host.service" || true
  while read -r p; do [[ -n "$p" ]] && systemctl is-active "twebproxy-mtproxy@$(backend_id "$host" "$p").service" || true; done < <(list_profiles_array "$host")
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
  dig +short A "$host" || true; dig +short AAAA "$host" || true
  echo; printf '== %s ==\n' "$(ui_msg diag_public_https)"
  curl -I --max-time 10 "https://$host/" || true
  echo; printf '== %s ==\n' "$(ui_msg diag_certificate)"
  timeout 10 openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates || true
  echo; printf '== %s ==\n' "$(ui_msg diag_backend_firewall)"
  nft list table inet twebproxy_backend || true
  echo; printf '== %s ==\n' "$(ui_msg dpi_title)"
  "$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE" || true
  systemctl --no-pager --full status "$DPI_FIREWALL_UNIT" "$DPI_NFQWS_UNIT" || true
  echo
  audit_instance_impl "$host" || true
  echo; printf '== %s ==\n' "$(ui_msg diag_recent_logs)"
  journalctl -u "twebproxy@$host.service" --since '20 minutes ago' --no-pager -n 120 || true
  while read -r p; do [[ -n "$p" ]] && journalctl -u "twebproxy-mtproxy@$(backend_id "$host" "$p").service" --since '20 minutes ago' --no-pager -n 60 || true; done < <(list_profiles_array "$host")
}

delete_instance_cmd() {
  need_root; banner
  local host="${1:-}" p old_ip=""
  [[ -n "$host" ]] || host="$(select_instance)"; instance_exists "$host" || die "Нет $host"
  warn "Будет удалён hostname $host, все его secrets/backends и управляемый reverse-proxy block."
  yesno "Удалить $host?" n || exit 0
  old_ip="$(dpi_resolve_ipv4 "$host" 2>/dev/null || true)"
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
  dpi_remove_host_state_if_orphaned "$old_ip" || warn "$(ui_msg dpi_repair_warning)"
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
  dpi_full_uninstall
  systemctl disable --now twebproxy-refresh-mtproxy.timer twebproxy-firewall.service twebproxy-cert-renew.timer >/dev/null 2>&1 || true
  if nft list table inet twebproxy_backend >/dev/null 2>&1; then nft delete table inet twebproxy_backend || true; fi
  rm -f "$SYSTEMD_DIR/twebproxy@.service" "$SYSTEMD_DIR/twebproxy-mtproxy@.service" "$SYSTEMD_DIR/twebproxy-firewall.service" "$SYSTEMD_DIR/twebproxy-refresh-mtproxy.service" "$SYSTEMD_DIR/twebproxy-refresh-mtproxy.timer" "$SYSTEMD_DIR/twebproxy-cert-renew.service" "$SYSTEMD_DIR/twebproxy-cert-renew.timer"
  rm -f /etc/letsencrypt/renewal-hooks/deploy/twebproxy-nginx-reload
  rm -rf "$BASE_DIR" "$TPROXY_SRC" "$MTPROXY_SRC"
  rm -f "$MTPROXY_BIN" "$LIBEXEC_DIR/run-mtproxy" "$LIBEXEC_DIR/apply-firewall" "$LIBEXEC_DIR/refresh-mtproxy-config"
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
    "$DPI_NFT_BIN" list table ip "$DPI_NFT_TABLE" || true
    echo
    echo "== optional network compatibility =="
    find "$DPI_STATE_DIR" -maxdepth 1 -type f -name '*.env' -print -exec sed -n '1,20p' {} \; 2>/dev/null || true
    systemctl --no-pager --full status "$DPI_FIREWALL_UNIT" "$DPI_NFQWS_UNIT" || true
    [[ -f "$DPI_NFQWS_BIN" ]] && sha256sum "$DPI_NFQWS_BIN" || true
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
      echo
      echo "-- certificate status --"
      cert_status_impl "$host" || true
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
          journalctl -u "$unit" --since "$since" --until "$until_ts" \
            -n 2000 --no-pager -o short-iso-precise 2>&1 || true
        else
          journalctl -u "$unit" --since "$since" \
            -n 2000 --no-pager -o short-iso-precise 2>&1 || true
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
      if "$DPI_NFT_BIN" -a list table inet twebproxy_backend 2>/dev/null; then :; else
        echo "table_absent_or_unreadable=yes"
      fi
      echo
      echo "== table ip $DPI_NFT_TABLE =="
      if "$DPI_NFT_BIN" -a list table ip "$DPI_NFT_TABLE" 2>/dev/null; then :; else
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
  instance_exists "$host" || die "Нет $host"

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
  tar -czf "$bundle" -C "$staging" .
  chmod 0600 "$bundle"
  rm -rf "$staging"
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
    for state in "$relay" "$frontend" "$backend"; do
      [[ "$state" == ERROR ]] && break
      [[ "$state" == WARNING || "$state" == UNKNOWN ]] && break
    done
    printf '%b%-30s%b %s\n' "$C_BOLD" "$host" "$C_RESET" "$(tui_state_text "$state")"
    tui_text "  $(ui_msg profiles_count): $profiles  TLS: $tls  $(ui_msg dpi_mode): $dpi"
  done
}

tui_render_status() {
  local host="$1" i problems=0 dpi=STOCK
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
      tui_text "$(tui_state_text "${TCORE_STATUSES[$i]}") ${TCORE_IDS[$i]} — ${TCORE_OBSERVED[$i]}";; esac
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

menu_logs() {
  while true; do
    clear 2>/dev/null || true; tui_title "$(ui_msg logs_reports)"; tui_kv "Logs" "$LOG_DIR"; echo
    local c; c="$(menu_choose "$(ui_msg logs_reports):" "$(ui_msg back)" \
      "$(ui_msg list_logs)" "$(ui_msg tail_log)" "$(ui_msg runtime_snapshot)" \
      "$(ui_msg safe_bundle)" "$(ui_msg full_report)")"
    case "$c" in
      1) logs_list_cmd; pause;;
      2) logs_tail_cmd 200; pause;;
      3) logs_collect_cmd; pause;;
      4) logs_pack_cmd; pause;;
      5) report_cmd; pause;;
      0) return;;
    esac
  done
}

menu_profiles() {
  local host; host="$(select_instance)"
  while true; do
    clear 2>/dev/null || true
    collect_profiles_state "$host"; tui_render_profiles "$host"; echo
    local c; c="$(menu_choose "$(ui_msg profiles):" "$(ui_msg back)" \
      "$(ui_msg add_profile)" "$(ui_msg show_profile)" "$(ui_msg rotate_profile)" \
      "$(ui_msg carrier_profile)" "$(ui_msg delete_profile)")"
    case "$c" in
      1) profile_add_cmd "$host"; pause;;
      2) warn "$(ui_msg secret_warning)"; show_profile_cmd "$host" "$(select_profile "$host")"; pause;;
      3) profile_rotate_cmd "$host" "$(select_profile "$host")"; pause;;
      4) profile_carrier_cmd "$host" "$(select_profile "$host")"; pause;;
      5) profile_delete_cmd "$host" "$(select_profile "$host")"; pause;;
      0) return;;
    esac
  done
}

menu_certificates() {
  local host; host="$(select_instance)"
  while true; do
    clear 2>/dev/null || true
    collect_audit "$host"; tui_render_tls "$host"
    echo
    local c; c="$(menu_choose "$(ui_msg tls_certificates):" "$(ui_msg back)" \
      "$(ui_msg cert_details)" "$(ui_msg cert_dry_run)" "$(ui_msg cert_renew)" "$(ui_msg cert_force)")"
    case "$c" in
      1) cert_status_cmd "$host"; pause;;
      2) cert_renew_cmd "$host" --dry-run; pause;;
      3) cert_renew_cmd "$host"; pause;;
      4) cert_renew_cmd "$host" --force; pause;;
      0) return;;
    esac
  done
}

menu_web_proxy() {
  while true; do
    clear 2>/dev/null || true
    collect_overview; tui_render_dashboard; echo
    local c; c="$(menu_choose "$(ui_msg instances):" "$(ui_msg back)" \
      "$(ui_msg add_instance)" "$(ui_msg show_connection)" "$(ui_msg manual_snippet)" \
      "$(ui_msg restart_instance)" "$(ui_msg repair_instance)" "$(ui_msg delete_instance)" \
      "$(ui_msg uninstall_core)")"
    case "$c" in
      1) add_instance_cmd; pause;;
      2) show_instance_cmd; pause;;
      3) manual_snippet_cmd; pause;;
      4) restart_cmd; pause;;
      5) repair_instance_cmd; pause;;
      6) delete_instance_cmd; pause;;
      7) core_uninstall_cmd; pause;;
      0) return;;
    esac
  done
}

menu_status_statistics() {
  local host; host="$(select_instance)"
  while true; do
    clear 2>/dev/null || true; collect_status "$host"; tui_render_status "$host"; echo
    local c; c="$(menu_choose "$(ui_msg status_stats):" "$(ui_msg back)" \
      "$(ui_msg compact_status)" "$(ui_msg compact_statistics)" \
      "$(ui_msg detailed_status)" "$(ui_msg raw_statistics)")"
    case "$c" in
      1) clear 2>/dev/null || true; collect_status "$host"; tui_render_status "$host"; pause;;
      2) clear 2>/dev/null || true; collect_statistics_state "$host"; tui_render_statistics "$host"; pause;;
      3) status_cmd "$host" --verbose; pause;;
      4) stats_cmd "$host" --verbose; pause;;
      0) return;;
    esac
  done
}

menu_update_recovery() {
  while true; do
    clear 2>/dev/null || true; tui_render_update_recovery; echo
    local c; c="$(menu_choose "$(ui_msg update_recovery):" "$(ui_msg back)" \
      "$(ui_msg manager_check_update)" "$(ui_msg manager_install_update)" \
      "$(ui_msg backup_list)" "$(ui_msg rollback_latest)" "$(ui_msg relay_update)")"
    case "$c" in
      1) manager_check_update_cmd; pause;;
      2) manager_update_cmd; pause;;
      3) manager_backup_list_cmd; pause;;
      4) manager_restore_backup_cmd latest; pause;;
      5) update_cmd; pause;;
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
  local host c
  while true; do
    clear 2>/dev/null || true; tui_title "$(ui_msg diagnostics_logs)"; echo
    c="$(menu_choose "$(ui_msg diagnostics_logs):" "$(ui_msg back)" \
      "$(ui_msg full_diagnose)" "$(ui_msg isolation_audit)" "$(ui_msg typed_json)" \
      "$(ui_msg typed_raw)" "$(ui_msg field_diagnostics)" "$(ui_msg logs_reports)")"
    case "$c" in
      1) host="$(select_instance)"; diagnose_cmd "$host"; pause;;
      2) host="$(select_instance)"; audit_cmd "$host"; pause;;
      3) host="$(select_instance)"; collect_audit "$host"; tcore_render_json; pause;;
      4) host="$(select_instance)"; collect_audit "$host"; tcore_render_raw; pause;;
      5) host="$(select_instance)"; field_report_cmd "$host"; pause;;
      6) menu_logs;;
      0) return;;
    esac
  done
}

menu_network_compatibility() {
  local c host method selected
  while true; do
    clear 2>/dev/null || true; dpi_status_cmd; echo
    c="$(menu_choose "$(ui_msg dpi_title):" "$(ui_msg back)" \
      "$(ui_msg dpi_status)" "$(ui_msg dpi_methods)" \
      "$(ui_msg dpi_enable)" "$(ui_msg dpi_disable)")"
    case "$c" in
      1) host="$(select_instance)"; dpi_status_cmd "$host"; pause;;
      2) dpi_list_methods_cmd; pause;;
      3)
        host="$(select_instance)"
        selected="$(choose "$(ui_msg dpi_enable):" window1152 mss88 nfqws window1152_nfqws mss88_nfqws)"
        case "$selected" in
          1) method=window1152;; 2) method=mss88;; 3) method=nfqws;;
          4) method=window1152_nfqws;; 5) method=mss88_nfqws;;
        esac
        dpi_set_cmd "$host" "$method"; pause;;
      4) host="$(select_instance)"; dpi_disable_cmd "$host"; pause;;
      0) return;;
    esac
  done
}

menu_settings() {
  while true; do
    clear 2>/dev/null || true; tui_render_settings; echo
    local c lang; c="$(menu_choose "$(ui_msg settings):" "$(ui_msg back)" \
      "$(ui_msg change_language)" "$(ui_msg enable_color)" "$(ui_msg disable_color)" \
      "$(ui_msg network_compatibility)")"
    case "$c" in
      1) lang="$(choose "$(ui_msg change_language):" "$(ui_msg english)" "$(ui_msg russian)")";
         [[ "$lang" == 1 ]] && ui_language_store en || ui_language_store ru
         ok "$(ui_msg language_saved)";;
      2) enable_colors;;
      3) disable_colors;;
      4) menu_network_compatibility;;
      0) return;;
    esac
  done
}

menu() {
  need_root; need_systemd; ui_language_load
  while true; do
    if core_installed; then
      clear 2>/dev/null || true
      collect_overview; tui_render_dashboard; echo
      local c; c="$(menu_choose "$(ui_msg main_menu):" "$(ui_msg exit)" \
        "$(ui_msg instances)" "$(ui_msg profiles)" "$(ui_msg status_stats)" \
        "$(ui_msg maintenance)" "$(ui_msg diagnostics_logs)" "$(ui_msg settings)")"
      case "$c" in
        1) menu_web_proxy;;
        2) menu_profiles;;
        3) menu_status_statistics;;
        4) menu_maintenance;;
        5) menu_diagnostics;;
        6) menu_settings;;
        0) exit 0;;
      esac
    else
      ui_language_ensure_interactive_install
      clear 2>/dev/null || true; banner; echo
      local c; c="$(menu_choose "$(ui_msg first_action):" "$(ui_msg exit)" \
        "$(ui_msg first_install)" "$(ui_msg first_install_add)")"
      case "$c" in 1) core_install_cmd; pause;; 2) add_instance_cmd; pause;; 0) exit 0;; esac
    fi
  done
}

usage() {
  if [[ "$UI_LANGUAGE" == en ]]; then
    cat <<EOF
TWebProxy Manager v$MANAGER_RELEASE_VERSION

Usage: twebproxy [--json|--raw] [--no-color] [command] [args]

Manager / Core:
  check-update                 check for a new Manager version
  manager-update [--force]     verified backup, update, health gate and exact rollback
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

TWebProxy Manager / основа:
  check-update                 проверить новую версию TWebProxy Manager
  manager-update [--force]     резервная копия, обновление, проверка и точный откат
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
  menu                         двуязычный интерфейс по задачам

Флаги вывода можно указывать до или после команды. --json и --raw взаимно
исключаются, не задают вопросов и используют стабильные нелокализованные поля.
Telegram WEB Proxy всегда использует публичный HTTPS-порт 443.
EOF
  fi
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
    case "$cmd" in overview|status|audit|stats|profile-list) ;; *) die "$cmd пока не поддерживает --$OUTPUT_MODE.";; esac
    # Machine-readable stdout must contain only the selected renderer payload.
    export TWEBPROXY_NO_LOG=1
    disable_colors
  elif (( OUTPUT_NO_COLOR )) || [[ -n "${NO_COLOR:-}" ]]; then
    disable_colors
  fi

  setup_logging "$cmd"
  case "$cmd" in
    check-update) manager_check_update_cmd ;;
    manager-update) manager_update_cmd "${1:-}" ;;
    manager-backup-list) manager_backup_list_cmd ;;
    manager-rollback) manager_restore_backup_cmd "${1:-latest}" ;;
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
  main "$@"
fi
