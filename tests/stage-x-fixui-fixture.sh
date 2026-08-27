#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/twebproxy-manager.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export TWEBPROXY_NO_LOG=1
export COLUMNS=80
export TWEBPROXY_LANGUAGE_FILE="$TMP/etc/twebproxy/ui-language"

# shellcheck disable=SC1090
source "$SCRIPT"
trap - ERR
disable_colors

fail() { printf 'stage-x-fixui-fixture: FAIL: %s\n' "$*" >&2; exit 1; }
assert_width() { local n; n="$(wc -L < "$1")"; ((n <= $2)) || fail "$1 width $n > $2"; }

# Existing-install/non-interactive migration is deterministic and never writes.
rm -rf "$TMP/etc"
unset TWEBPROXY_UI_LANGUAGE
UI_LANGUAGE=en
ui_language_load
[[ "$UI_LANGUAGE" == ru ]] || fail 'legacy fallback is not Russian'
[[ ! -e "$TWEBPROXY_LANGUAGE_FILE" ]] || fail 'migration unexpectedly wrote state'

# Exact bilingual first-run selector; persist EN, reload, switch RU -> EN -> RU.
printf '1\n' | ui_select_language > "$TMP/selector-en.txt"
grep -Fxq 'Select language / Выберите язык' "$TMP/selector-en.txt"
grep -Fxq '[1] English' "$TMP/selector-en.txt"
grep -Fxq '[2] Русский' "$TMP/selector-en.txt"
[[ "$(<"$TWEBPROXY_LANGUAGE_FILE")" == en ]]
UI_LANGUAGE=ru; ui_language_load; [[ "$UI_LANGUAGE" == en ]]
ui_language_store ru; [[ "$(<"$TWEBPROXY_LANGUAGE_FILE")" == ru ]]
ui_language_store en; [[ "$(<"$TWEBPROXY_LANGUAGE_FILE")" == en ]]
ui_language_store ru; [[ "$(<"$TWEBPROXY_LANGUAGE_FILE")" == ru ]]

# Unsafe language-file symlink is never replaced.
ln -sfn /nonexistent/target "$TMP/dangling-language"
LANGUAGE_FILE="$TMP/dangling-language"
before="$(readlink "$LANGUAGE_FILE")"
if ui_language_store en; then fail 'dangling language symlink accepted'; fi
[[ -L "$LANGUAGE_FILE" && "$(readlink "$LANGUAGE_FILE")" == "$before" ]]
LANGUAGE_FILE="$TWEBPROXY_LANGUAGE_FILE"

# Deterministic typed fixtures for EN/RU dashboard, compact status/statistics.
build_overview() {
  tcore_reset overview global
  TCORE_DATA_JSON='{"hostnames":2,"profiles":3}'
  tcore_add_check inventory.hostnames OK info global state 2 '>=1' 'Configured hostnames' none
  tcore_add_check relay.service.active OK critical hostname:alpha.example systemd active active 'Relay active' none
  tcore_add_check frontend.service.active OK critical hostname:alpha.example systemd active active 'Frontend active' none
  tcore_add_check tls.mode OK info hostname:alpha.example configuration caddy configured 'TLS mode' none
  tcore_add_check profiles.present OK critical hostname:alpha.example state 2 '>=1' 'Profiles present' none
  tcore_add_check profile.backend.service.active OK critical profile:alpha.example/a systemd active active 'Backend active' none
  tcore_add_check relay.service.active ERROR critical hostname:beta.example systemd failed active 'Relay failed' none
  tcore_add_check frontend.service.active OK critical hostname:beta.example systemd active active 'Frontend active' none
  tcore_add_check tls.mode OK info hostname:beta.example configuration nginx-le configured 'TLS mode' none
  tcore_add_check profiles.present OK critical hostname:beta.example state 1 '>=1' 'Profiles present' none
  tcore_finalize
}
build_status() {
  tcore_reset status hostname:alpha.example
  tcore_add_check relay.service.active OK critical hostname:alpha.example systemd active active 'Relay active' none
  tcore_add_check tls.public.certificate.validity WARNING warning hostname:alpha.example tls 9 '>=15' 'Renewal window close' none
  tcore_finalize
}
build_stats() {
  tcore_reset stats hostname:alpha.example
  tcore_add_check statistics.relay.live OK info hostname:alpha.example relay available available 'Relay responded' none '' $'twebproxy_sessions 3\ntwebproxy_streams 5\ntwebproxy_bytes_total 4096'
  tcore_add_check statistics.profile.live OK info profile:alpha.example/a stats available available 'Profile responded' none '' $'connections\t2'
  tcore_add_check statistics.history DISABLED info hostname:alpha.example unavailable unavailable unavailable 'History unavailable' none
  tcore_finalize
}

UI_LANGUAGE=en
tcore_reset overview global
TCORE_DATA_JSON='{"hostnames":0,"profiles":0}'
tcore_finalize
tui_render_dashboard > "$TMP/dashboard-zero.txt"
grep -q 'No configured WEB Proxy instances' "$TMP/dashboard-zero.txt"

for lang in en ru; do
  UI_LANGUAGE="$lang"
  build_overview; tui_render_dashboard > "$TMP/dashboard-$lang-80.txt"
  COLUMNS=42; tui_render_dashboard > "$TMP/dashboard-$lang-42.txt"; COLUMNS=80
  build_status; tui_render_status alpha.example > "$TMP/status-$lang.txt"
  build_stats; tui_render_statistics alpha.example > "$TMP/statistics-$lang.txt"
  tui_render_settings > "$TMP/settings-$lang.txt"
  for f in "$TMP/dashboard-$lang-80.txt" "$TMP/dashboard-$lang-42.txt" "$TMP/status-$lang.txt" "$TMP/statistics-$lang.txt" "$TMP/settings-$lang.txt"; do
    ! grep -q $'\033' "$f" || fail "ANSI present in $f"
  done
  assert_width "$TMP/dashboard-$lang-42.txt" 42
done

grep -q '^Language.*English' "$TMP/dashboard-en-80.txt"
grep -q '^Язык.*Русский' "$TMP/dashboard-ru-80.txt"
grep -q '^TWebProxy Status' "$TMP/status-en.txt"
grep -q '^Статус TWebProxy' "$TMP/status-ru.txt"
grep -q '^TWebProxy Statistics' "$TMP/statistics-en.txt"
grep -q '^Статистика TWebProxy' "$TMP/statistics-ru.txt"
grep -q '^Relay sessions.*3$' "$TMP/statistics-en.txt"
grep -q '^Relay streams.*5$' "$TMP/statistics-en.txt"
grep -q '^Relay bytes total.*4.0 KiB (4096 B)$' "$TMP/statistics-en.txt"
grep -q '^Backend connections.*2$' "$TMP/statistics-en.txt"
grep -q '^Сессии relay.*3$' "$TMP/statistics-ru.txt"
grep -q '^Потоки relay.*5$' "$TMP/statistics-ru.txt"
grep -q '^Всего байтов relay.*4.0 KiB (4096 B)$' "$TMP/statistics-ru.txt"
grep -q '^Соединения backend.*2$' "$TMP/statistics-ru.txt"
for file in "$TMP/dashboard-en-80.txt" "$TMP/status-en.txt" "$TMP/statistics-en.txt" "$TMP/settings-en.txt"; do
  ! ui_contains_cyrillic "$(<"$file")" || fail 'Cyrillic prose leaked into English compact UI'
done
if LC_ALL=C grep -Eq '(^|[^A-Za-z])(live|legacy|lifecycle|Audit|renewal|Offline|helper|workflow|update-backup)([^A-Za-z]|$)' \
  "$TMP/dashboard-ru-80.txt" "$TMP/status-ru.txt" "$TMP/statistics-ru.txt" "$TMP/settings-ru.txt"; then
  fail 'ordinary English prose leaked into Russian compact UI'
fi

# Main navigation has six task groups, explicit zero Exit, no Anti-DPI action.
body="$(declare -f menu)"
for fn in menu_web_proxy menu_profiles menu_status_statistics menu_maintenance menu_diagnostics menu_settings; do
  [[ "$body" == *"$fn"* ]] || fail "main route missing: $fn"
done
[[ "$body" != *menu_anti_dpi* ]]
for fn in menu_web_proxy menu_profiles menu_status_statistics menu_maintenance menu_diagnostics menu_settings menu_logs menu_certificates menu_update_recovery; do
  fn_body="$(declare -f "$fn")"
  [[ "$fn_body" == *'0)'* && "$fn_body" == *return* ]] || fail "$fn lacks consistent zero Back"
done
UI_LANGUAGE=en
printf 'x\n0\n' | menu_choose Test Back One > "$TMP/menu-choice.txt" 2> "$TMP/menu-choice.err"
[[ "$(<"$TMP/menu-choice.txt")" == 0 ]]
grep -q 'Enter a number' "$TMP/menu-choice.err"

# Execute each visible main-menu route and then Exit. Stubs make the test
# read-only while proving the case mapping, one-level return and zero semantics.
for route in \
  '1:menu_web_proxy' '2:menu_profiles' '3:menu_status_statistics' \
  '4:menu_maintenance' '5:menu_diagnostics' '6:menu_settings'; do
  number="${route%%:*}"; function_name="${route#*:}"
  (
    need_root() { :; }; need_systemd() { :; }; core_installed() { return 0; }; clear() { :; }
    collect_overview() { build_overview; }
    menu_web_proxy() { echo ROUTE:menu_web_proxy; }
    menu_profiles() { echo ROUTE:menu_profiles; }
    menu_status_statistics() { echo ROUTE:menu_status_statistics; }
    menu_maintenance() { echo ROUTE:menu_maintenance; }
    menu_diagnostics() { echo ROUTE:menu_diagnostics; }
    menu_settings() { echo ROUTE:menu_settings; }
    export TWEBPROXY_UI_LANGUAGE=en
    printf '%s\n0\n' "$number" | menu
  ) > "$TMP/route-$number.txt" 2>&1
  grep -Fxq "ROUTE:$function_name" "$TMP/route-$number.txt" || fail "route $number did not reach $function_name"
done

# True absence is the only state that triggers the first-install selector.
install_body="$(declare -f core_install_cmd)"
[[ "$install_body" == *ui_language_ensure_interactive_install* ]]
for fn in repair_instance_cmd manager_update_cmd update_cmd; do
  [[ "$(declare -f "$fn")" != *ui_select_language* ]] || fail "$fn prompts for language"
done

# NO_COLOR is accepted in main(), while machine formats stay canonical.
grep -q 'NO_COLOR' "$SCRIPT"
grep -q 'OUTPUT_MODE.*human' "$SCRIPT"

if [[ -n "${TWEBPROXY_CAPTURE_DIR:-}" ]]; then
  install -d -m 0755 "$TWEBPROXY_CAPTURE_DIR"
  cp "$TMP"/selector-en.txt "$TWEBPROXY_CAPTURE_DIR/"
  cp "$TMP"/dashboard-*.txt "$TMP"/status-*.txt "$TMP"/statistics-*.txt "$TMP"/settings-*.txt "$TWEBPROXY_CAPTURE_DIR/"
fi

printf 'stage-x-fixui-fixture: PASS\n'
