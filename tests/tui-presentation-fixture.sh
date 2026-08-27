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
UI_LANGUAGE=en
export COLUMNS=42

FIXTURE_SECRET="0123456789abcdef0123456789abcdef"
list_hosts_array() { printf 'fixture.example\n'; }
list_profiles_array() { [[ "${1:-}" == fixture.example ]] && printf 'default\n'; }

assert_no_ansi() { ! grep -q $'\033' "$1"; }
assert_no_secret() { ! grep -Fq "$FIXTURE_SECRET" "$1"; }
assert_width() {
  local max
  max="$(wc -L < "$1")"
  (( max <= COLUMNS )) || { printf 'line width %s exceeds %s\n' "$max" "$COLUMNS" >&2; return 1; }
}

# Stable, non-colour state vocabulary; malformed input has a safe fallback.
[[ "$(tui_state_text OK)" == '[OK]' ]]
[[ "$(tui_state_text WARNING)" == '[WARNING]' ]]
[[ "$(tui_state_text ERROR)" == '[ERROR]' ]]
[[ "$(tui_state_text DISABLED)" == '[DISABLED]' ]]
[[ "$(tui_state_text UNKNOWN)" == '[UNKNOWN]' ]]
[[ "$(tui_state_text BROKEN)" == '[UNKNOWN]' ]]

# Human-readable conversions are deterministic and never fabricate a value.
[[ "$(tui_human_bytes 0)" == '0 B' ]]
[[ "$(tui_human_bytes 1536)" == '1.5 KiB' ]]
[[ "$(tui_human_bytes invalid)" == 'Unavailable' ]]
[[ "$(tui_human_duration 65)" == '1m 5s' ]]
[[ "$(tui_human_duration 90061)" == '1d 1h' ]]
[[ "$(tui_human_duration invalid)" == 'Unavailable' ]]
[[ "$(tui_live_scalar $'twebproxy_sessions 3\n' twebproxy_sessions)" == 3 ]]
if tui_live_scalar $'twebproxy_sessions 3\ntwebproxy_sessions 4' twebproxy_sessions >/dev/null; then
  printf 'duplicate live metric was accepted\n' >&2; exit 1
fi
if tui_live_scalar 'twebproxy_sessions{profile="x"} 3' twebproxy_sessions >/dev/null; then
  printf 'labelled/ambiguous live metric was accepted\n' >&2; exit 1
fi

# Dashboard: compact typed data, narrow-terminal wrapping and no secret-bearing
# evidence. The information-only Anti-DPI item is intentionally not a menu tile.
tcore_reset overview global
TCORE_DATA_JSON='{"hostnames":1,"profiles":1}'
tcore_add_check inventory.hostnames OK info global state 1 '>=1' 'Configured hostnames' none
tcore_add_check relay.service.active OK critical hostname:fixture.example systemd active active 'Relay service is active' none
tcore_add_check frontend.service.active WARNING critical hostname:fixture.example systemd degraded active 'Frontend needs attention' none
tcore_add_check tls.mode OK info hostname:fixture.example configuration caddy configured 'TLS lifecycle mode' none
tcore_add_check profiles.present OK critical hostname:fixture.example state 1 '>=1' 'Profiles are configured' none
tcore_add_check profile.backend.service.active ERROR critical profile:fixture.example/default systemd inactive active 'Backend is not active' none
tcore_add_check profile.carrier OK info profile:fixture.example/default configuration https configured 'Configured carrier' none
tcore_add_check anti_dpi.mode DISABLED info global configuration STOCK STOCK 'STOCK mode; no experimental mechanism' none
tcore_add_check evidence.redaction OK info global systemd configured configured 'Secret evidence is redacted' none '' "-S $FIXTURE_SECRET"
tcore_finalize
tui_render_dashboard > "$TMP/dashboard.txt"
grep -q '^TWebProxy Manager v0.2.8-dpi-beta$' "$TMP/dashboard.txt"
grep -q '^Language$' "$TMP/dashboard.txt"; grep -q '^  English$' "$TMP/dashboard.txt"
grep -q '^fixture.example' "$TMP/dashboard.txt"; grep -q '\[ERROR\]' "$TMP/dashboard.txt"
! grep -q 'Anti-DPI' "$TMP/dashboard.txt"
assert_no_ansi "$TMP/dashboard.txt"
assert_no_secret "$TMP/dashboard.txt"
assert_width "$TMP/dashboard.txt"
COLUMNS=80 tui_render_dashboard > "$TMP/dashboard-80.txt"

# Unknown/malformed typed state cannot masquerade as success.
TCORE_STATUSES[0]=MALFORMED
tui_render_record 0 > "$TMP/malformed.txt"
grep -q '^\[UNKNOWN\]' "$TMP/malformed.txt"

# Profiles never display a secret value; an empty set is a first-class error.
tcore_reset profile-list hostname:fixture.example
tcore_add_check profiles.present OK critical hostname:fixture.example state 1 '>=1' 'Profiles configured' none
tcore_add_check profile.carrier OK info profile:fixture.example/default configuration https configured 'Carrier' none
tcore_add_check profile.backend.service.active OK critical profile:fixture.example/default systemd active active 'Backend active' none
tcore_add_check profile.backend.port OK info profile:fixture.example/default configuration 23980 configured 'Backend port' none
tcore_add_check profile.stats.port OK info profile:fixture.example/default configuration 23981 configured 'Stats port' none
tcore_add_check profile.secret.configured OK critical profile:fixture.example/default configuration configured configured 'Secret configured and hidden' none '' "$FIXTURE_SECRET"
tcore_finalize
tui_render_profiles fixture.example > "$TMP/profiles.txt"
grep -q '^Secret' "$TMP/profiles.txt"
grep -q '\[OK\] Hidden' "$TMP/profiles.txt"
assert_no_secret "$TMP/profiles.txt"

list_profiles_array() { :; }
tcore_reset profile-list hostname:fixture.example
tcore_add_check profiles.present ERROR critical hostname:fixture.example state 0 '>=1' 'No profiles are configured' none
tcore_finalize
tui_render_profiles fixture.example > "$TMP/profiles-empty.txt"
grep -q '\[ERROR\].*No profiles' "$TMP/profiles-empty.txt"

# Statistics distinguish a verified source from unavailable metrics/history.
tcore_reset stats hostname:fixture.example
tcore_add_check statistics.relay.live OK info hostname:fixture.example relay-metrics available available 'Relay source responded' none '' $'twebproxy_sessions 7\ntwebproxy_streams 9\ntwebproxy_bytes_total 1536'
tcore_add_check statistics.profile.live OK info profile:fixture.example/default mtproxy-stats available available 'Profile source responded' none '' $'connections\t4'
tcore_add_check statistics.history DISABLED info hostname:fixture.example unavailable unavailable unavailable 'History is unavailable' none
tcore_add_check statistics.latency UNKNOWN warning hostname:fixture.example unavailable unavailable unavailable 'Latency source unavailable' none
tcore_finalize
tui_render_statistics fixture.example > "$TMP/statistics.txt"
grep -q '^TWebProxy Statistics · fixture.example$' "$TMP/statistics.txt"
grep -q '^Relay sessions$' "$TMP/statistics.txt"; grep -q '^  7$' "$TMP/statistics.txt"
grep -q '^Relay streams$' "$TMP/statistics.txt"; grep -q '^  9$' "$TMP/statistics.txt"
grep -q '^Relay bytes total$' "$TMP/statistics.txt"; grep -q '^  1.5 KiB (1536 B)$' "$TMP/statistics.txt"
grep -q '^Backend connections$' "$TMP/statistics.txt"; grep -q '^  4$' "$TMP/statistics.txt"
grep -q '^Relay metrics$' "$TMP/statistics.txt"; grep -q '^  \[OK\]$' "$TMP/statistics.txt"
grep -q '^History$' "$TMP/statistics.txt"; grep -q '^  Unavailable$' "$TMP/statistics.txt"
! grep -q 'Latency source' "$TMP/statistics.txt"
! grep -Eqi 'users|bandwidth|24.?hour' "$TMP/statistics.txt"

# TLS lifecycle states remain distinct and readable without colour.
tcore_reset audit hostname:fixture.example
tcore_add_check tls.public.certificate.validity WARNING warning hostname:fixture.example tls 10 '>=15 days' 'Certificate renewal window is close' none
tcore_add_check tls.manager.active OK critical hostname:fixture.example systemd active active 'Caddy TLS manager is active' none
tcore_add_check https.public.strict ERROR critical hostname:fixture.example https fail pass 'Strict public TLS check failed' none
tcore_finalize
tui_render_tls fixture.example > "$TMP/tls.txt"
grep -q '\[WARNING\].*tls.public.certificate.validity' "$TMP/tls.txt"
grep -q '\[OK\].*tls.manager.active' "$TMP/tls.txt"
grep -q '\[ERROR\].*https.public.strict' "$TMP/tls.txt"

tui_render_status fixture.example all > "$TMP/status.txt"
grep -q '^TWebProxy Status · fixture.example$' "$TMP/status.txt"
grep -q 'Detailed evidence is available' "$TMP/status.txt"
grep -q '\[ERROR\].*https.public.strict' "$TMP/status.txt"

tui_render_update_recovery > "$TMP/update-recovery.txt"
tui_render_settings > "$TMP/settings.txt"
grep -q 'Existing SHA256SUMS-verified workflow' "$TMP/update-recovery.txt"
legacy_signature_wording="signed-by-${sha_label:-SHA}"
! grep -q "$legacy_signature_wording" "$TMP/update-recovery.txt"
grep -q '^Local update backups' "$TMP/update-recovery.txt"
grep -q '^Offline rollback helper' "$TMP/update-recovery.txt"
! grep -Eq 'LKG snapshots|Independent recovery|snapshot ID|Explicit LKG|entrypoint is available|Local recovery foundation' "$TMP/update-recovery.txt"
grep -q 'List local update backups' "$SCRIPT"
grep -q 'Rollback to latest verified backup' "$SCRIPT"

# Navigation and capability boundaries are present; Anti-DPI is absent from the UI.
for label in 'Proxies / Instances' 'Profiles' 'Status & Statistics' 'Maintenance' 'Diagnostics & Logs' 'Settings'; do
  grep -q "$label" "$SCRIPT"
done
menu_body="$(declare -f menu)"
[[ "$menu_body" != *'menu_anti_dpi'* && "$menu_body" != *'Anti-DPI'* ]]

if [[ -n "${TWEBPROXY_CAPTURE_DIR:-}" ]]; then
  install -d -m 0755 "$TWEBPROXY_CAPTURE_DIR"
  cp "$TMP/dashboard-80.txt" "$TWEBPROXY_CAPTURE_DIR/tui-dashboard.txt"
  cp "$TMP/dashboard.txt" "$TWEBPROXY_CAPTURE_DIR/tui-dashboard-narrow-42.txt"
  cp "$TMP/profiles.txt" "$TWEBPROXY_CAPTURE_DIR/tui-profiles.txt"
  cp "$TMP/statistics.txt" "$TWEBPROXY_CAPTURE_DIR/tui-statistics.txt"
  cp "$TMP/tls.txt" "$TWEBPROXY_CAPTURE_DIR/tui-tls.txt"
  cp "$TMP/status.txt" "$TWEBPROXY_CAPTURE_DIR/tui-status.txt"
  cp "$TMP/update-recovery.txt" "$TWEBPROXY_CAPTURE_DIR/tui-update-recovery.txt"
  cp "$TMP/settings.txt" "$TWEBPROXY_CAPTURE_DIR/tui-settings-non-ansi.txt"
fi

printf 'tui-presentation-fixture: PASS\n'
