#!/usr/bin/env bash
# R3 regression: `nft -f` may fail on the client side after the kernel already
# committed the batch (for example when `timeout` kills nft). The helper must
# never claim success, must say what the kernel actually holds, and must
# converge like its other failure paths: previous verified table restored, or -
# when no table existed - the new isolation retained. Behavioral model only;
# the real timing window needs a disposable VM.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-stageb-apply.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/tests/stageb/backend-harness.sh"
backend_harness
pass=0; fail=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
helper() { "$BF_TEST_HELPER" > "$TMP/output" 2>&1; }
says() { grep -q -- "$1" "$TMP/output"; }
live_ports() { sed -n 's/.*dport { \([^}]*\) } drop/\1/p' "$TMP/live" | tr -d ' '; }
failed() {
  if helper; then bad "$1_reports_failure"; else ok "$1_reports_failure"; fi
  sed 's/^/  | /' "$TMP/output"
}
# Each case starts from the model kernel holding exactly the given canonical file.
start_from() { rm -f "$TMP"/fail-*; if [[ -n "$1" ]]; then cp "$1" "$TMP/live"; else rm -f "$TMP/live"; fi; }

backend_state a 23980 28980
rebuild() { (rebuild_firewall) > "$TMP/output" 2>&1; }
check setup_first_install rebuild
cp "$FIREWALL_FILE" "$TMP/canonical.a"

# 1. Committed, then reported failure, with a previous table: restore it.
backend_state b 23981 28981
touch "$TMP/fail-after-commit"
failed committed_previous
check committed_previous_named says 'after the kernel committed the new rules'
check committed_previous_restored says 'previous live isolation restored'
check committed_previous_live_is_previous test "$(live_ports)" = 23980,28980
check committed_previous_canonical_unchanged cmp -s "$TMP/canonical.a" "$FIREWALL_FILE"

# 2. Rejected batch: kernel unchanged, and the message says so.
start_from "$TMP/canonical.a"
touch "$TMP/fail-apply"
failed rejected_previous
check rejected_previous_named says 'previous live isolation unchanged'
check rejected_previous_live_unchanged test "$(live_ports)" = 23980,28980
check rejected_previous_canonical_unchanged cmp -s "$TMP/canonical.a" "$FIREWALL_FILE"

# 3. Committed, then failure, and the restore also fails: explicit RESTORE FAILED.
start_from "$TMP/canonical.a"
touch "$TMP/fail-after-commit" "$TMP/fail-rollback"
failed committed_restore_failed
check committed_restore_failed_named says 'RESTORE FAILED'
check committed_restore_failed_canonical_unchanged cmp -s "$TMP/canonical.a" "$FIREWALL_FILE"
rm -f "$TMP"/fail-*
check committed_restore_failed_converges_next_run helper
check committed_restore_failed_full_set test "$(live_ports)" = 23980,23981,28980,28981
cp "$FIREWALL_FILE" "$TMP/canonical.ab"

# 4. Failure, then the live table cannot be read: unknown, never success.
rm "$BACKENDS_DIR/b.env"
start_from "$TMP/canonical.ab"
touch "$TMP/fail-after-commit" "$TMP/fail-post-verify"
failed unknown_state
check unknown_state_named says 'state is unknown'
check unknown_state_restore_failed says 'RESTORE FAILED'
check unknown_state_canonical_unchanged cmp -s "$TMP/canonical.ab" "$FIREWALL_FILE"

# 5. First install, committed then failure: retain the new isolation.
start_from ""; rm -f "$FIREWALL_FILE"
touch "$TMP/fail-after-commit"
failed committed_first_install
check committed_first_install_named says 'after the kernel committed the new rules'
check committed_first_install_retained says 'retaining applied isolation'
check committed_first_install_isolation_kept test "$(live_ports)" = 23980,28980
check committed_first_install_not_published test ! -e "$FIREWALL_FILE"

# 6. First install, rejected batch: nothing installed, and the message says so.
start_from ""
touch "$TMP/fail-apply"
failed rejected_first_install
check rejected_first_install_named says 'no table was installed'
check rejected_first_install_no_table test ! -e "$TMP/live"
check rejected_first_install_not_published test ! -e "$FIREWALL_FILE"

printf 'stageb-apply-ambiguity: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
