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
ui_i18n_init

fail() { printf 'localization-static-audit: FAIL: %s\n' "$*" >&2; exit 1; }
(( ${#UI_EN[@]} >= 100 )) || fail 'catalog unexpectedly small'
[[ ${#UI_EN[@]} -eq ${#UI_RU[@]} ]] || fail 'catalog language counts differ'
for key in "${!UI_EN[@]}"; do
  [[ -n "${UI_EN[$key]}" && -n "${UI_RU[$key]}" ]] || fail "empty catalog value: $key"
done

UI_LANGUAGE=en; usage > "$TMP/help-en.txt"
UI_LANGUAGE=ru; usage > "$TMP/help-ru.txt"
if ui_contains_cyrillic "$(<"$TMP/help-en.txt")"; then fail 'Cyrillic leaked into English help'; fi
ui_contains_cyrillic "$(<"$TMP/help-ru.txt")" || fail 'Russian help lacks Russian prose'

for key in "${!UI_RU[@]}"; do
  if LC_ALL=C grep -Eq '(^|[^A-Za-z])(live|legacy|lifecycle|Audit|renewal|Offline|helper|workflow|update-backup)([^A-Za-z]|$)' <<< "${UI_RU[$key]}"; then
    fail "ordinary English prose in Russian catalog: $key=${UI_RU[$key]}"
  fi
done

UI_LANGUAGE=en
for sample in \
  'Некорректный порт.' \
  'Проверяю базовые зависимости...' \
  'Порт 18080 уже занят или зарегистрирован TWebProxy.' \
  'MTProxy backend alpha/default не стал ready.' \
  'Инстанс alpha.example создан и прошёл isolation audit.'; do
  translated="$(ui_localize_legacy "$sample")"
  if ui_contains_cyrillic "$translated"; then fail "legacy adapter leaked Cyrillic: $sample"; fi
  [[ "$translated" != UNTRANSLATED_MESSAGE_* ]] || fail "reachable message used emergency fallback: $sample"
done

for locale in C POSIX C.UTF-8; do
  LC_ALL="$locale" ui_contains_cyrillic 'Русский текст' || fail "$locale failed to detect Cyrillic"
  if LC_ALL="$locale" ui_contains_cyrillic 'English text /var/lib/twebproxy 443'; then
    fail "$locale reported false Cyrillic"
  fi
done

# Audit every literal passed to the legacy presentation wrappers. Dynamic
# values are replaced with a neutral marker, then both language paths are
# required to avoid the emergency fallback / forbidden mixed prose.
audited=0
while IFS= read -r sample; do
  sample="$(sed -E 's/\$\([^)]*\)/VALUE/g; s/\$\{[^}]*\}/VALUE/g; s/\$[A-Za-z_][A-Za-z0-9_]*/VALUE/g' <<< "$sample")"
  UI_LANGUAGE=en
  translated="$(ui_localize_legacy "$sample")"
  [[ "$translated" != UNTRANSLATED_MESSAGE_* ]] || fail "call-site uses emergency fallback: $sample"
  ! ui_contains_cyrillic "$translated" || fail "call-site leaks Cyrillic: $sample"
  UI_LANGUAGE=ru
  translated="$(ui_localize_legacy "$sample")"
  scan="$(sed -E 's#(/[A-Za-z0-9._-]+)+#PATH#g' <<< "$translated")"
  if LC_ALL=C grep -Eq '(^|[^A-Za-z])(live|legacy|lifecycle|Audit|renewal|Offline|helper|workflow|update-backup)([^A-Za-z]|$)' <<< "$scan"; then
    fail "call-site has ordinary English prose in Russian: $translated"
  fi
  audited=$((audited+1))
done < <({
  sed -nE 's/.*\b(log|ok|warn|die|ask|yesno|choose)[[:space:]]+"([^"\\]*(\\.[^"\\]*)*)".*/\2/p' "$SCRIPT"
  sed -nE "s/.*\\b(log|ok|warn|die|ask|yesno|choose)[[:space:]]+'([^']*)'.*/\\2/p" "$SCRIPT"
} | sort -u)
(( audited >= 200 )) || fail "too few presentation call-sites audited: $audited"

# Language decisions are centralized; menu bodies resolve catalog keys rather
# than open-coding per-language branches.
for fn in menu menu_web_proxy menu_profiles menu_status_statistics menu_maintenance menu_diagnostics menu_settings; do
  body="$(declare -f "$fn")"
  [[ "$body" == *ui_msg* || "$fn" == menu_status_statistics ]] || fail "$fn bypasses the catalog"
done
[[ "$(declare -f menu)" != *menu_anti_dpi* ]] || fail 'Anti-DPI action returned to main UI'

grep -q 'LANGUAGE_FILE=.*ui-language' "$SCRIPT"
grep -q 'NO_COLOR' "$SCRIPT"
grep -q 'status \[hostname\] \[--verbose\]' "$SCRIPT"
grep -q 'stats \[hostname\] \[--verbose\]' "$SCRIPT"

printf 'localization-static-audit: PASS (%s bilingual keys; %s legacy call-sites)\n' "${#UI_EN[@]}" "$audited"
