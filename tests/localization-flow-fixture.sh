#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/twebproxy-manager.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
source "$SCRIPT"
trap - ERR
disable_colors
export COLUMNS=100

fail() { printf 'localization-flow-fixture: FAIL: %s\n' "$*" >&2; exit 1; }

assert_en() {
  local source="$1" token output
  shift
  UI_LANGUAGE=en
  output="$(ui_localize_legacy "$source")"
  ! ui_contains_cyrillic "$output" || fail "Cyrillic leaked: $source -> $output"
  [[ "$output" != UNTRANSLATED_MESSAGE_* ]] || fail "emergency fallback used: $source"
  for token in "$@"; do
    [[ "$output" == *"$token"* ]] || fail "lost '$token': $source -> $output"
  done
}

assert_ru() {
  local source="$1" output scan
  UI_LANGUAGE=ru
  output="$(ui_localize_legacy "$source")"
  ui_contains_cyrillic "$output" || fail "Russian flow lacks Russian prose: $source"
  scan="$(sed -E 's#(/[A-Za-z0-9._-]+)+#PATH#g' <<< "$output")"
  if LC_ALL=C grep -Eq '(^|[^A-Za-z])(live|legacy|lifecycle|Audit|renewal|Offline|helper|workflow|update-backup)([^A-Za-z]|$)' <<< "$scan"; then
    fail "ordinary English prose in Russian flow: $output"
  fi
}

# Representative reachable prompts and operation results. Each English check
# names the operational values that must survive localization.
while IFS=$'\t' read -r source tokens; do
  [[ -n "$source" ]] || continue
  IFS='|' read -r -a required <<< "$tokens"
  assert_en "$source" "${required[@]}"
  assert_ru "$source"
done <<'FLOW_CASES'
Базовая часть TWebProxy ещё не установлена. Установлю её сейчас.	TWebProxy core|Installing
Hostname WEB-proxy (без https://)	WEB Proxy hostname|https://
Имя профиля/секрета	Profile|secret
Carrier mode:	Carrier mode
Проксировать существующее web-приложение на loopback	Proxy|loopback|web application
Caddy — автоматический сертификат	Caddy|automatic certificate
Некорректный порт.	Invalid port
Порт 18080 уже занят или зарегистрирован TWebProxy.	18080|already in use|TWebProxy
MTProxy backend alpha/default не стал ready.	MTProxy backend|alpha/default|did not become ready
Инстанс alpha.example создан и прошёл isolation audit.	alpha.example|created|isolation audit
Профиль default добавлен.	Profile|default|added
Не удалось проверить обновление manager на https://example.test/releases	Failed|Manager update|https://example.test/releases
Установка или bounded health-check не завершились. Выполняю один exact rollback: update-20260825T120000Z-abcdef123456	bounded health check|exact rollback|update-20260825T120000Z-abcdef123456
Offline rollback helper отсутствует или небезопасен: /usr/local/libexec/twebproxy/restore-update-backup	offline rollback helper|unsafe|/usr/local/libexec/twebproxy/restore-update-backup
Сертификат не читается: /etc/ssl/example/fullchain.pem	Certificate|not readable|/etc/ssl/example/fullchain.pem
После renewal/reload публичная TLS-проверка не прошла.	Public TLS verification|renewal|reload|failed
AUDIT WARN: alpha stats endpoint не ответил на loopback	AUDIT WARN|alpha|statistics endpoint|loopback
AUDIT FAIL: alpha stats port 23981 не слушается	AUDIT FAIL|alpha|23981|not listening
FLOW_CASES

UI_LANGUAGE=ru
ru_helper="$(ui_localize_legacy 'Offline rollback helper отсутствует или небезопасен: /usr/local/libexec/twebproxy/restore-update-backup')"
[[ "$ru_helper" == *'/usr/local/libexec/twebproxy/restore-update-backup'* ]] || fail 'Russian localization changed a canonical path'

# Unknown-message fallback remains an explicit emergency marker and cannot be
# mistaken for a translated normal flow.
UI_LANGUAGE=en
unknown="$(ui_localize_legacy 'Совершенно неизвестная фраза 443 /tmp/evidence')"
[[ "$unknown" == UNTRANSLATED_MESSAGE_UTF8_HEX=* ]] || fail 'emergency fallback is not auditable'
! ui_contains_cyrillic "$unknown" || fail 'emergency fallback leaked Cyrillic'

build_compact() {
  tcore_reset status hostname:alpha.example
  tcore_add_check relay.service.active OK critical hostname:alpha.example systemd active active 'Relay active' none
  tcore_add_check tls.public.certificate.validity WARNING warning hostname:alpha.example tls 8 '>=15' 'Certificate expires soon' none
  tcore_finalize
  tui_render_status alpha.example
  tcore_reset stats hostname:alpha.example
  tcore_add_check statistics.relay.live OK info hostname:alpha.example relay available available 'Relay source' none '' $'twebproxy_sessions 12\ntwebproxy_streams 4\ntwebproxy_bytes_total 8192'
  tcore_add_check statistics.profile.live OK info profile:alpha.example/default stats available available 'Profile source' none '' $'connections\t6'
  tcore_add_check statistics.history DISABLED info hostname:alpha.example unavailable unavailable unavailable 'No history' none
  tcore_finalize
  tui_render_statistics alpha.example
  tui_render_settings
}

for lang in en ru; do
  UI_LANGUAGE="$lang"
  {
    build_compact
    printf '%s\n' "$(ui_msg full_diagnose)" "$(ui_msg isolation_audit)" "$(ui_msg typed_json)" "$(ui_msg typed_raw)"
    usage
  } > "$TMP/representative-$lang.txt"
done

! ui_contains_cyrillic "$(<"$TMP/representative-en.txt")" || fail 'English compact/help flow contains Cyrillic'
grep -q '^Relay sessions.*12$' "$TMP/representative-en.txt"
grep -q '^Relay streams.*4$' "$TMP/representative-en.txt"
grep -q '^Relay bytes total.*8.0 KiB (8192 B)$' "$TMP/representative-en.txt"
grep -q '^Backend connections.*6$' "$TMP/representative-en.txt"
grep -q 'Full legacy diagnostics' "$TMP/representative-en.txt"
grep -q 'Settings' "$TMP/representative-en.txt"

ui_contains_cyrillic "$(<"$TMP/representative-ru.txt")" || fail 'Russian compact/help flow lacks Russian prose'
grep -q '^Сессии relay.*12$' "$TMP/representative-ru.txt"
grep -q '^Потоки relay.*4$' "$TMP/representative-ru.txt"
grep -q '^Всего байтов relay.*8.0 KiB (8192 B)$' "$TMP/representative-ru.txt"
grep -q '^Соединения backend.*6$' "$TMP/representative-ru.txt"
grep -q 'Полная расширенная диагностика' "$TMP/representative-ru.txt"
grep -q 'Настройки' "$TMP/representative-ru.txt"
if LC_ALL=C grep -Eq '(^|[^A-Za-z])(live|legacy|lifecycle|Audit|renewal|Offline|helper|workflow|update-backup)([^A-Za-z]|$)' "$TMP/representative-ru.txt"; then
  fail 'ordinary English prose in Russian representative flows'
fi

# Exercise the actual certificate and audit presentation functions with
# read-only stubs, retaining hostname, mode, validity and issuer evidence.
(
  instance_exists() { return 0; }
  load_instance() { TLS_MODE=caddy; }
  fetch_public_leaf_cert() { printf 'fixture certificate\n' > "$2"; }
  cert_days_remaining_file() { printf '42'; }
  cert_fingerprint_file() { printf 'AA:BB'; }
  openssl() {
    case "$*" in
      *-issuer*) printf 'issuer=Fixture CA\n';;
      *-subject*) printf 'subject=CN=alpha.example\n';;
      *-serial*) printf 'serial=1234\n';;
    esac
  }
  systemctl() { return 0; }
  curl() { return 0; }
  for lang in en ru; do
    UI_LANGUAGE="$lang"
    cert_status_impl alpha.example > "$TMP/certificate-$lang.txt"
  done
)
! ui_contains_cyrillic "$(<"$TMP/certificate-en.txt")" || fail 'English certificate status contains Cyrillic'
grep -q '^== Certificate status: alpha.example ==$' "$TMP/certificate-en.txt"
grep -q '^TLS mode: caddy$' "$TMP/certificate-en.txt"
grep -q '42 day(s)' "$TMP/certificate-en.txt"
grep -q 'Fixture CA' "$TMP/certificate-en.txt"
grep -q '^== Состояние сертификата: alpha.example ==$' "$TMP/certificate-ru.txt"
grep -q '^Режим TLS: caddy$' "$TMP/certificate-ru.txt"
grep -q '42 дн.' "$TMP/certificate-ru.txt"
grep -q 'Fixture CA' "$TMP/certificate-ru.txt"

for lang in en ru; do
  UI_LANGUAGE="$lang"
  tcore_reset audit hostname:alpha.example
  TCORE_HOST=alpha.example
  tcore_add_check firewall.backend.boundary ERROR critical hostname:alpha.example nftables missing present \
    'Backend firewall rule missing' warn 'AUDIT FAIL: default backend port 23980 не найден в backend firewall rule'
  tcore_finalize
  render_audit_human > "$TMP/audit-$lang.txt"
done
! ui_contains_cyrillic "$(<"$TMP/audit-en.txt")" || fail 'English audit presentation contains Cyrillic'
grep -q '^== Isolation audit: alpha.example ==$' "$TMP/audit-en.txt"
grep -q 'default backend port 23980 is missing from the backend firewall rule' "$TMP/audit-en.txt"
grep -q '^== Аудит изоляции: alpha.example ==$' "$TMP/audit-ru.txt"
grep -q '23980' "$TMP/audit-ru.txt"
grep -q 'ОШИБКА АУДИТА' "$TMP/audit-ru.txt"

(
  need_root() { :; }
  load_instance() {
    RELAY_PORT=18080; ADMIN_PORT=18081; TLS_MODE=caddy; SITE_MODE=placeholder
  }
  load_profile() {
    PROFILE_NAME=default; CARRIER_MODE=https; SECRET=0123456789abcdef0123456789abcdef
  }
  count_profiles() { printf '1'; }
  list_profiles_array() { printf 'default\n'; }
  for lang in en ru; do
    UI_LANGUAGE="$lang"
    show_instance_cmd alpha.example > "$TMP/instance-$lang.txt"
    manual_snippet_cmd alpha.example > "$TMP/manual-$lang.txt"
  done
)
! ui_contains_cyrillic "$(<"$TMP/instance-en.txt")$(<"$TMP/manual-en.txt")" || fail 'English instance/manual flow contains Cyrillic'
grep -q '^Hostname:.*alpha.example$' "$TMP/instance-en.txt"
grep -q '^Public:.*https://alpha.example/' "$TMP/instance-en.txt"
grep -q '^Публичный адрес:.*https://alpha.example/' "$TMP/instance-ru.txt"
grep -q 'Профиль:' "$TMP/instance-ru.txt"
grep -q 'proxy the entire hostname through the relay' "$TMP/manual-en.txt"
grep -q 'весь hostname должен идти через relay' "$TMP/manual-ru.txt"
grep -q '/PATH/TO/fullchain.pem' "$TMP/manual-en.txt"
grep -q '/PATH/TO/fullchain.pem' "$TMP/manual-ru.txt"

if [[ -n "${TWEBPROXY_CAPTURE_DIR:-}" ]]; then
  install -d -m 0755 "$TWEBPROXY_CAPTURE_DIR"
  cp "$TMP/representative-en.txt" "$TWEBPROXY_CAPTURE_DIR/localization-representative-en.txt"
  cp "$TMP/representative-ru.txt" "$TWEBPROXY_CAPTURE_DIR/localization-representative-ru.txt"
  cp "$TMP"/certificate-*.txt "$TMP"/audit-*.txt "$TWEBPROXY_CAPTURE_DIR/"
  cp "$TMP"/instance-*.txt "$TMP"/manual-*.txt "$TWEBPROXY_CAPTURE_DIR/"
fi

printf 'localization-flow-fixture: PASS (locale=%s)\n' "${LC_ALL:-inherited}"
