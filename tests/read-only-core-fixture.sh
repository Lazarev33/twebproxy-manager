#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/twebproxy-manager.sh"
FIXTURES="$ROOT/tests/fixtures/read-only-core"
TMP="$(mktemp -d)"
trap 'if [[ "${TWEBPROXY_KEEP_TEST_TMP:-0}" == 1 ]]; then printf "fixture_tmp=%s\n" "$TMP" >&2; else rm -rf "$TMP"; fi' EXIT

# main() is guarded, so the complete manager can be loaded as a function library.
# shellcheck disable=SC1090
source "$SCRIPT"
trap - ERR
export TWEBPROXY_UI_LANGUAGE=en

BASE_DIR="$TMP/etc/twebproxy"
INSTANCES_DIR="$BASE_DIR/instances"
BACKENDS_DIR="$BASE_DIR/backends"
MTPROXY_DATA_DIR="$BASE_DIR/mtproxy"
PROJECT_DIR="$TMP/opt/twebproxy-manager"
LOG_DIR="$PROJECT_DIR/logs"
LOG_MANAGER_DIR="$LOG_DIR/manager"
LOG_RUNTIME_DIR="$LOG_DIR/runtime"
LOG_BUNDLE_DIR="$LOG_DIR/bundles"
LOG_FULL_DIR="$LOG_DIR/full"
SYSTEMD_DIR="$TMP/etc/systemd/system"
FIREWALL_FILE="$BASE_DIR/firewall.nft"

FIXTURE_HOST="fixture.example"
FIXTURE_PROFILE="default"
FIXTURE_SECRET="0123456789abcdef0123456789abcdef"
FIXTURE_FAIL_RELAY=0

mkdir -p "$INSTANCES_DIR/$FIXTURE_HOST/profiles.d" "$BACKENDS_DIR" "$SYSTEMD_DIR"
cat > "$INSTANCES_DIR/$FIXTURE_HOST/instance.env" <<'EOF'
HOSTNAME=fixture.example
RELAY_PORT=18080
ADMIN_PORT=18081
TLS_MODE=caddy
SITE_MODE=placeholder
SITE_UPSTREAM=
SOURCE_SITE_DIR=
ACME_EMAIL=
NGINX_CERT=
NGINX_KEY=
CREATED_AT=2026-08-23T00:00:00Z
EOF
cat > "$INSTANCES_DIR/$FIXTURE_HOST/profiles.d/$FIXTURE_PROFILE.env" <<EOF
PROFILE_NAME=default
SECRET=$FIXTURE_SECRET
CARRIER_MODE=https
BACKEND_PORT=23980
STATS_PORT=23981
WORKERS=2
MAX_CONNECTIONS=60000
CREATED_AT=2026-08-23T00:00:00Z
EOF

# Fixture adapters: the read-only core sees the same facts it would obtain from
# systemd, ss, nftables, local HTTP endpoints and TLS helpers on a healthy host.
need_root() { :; }
need_systemd() { :; }

systemctl() {
  local joined="$*" unit="${*: -1}"
  if [[ "${1:-}" == is-active ]]; then
    if [[ "$unit" == "twebproxy@$FIXTURE_HOST.service" && "$FIXTURE_FAIL_RELAY" == 1 ]]; then
      [[ "$joined" == *'--quiet'* ]] || printf 'failed\n'
      return 3
    fi
    [[ "$joined" == *'--quiet'* ]] || printf 'active\n'
    return 0
  fi
  if [[ "${1:-}" == cat ]]; then
    printf '[Service]\nRestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK\n'
    return 0
  fi
  if [[ "$joined" == *' status '* ]]; then
    printf '● %s - fixture service\n' "$unit"
    printf '   Active: active (running)\n'
    # Deliberate secret-bearing process evidence: every renderer must redact it.
    printf '   Main PID: 123 (mtproto-proxy -S %s)\n' "$FIXTURE_SECRET"
    return 0
  fi
  return 0
}

ss() {
  case "$*" in
    *':18080'*) printf 'LISTEN 0 4096 127.0.0.1:18080 0.0.0.0:*\n';;
    *':18081'*) printf 'LISTEN 0 4096 127.0.0.1:18081 0.0.0.0:*\n';;
    *':23980'*) printf 'LISTEN 0 4096 0.0.0.0:23980 0.0.0.0:*\n';;
    *':23981'*) printf 'LISTEN 0 4096 0.0.0.0:23981 0.0.0.0:*\n';;
  esac
}

nft() {
  cat <<'EOF'
table inet twebproxy_backend {
  chain input {
    type filter hook input priority -5; policy accept;
    iifname != "lo" tcp dport { 23980, 23981 } drop
  }
}
EOF
}

curl() {
  local joined="$*"
  case "$joined" in
    *'/healthz'*) printf 'ok';;
    *'/readyz'*) printf 'ready';;
    *'/metrics'*) printf 'twebproxy_sessions 1\ntwebproxy_bytes_total 2048\n';;
    *'/stats'*) printf 'connections\t1\n';;
    *'https://fixture.example/'*) :;;
    *) return 22;;
  esac
}

fetch_public_leaf_cert() { printf '%s\n' 'fixture certificate' > "$2"; }
cert_days_remaining_file() { printf '45'; }
cert_fingerprint_file() { printf 'AA:BB:CC'; }

assert_no_secret() {
  local file="$1"
  if grep -Fq "$FIXTURE_SECRET" "$file"; then
    printf 'secret leak in %s\n' "$file" >&2
    return 1
  fi
}

assert_fixture_checks() {
  local json="$1" fixture="$2" actual="$TMP/actual.tsv"
  jq -r '.checks[] | [.id,.status,.scope] | @tsv' "$json" > "$actual"
  diff -u "$fixture" "$actual"
}

redaction_probe="$(printf 'Secret: %s\n?secret=dd%s\nMTPROXY_SECRET=%s\nSECRET=%s\n' \
  "$FIXTURE_SECRET" "$FIXTURE_SECRET" "$FIXTURE_SECRET" "$FIXTURE_SECRET" | redact_sensitive_stream)"
[[ "$redaction_probe" != *"$FIXTURE_SECRET"* ]]
[[ "$(grep -o '\[REDACTED\]' <<<"$redaction_probe" | wc -l)" -eq 4 ]]

# JSON: one clean document, schema-versioned, stable check IDs and no decoration.
main --json status "$FIXTURE_HOST" > "$TMP/status.json" 2> "$TMP/status.err"
jq -e '.schema_version == "twebproxy.output.v1" and .command == "status" and .overall == "OK"' "$TMP/status.json" >/dev/null
[[ "$(wc -l < "$TMP/status.json")" -eq 1 ]]
! grep -q $'\033' "$TMP/status.json"
! grep -Eq 'TWebProxy Manager|^\[log\]' "$TMP/status.json"
[[ ! -s "$TMP/status.err" ]] || { cat "$TMP/status.err" >&2; false; }
assert_no_secret "$TMP/status.json"
assert_fixture_checks "$TMP/status.json" "$FIXTURES/status-healthy.tsv"

# Flag order is intentionally compatible before or after the legacy command.
main status "$FIXTURE_HOST" --json > "$TMP/status-after.json" 2> "$TMP/status-after.err"
jq -e '.schema_version == "twebproxy.output.v1"' "$TMP/status-after.json" >/dev/null

main audit --json "$FIXTURE_HOST" > "$TMP/audit.json" 2> "$TMP/audit.err"
jq -e '.schema_version == "twebproxy.output.v1" and .command == "audit" and .overall == "OK"' "$TMP/audit.json" >/dev/null
assert_no_secret "$TMP/audit.json"
assert_fixture_checks "$TMP/audit.json" "$FIXTURES/audit-healthy.tsv"
[[ ! -s "$TMP/audit.err" ]]

# Raw: line-oriented typed records, no banner/ANSI/transcript or secrets.
main --raw status "$FIXTURE_HOST" > "$TMP/status.raw" 2> "$TMP/status-raw.err"
head -n1 "$TMP/status.raw" | grep -q $'^twebproxy.raw.v1\tcommand=status\t'
grep -q $'^relay.service.active\tOK\tcritical\t' "$TMP/status.raw"
! grep -Eq 'TWebProxy Manager|^\[log\]' "$TMP/status.raw"
assert_no_secret "$TMP/status.raw"

main audit "$FIXTURE_HOST" --raw > "$TMP/audit.raw" 2> "$TMP/audit-raw.err"
head -n1 "$TMP/audit.raw" | grep -q $'^twebproxy.raw.v1\tcommand=audit\t'
grep -q $'^firewall.backend.boundary\tOK\tcritical\t' "$TMP/audit.raw"
assert_no_secret "$TMP/audit.raw"

# Stage 2 reuses the same core for its new read-only views. Machine stdout stays
# a single clean document/stream and never contains the configured secret.
main --json overview > "$TMP/overview.json" 2> "$TMP/overview.err"
jq -e '.schema_version == "twebproxy.output.v1" and .command == "overview" and .data.hostnames == 1 and .data.profiles == 1' "$TMP/overview.json" >/dev/null
jq -e 'any(.checks[]; .id == "anti_dpi.mode" and .status == "DISABLED" and .observed == "STOCK@unresolved") and
  all(.checks[]; (.id | startswith("recovery.") or startswith("snapshot.")) | not)' "$TMP/overview.json" >/dev/null
[[ "$(wc -l < "$TMP/overview.json")" -eq 1 && ! -s "$TMP/overview.err" ]]
assert_no_secret "$TMP/overview.json"

main profile-list "$FIXTURE_HOST" --json > "$TMP/profiles.json" 2> "$TMP/profiles.err"
jq -e '.command == "profile-list" and .data.profiles == 1 and any(.checks[]; .id == "profile.secret.configured" and .observed == "configured")' "$TMP/profiles.json" >/dev/null
! grep -q $'\033' "$TMP/profiles.json"
[[ ! -s "$TMP/profiles.err" ]]
assert_no_secret "$TMP/profiles.json"

main --json stats "$FIXTURE_HOST" > "$TMP/stats.json" 2> "$TMP/stats.err"
jq -e '.command == "stats" and .data.available_sources == 2 and .data.history_available == false' "$TMP/stats.json" >/dev/null
jq -e 'any(.checks[]; .id == "statistics.history" and .status == "DISABLED")' "$TMP/stats.json" >/dev/null
[[ ! -s "$TMP/stats.err" ]]
assert_no_secret "$TMP/stats.json"

main --no-color stats "$FIXTURE_HOST" > "$TMP/stats.human" 2> "$TMP/stats-human.err"
grep -q '^TWebProxy Statistics · fixture.example$' "$TMP/stats.human"
grep -q '^Relay sessions.*1$' "$TMP/stats.human"
grep -q '^Relay bytes total.*2.0 KiB (2048 B)$' "$TMP/stats.human"
grep -q '^Backend connections.*1$' "$TMP/stats.human"
grep -q '^Relay streams.*Not reported by the live source$' "$TMP/stats.human"
[[ ! -s "$TMP/stats-human.err" ]]
assert_no_secret "$TMP/stats.human"

main --raw overview > "$TMP/overview.raw" 2> "$TMP/overview-raw.err"
head -n1 "$TMP/overview.raw" | grep -q $'^twebproxy.raw.v1\tcommand=overview\t'
grep -q $'^anti_dpi.mode\tDISABLED\tinfo\thostname:fixture.example\tdns\tSTOCK@unresolved\t' "$TMP/overview.raw"
assert_no_secret "$TMP/overview.raw"

# Default human output is compact. The explicit --verbose view retains every
# legacy fact, including redaction of secret-bearing service evidence.
main --no-color status "$FIXTURE_HOST" > "$TMP/status.human" 2> "$TMP/status-human.err"
grep -q '^TWebProxy Status · fixture.example$' "$TMP/status.human"
grep -q '^Overall.*\[OK\]' "$TMP/status.human"
grep -q 'Detailed evidence is available in Diagnostics' "$TMP/status.human"
! grep -q 'fixture service' "$TMP/status.human"
assert_no_secret "$TMP/status.human"

main --no-color status "$FIXTURE_HOST" --verbose > "$TMP/status.verbose" 2> "$TMP/status-verbose.err"
grep -q '^Host: fixture.example | TLS: caddy$' "$TMP/status.verbose"
grep -q '^TLS certificate: mode=caddy | remaining=45d | renewal=Caddy auto$' "$TMP/status.verbose"
grep -q 'fixture service' "$TMP/status.verbose"
grep -q 'ok <- healthz' "$TMP/status.verbose"
grep -q 'ready <- readyz' "$TMP/status.verbose"
grep -q -- '-S \[REDACTED\]' "$TMP/status.verbose"
assert_no_secret "$TMP/status.verbose"

main --no-color audit "$FIXTURE_HOST" > "$TMP/audit.human" 2> "$TMP/audit-human.err"
grep -q '^== Isolation audit: fixture.example ==$' "$TMP/audit.human"
grep -q 'relay service active' "$TMP/audit.human"
grep -q 'backend port 23980 is covered by nftables' "$TMP/audit.human"
! ui_contains_cyrillic "$(<"$TMP/audit.human")"
grep -q 'AUDIT RESULT: PASS (0 warnings)' "$TMP/audit.human"
! grep -q 'UNTRANSLATED_MESSAGE_' "$TMP/audit.human"
assert_no_secret "$TMP/audit.human"

# Failure fixture: audit preserves exit 1 and exposes the same failed fact;
# observational status preserves its legacy exit 0 behavior.
FIXTURE_FAIL_RELAY=1
if main --json audit "$FIXTURE_HOST" > "$TMP/audit-fail.json" 2> "$TMP/audit-fail.err"; then
  printf 'audit failure fixture unexpectedly returned 0\n' >&2
  exit 1
else
  rc=$?
fi
[[ "$rc" -eq 1 ]]
jq -e '.overall == "ERROR" and any(.checks[]; .id == "relay.service.active" and .status == "ERROR")' "$TMP/audit-fail.json" >/dev/null
main --json status "$FIXTURE_HOST" > "$TMP/status-fail.json" 2> "$TMP/status-fail.err"
jq -e '.overall == "ERROR" and any(.checks[]; .id == "relay.service.active" and .status == "ERROR")' "$TMP/status-fail.json" >/dev/null

main --json status missing.example > "$TMP/status-missing.json" 2> "$TMP/status-missing.err"
jq -e '.overall == "ERROR" and .checks[0].id == "instance.state.present"' "$TMP/status-missing.json" >/dev/null

if [[ -n "${TWEBPROXY_CAPTURE_DIR:-}" ]]; then
  install -d -m 0755 "$TWEBPROXY_CAPTURE_DIR"
  cp "$TMP/status.human" "$TWEBPROXY_CAPTURE_DIR/human-cli-status.txt"
  cp "$TMP/status.json" "$TWEBPROXY_CAPTURE_DIR/status.json"
  cp "$TMP/status.raw" "$TWEBPROXY_CAPTURE_DIR/status.raw.tsv"
  cp "$TMP/overview.json" "$TWEBPROXY_CAPTURE_DIR/overview.json"
  cp "$TMP/profiles.json" "$TWEBPROXY_CAPTURE_DIR/profiles.json"
  cp "$TMP/stats.json" "$TWEBPROXY_CAPTURE_DIR/statistics.json"
  cp "$TMP/stats.human" "$TWEBPROXY_CAPTURE_DIR/human-cli-statistics.txt"
fi

printf 'read-only-core-fixture: PASS\n'
