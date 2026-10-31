#!/usr/bin/env bash
# F13 regression: an occupied port is never reported free. v0.2.13 used
# `ss | awk | grep -q` under pipefail: grep -q exiting at the first match makes
# awk die of SIGPIPE, the pipeline fails, and a listening port looks free; a
# failing ss looked like "nothing listens". Ports recorded only in profiles.d
# (backend env missing after an interrupted commit) were not seen either.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
TMP="$(mktemp -d /tmp/twebproxy-c1-ports.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
source "$ROOT/tests/stagec1/state-harness.sh"
c1_harness
pass=0; fail=0
ok() { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
listening() { c1_run port_listening "$1" >/dev/null 2>&1; }
free() { c1_run port_available "$1" >/dev/null 2>&1; }
not() { ! "$@"; }
H=alpha.example

# 1. SIGPIPE: the matching listener comes first, then a large listener table.
printf 'LISTEN 0 4096 0.0.0.0:23980 0.0.0.0:*\n' > "$TMP/ss-extra"
export C1_SS_PAD=200000
check sigpipe_listening_port_detected listening 23980
check sigpipe_listening_port_not_free not free 23980
for i in 1 2 3; do check "sigpipe_repeat_$i" listening 23980; done
unset C1_SS_PAD

# 2. listener formats (IPv4, IPv6, wildcard, mapped, scoped).
cat > "$TMP/ss-extra" <<'EOF'
LISTEN 0 4096 [::]:23990 [::]:*
LISTEN 0 4096 *:23991 *:*
LISTEN 0 4096 [::ffff:127.0.0.1]:23992 *:*
LISTEN 0 4096 127.0.0.1%lo:23993 0.0.0.0:*
LISTEN 0 4096 0.0.0.0:23994 0.0.0.0:*
LISTEN 0 4096 [fe80::1%eth0]:23995 [::]:*
LISTEN 0 4096 *:8080 *:*
EOF
for p in 23990 23991 23992 23993 23994 23995 8080; do check "format_listening_$p" listening "$p"; done
check format_absent_port_free free 23996
check format_suffix_is_not_port not listening 80
check format_prefix_is_not_port not listening 2399

# 3. ss failure is not proof that a port is free.
: > "$TMP/fail-ss"
c1_run port_listening 23996 > "$TMP/out" 2>&1; rc=$?
check ss_failure_not_listening_unknown test "$rc" -ne 0 -a "$rc" -ne 1
check ss_failure_port_not_free not free 23996
check ss_failure_reported grep -qi 'ss' "$TMP/out"
c1_run next_free_port 23996 23999 > "$TMP/out" 2>/dev/null; rc=$?
check ss_failure_allocation_refused test "$rc" -ne 0 -a -z "$(cat "$TMP/out")"
rm -f "$TMP/fail-ss"

# 4. ports recorded in the authoritative profile record count as registered.
c1_seed_instance "$H" 18080 18081
c1_seed_profile "$H" alpha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa https 24500 29500
rm -f "$BACKENDS_DIR/$H--alpha.env"
: > "$TMP/ss-extra"
check profile_record_backend_port_registered not free 24500
check profile_record_stats_port_registered not free 29500
check instance_relay_port_registered not free 18080
check unrelated_port_free free 24501

# 5. allocation skips registered and listening ports, returns a free one.
printf 'LISTEN 0 4096 [::]:24501 [::]:*\n' > "$TMP/ss-extra"
check next_free_skips_taken test "$(c1_run next_free_port 24500 24510)" = 24502

# 6. backend readiness is found despite a large listener table (no SIGPIPE flake).
c1_seed_profile "$H" alpha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa https 24500 29500
: > "$TMP/ss-extra"
start=$SECONDS
C1_SS_PAD=200000 c1_run start_profile_backend "$H" alpha > "$TMP/out" 2>&1; rc=$?
check readiness_detected_with_large_table test "$rc" -eq 0
check readiness_without_retry_loop test "$((SECONDS - start))" -le 8

printf 'c1-port-allocation: pass=%s fail=%s\n' "$pass" "$fail"
(( fail == 0 ))
