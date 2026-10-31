#!/usr/bin/env bash
# F1 regression (v0.2.12): rebuild_firewall ran `install -d -m 0700` on the
# existing LIBEXEC_DIR. twebproxy-mtproxy@ (User=mtproxy) and the nfqws worker
# (User=twebproxy-dpi) execute/read from it, so every later backend start failed.
#
# Invariants: rebuild (start and reload path) leaves LIBEXEC_DIR root:root 0755
# and every other entry byte- and mode-identical; an unprivileged account can
# traverse it and run a service entrypoint; BASE_DIR stays private; a v0.2.12-
# damaged 0700 directory is restored; a symlinked directory is refused without
# touching its target; a missing parent is created traversable under umask 077.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-stageb-libexec.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/tests/stageb/backend-harness.sh"
backend_harness
pass=0; fail=0; not_executed=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
run() { (rebuild_firewall) > "$TMP/output" 2>&1; }
mode() { stat -c '%a:%u:%g' -- "$1"; }
# Everything except the helper rebuild_firewall itself owns.
snapshot() {
  (cd "$LIBEXEC_DIR" && find . -mindepth 1 ! -name apply-firewall ! -name firewall-guard ! -name backend-start-check -printf '%p %m %U:%G %s\n' | sort &&
    find . -mindepth 1 -type f ! -name apply-firewall ! -name firewall-guard ! -name backend-start-check -exec sha256sum {} + | sort)
}
# Production-shaped content: entrypoints and the nfqws checksum file.
cp /bin/true "$LIBEXEC_DIR/mtproto-proxy"
printf '#!/bin/sh\nexec ./libexec/mtproto-proxy\n' > "$LIBEXEC_DIR/run-mtproxy"
printf '#!/bin/sh\nexit 0\n' > "$LIBEXEC_DIR/refresh-mtproxy-config"
cp /bin/true "$LIBEXEC_DIR/twebproxy-nfqws"
# Production writes "<sha>  <absolute binary path>"; relative to $TMP here.
(cd "$TMP" && sha256sum ./libexec/twebproxy-nfqws > ./libexec/twebproxy-nfqws.sha256)
chmod 0755 "$LIBEXEC_DIR/mtproto-proxy" "$LIBEXEC_DIR/run-mtproxy" "$LIBEXEC_DIR/refresh-mtproxy-config" "$LIBEXEC_DIR/twebproxy-nfqws"
chmod 0644 "$LIBEXEC_DIR/twebproxy-nfqws.sha256"
backend_state a 23980 28980
snapshot > "$TMP/before"

unprivileged() { # run "$@" as uid/gid 65534 with cwd $TMP (only LIBEXEC_DIR is on the path walk)
  (cd "$TMP" && setpriv --reuid=65534 --regid=65534 --clear-groups "$@") >/dev/null 2>&1
}
can_test_unprivileged=0
if [[ $EUID -eq 0 ]] && command -v setpriv >/dev/null; then can_test_unprivileged=1; chmod 0711 "$TMP"; fi
service_checks() { # $1 = phase label
  if (( ! can_test_unprivileged )); then
    printf 'NOT_EXECUTED %s unprivileged checks: needs root and setpriv\n' "$1"; not_executed=$((not_executed+1)); return
  fi
  check "$1_mtproxy_account_runs_entrypoint" unprivileged ./libexec/run-mtproxy
  check "$1_dpi_account_reads_checksum" unprivileged sha256sum --check --status ./libexec/twebproxy-nfqws.sha256
  check "$1_backend_state_not_readable" bash -c '! (cd "$1" && setpriv --reuid=65534 --regid=65534 --clear-groups cat ./etc/backends/a.env) >/dev/null 2>&1' _ "$TMP"
}

service_checks precondition
check start_rebuild_succeeds run
check start_libexec_root_0755 test "$(mode "$LIBEXEC_DIR")" = 755:0:0
snapshot > "$TMP/after-start"
check start_other_entries_unchanged cmp -s "$TMP/before" "$TMP/after-start"
check start_helper_root_0755 test "$(mode "$LIBEXEC_DIR/apply-firewall")" = 755:0:0
check start_base_dir_private test "$(stat -c '%a' "$BASE_DIR")" = 700
service_checks after_start
check reload_rebuild_succeeds run
check reload_used_not_restart grep -q '^reload twebproxy-firewall.service$' "$TMP/systemctl.calls"
check reload_libexec_root_0755 test "$(mode "$LIBEXEC_DIR")" = 755:0:0
snapshot > "$TMP/after-reload"
check reload_other_entries_unchanged cmp -s "$TMP/before" "$TMP/after-reload"
service_checks after_reload

# A host damaged by v0.2.12 regains the canonical mode on the next rebuild.
chmod 0700 "$LIBEXEC_DIR"
check damaged_rebuild_succeeds run
check damaged_libexec_restored_0755 test "$(mode "$LIBEXEC_DIR")" = 755:0:0
service_checks after_repair

# A symlinked LIBEXEC_DIR is refused before any chmod reaches its target.
real_libexec="$LIBEXEC_DIR"
install -d -m 0751 "$TMP/elsewhere"   # unusual mode: any chmod through the link shows
mv "$LIBEXEC_DIR" "$TMP/libexec.real"; ln -s elsewhere "$LIBEXEC_DIR"
cp "$FIREWALL_FILE" "$TMP/canonical.before"
if run; then bad symlink_libexec_refused; else ok symlink_libexec_refused; fi
check symlink_target_mode_untouched test "$(stat -c '%a' "$TMP/elsewhere")" = 751
check symlink_target_not_written test -z "$(ls -A "$TMP/elsewhere")"
check symlink_canonical_untouched cmp -s "$TMP/canonical.before" "$FIREWALL_FILE"
rm "$LIBEXEC_DIR"; mv "$TMP/libexec.real" "$real_libexec"

# A missing parent is created traversable even under the manager's umask 077.
LIBEXEC_DIR="$TMP/fresh/usr/local/libexec/twebproxy"
install -d -m 0755 "$TMP/fresh/usr/local"
BF_TEST_HELPER="$LIBEXEC_DIR/apply-firewall"; export BF_TEST_HELPER
check fresh_rebuild_succeeds run
check fresh_parent_traversable test "$(stat -c '%a' "$TMP/fresh/usr/local/libexec")" = 755
check fresh_libexec_root_0755 test "$(mode "$LIBEXEC_DIR")" = 755:0:0

printf 'stageb-libexec-permissions: pass=%s fail=%s not_executed=%s\n' "$pass" "$fail" "$not_executed"
(( fail == 0 )) || exit 1
(( not_executed == 0 )) || exit 77
