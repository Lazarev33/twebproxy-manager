#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-stageb.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/tests/stageb/backend-harness.sh"
backend_harness
pass=0; fail=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
run() { (rebuild_firewall) > "$TMP/output" 2>&1; }
unchanged() { cmp -s "$TMP/old.file" "$FIREWALL_FILE" && cmp -s "$TMP/old.live" "$TMP/live"; }
save() { cp "$FIREWALL_FILE" "$TMP/old.file"; cp "$TMP/live" "$TMP/old.live"; }
negative() { if run; then bad "$1"; else ok "$1"; fi; }
backend_state a 23980 28980
printf 'ExecStop=-/usr/sbin/nft delete table inet twebproxy_backend\n' > "$SYSTEMD_DIR/twebproxy-firewall.service"
check first_install run
if [[ ! -f "$TMP/live" ]]; then cat "$TMP/output"; exit 1; fi
check candidate_complete cmp -s "$TMP/live" "$FIREWALL_FILE"
check canonical_permissions test "$(stat -c '%a:%u:%g' "$FIREWALL_FILE")" = 600:0:0
save
backend_state b 23981 28981
touch "$TMP/fail-check"
negative invalid_candidate_failure
check invalid_preserves_file_and_live unchanged
rm "$TMP/fail-check"
touch "$TMP/fail-apply"
negative atomic_apply_failure
check failed_apply_preserves_isolation unchanged
touch "$TMP/fail-publish"
negative failed_publish_failure
check failed_publish_restores_live_and_keeps_file unchanged
rm "$TMP/fail-publish"
touch "$TMP/fail-post-verify"
negative failed_live_verification
check failed_verification_restores_previous unchanged
# A partial write + failed renderer must be checked even with errexit suppressed.
printf() {
  if [[ -f "$BF_TEST_ROOT/fail-write" &&
       ( "${1:-}" == 'table inet twebproxy_backend {'* || "${2:-}" == 'table inet twebproxy_backend {'* ) ]]; then
    builtin printf 'table inet twebproxy_backend {\n'; return 1
  fi
  builtin printf "$@"
}
export -f printf
touch "$TMP/fail-write"
negative failed_partial_candidate_write
check partial_write_not_published unchanged
rm "$TMP/fail-write"
unset -f printf
check multiple_backends run
check all_backend_ports grep -q '23980,23981,28980,28981' "$FIREWALL_FILE"
save
check idempotent_rebuild run
check idempotent_state unchanged
check reload_without_restart bash -c '! grep -q "^restart " "$1"' _ "$TMP/systemctl.calls"
check no_separate_live_delete bash -c '! grep -q "^delete table " "$1"' _ "$TMP/nft.calls"
check unit_has_no_destructive_stop bash -c '! grep -q "^ExecStop=" "$1"' _ "$SYSTEMD_DIR/twebproxy-firewall.service"
touch "$TMP/fail-systemctl"
negative service_failure_propagated
check failed_service_keeps_state unchanged
rm "$TMP/fail-systemctl"
for action in daemon-reload enable reload is-active start; do
  [[ "$action" != start ]] || rm -f "$TMP/active"
  printf '%s\n' "$action" > "$TMP/fail-systemctl"
  negative "service_${action}_failure_propagated"
  check "service_${action}_failure_preserves_state" unchanged
  rm "$TMP/fail-systemctl"
done
printf 'MTPROXY_CLIENT_PORT=23982\n' > "$BACKENDS_DIR/broken.env"
negative damaged_backend_fails_closed
check damaged_backend_preserves_old unchanged
rm "$BACKENDS_DIR/broken.env" "$BACKENDS_DIR/b.env"
check removing_one_backend run
check other_backend_retained grep -q '23980,28980' "$FIREWALL_FILE"
rm "$BACKENDS_DIR/a.env"
check removing_last_backend run
check empty_has_input_chain grep -q 'type filter hook input priority -5; policy accept;' "$FIREWALL_FILE"
check empty_has_no_drop bash -c 'test -f "$1" && ! grep -q "dport" "$1"' _ "$FIREWALL_FILE"
# Reboot does not replay a stale canonical file: the installed helper reads state.
backend_state c 24000 29000
check installed_helper_reconstructs "$BF_TEST_HELPER"
check installed_helper_new_ports grep -q '24000,29000' "$FIREWALL_FILE"
save
backend_state d 24001 29001
touch "$TMP/interrupt-before-publish"
if "$BF_TEST_HELPER" >"$TMP/interrupted" 2>&1; then bad interrupted_operation_not_success; else ok interrupted_operation_not_success; fi
check interrupted_file_unchanged cmp -s "$TMP/old.file" "$FIREWALL_FILE"
check next_invocation_converges "$BF_TEST_HELPER"
check convergence_full_state grep -q '24000,24001,29000,29001' "$FIREWALL_FILE"
# Absent old table + publication failure retains new isolation, reports failure.
rm "$TMP/live"
touch "$TMP/fail-publish"
if "$BF_TEST_HELPER" >"$TMP/output" 2>&1; then bad absent_publish_not_success; else ok absent_publish_not_success; fi
check absent_publish_retains_new_isolation test -s "$TMP/live"
rm "$TMP/fail-publish"
printf 'stageb-model: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
