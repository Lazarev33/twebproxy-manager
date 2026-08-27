#!/usr/bin/env bash
# FD-1 — field diagnostics regression for `twebproxy field-report`.
#
# Drivers run as subprocesses so production `set -Eeuo pipefail` semantics and
# the ERR trap stay intact for the code under test.
#
# Usage: fd1-field-report.sh [path/to/twebproxy-manager.sh]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
MGR="$(cd "$(dirname "$MGR")" && pwd -P)/$(basename "$MGR")"

pass=0; fail=0; neel=0
t_ok()   { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
t_bad()  { printf 'FAIL %s\n' "$*" >&2; fail=$((fail+1)); }
t_skip() { printf 'NOT_EXECUTED_ENVIRONMENT_LIMITATION %s\n' "$*"; neel=$((neel+1)); }

TMP="$(mktemp -d /tmp/fd1-field.XXXXXX)"; trap 'rm -rf -- "$TMP"' EXIT
HOST=alpha.example
SECRET_WEB=00112233445566778899aabbccddeeff
SECRET_MT=ffeeddccbbaa99887766554433221100

# ---- shared preamble sourced by every driver -------------------------------
cat > "$TMP/preamble.sh" <<'PRE'
BASE_DIR="$SB/etc"; INSTANCES_DIR="$BASE_DIR/instances"; BACKENDS_DIR="$BASE_DIR/backends"
DPI_DIR="$BASE_DIR/dpi"; DPI_STATE_DIR="$DPI_DIR/scopes"; DPI_NFT_FILE="$DPI_DIR/firewall.nft"
SITES_DIR="$SB/srv"; GLOBAL_ENV="$BASE_DIR/global.env"; MTPROXY_DATA_DIR="$BASE_DIR/mtproxy"
LIBEXEC_DIR="$SB/libexec"; SYSTEMD_DIR="$SB/systemd"; DPI_DOC_DIR="$SB/doc"
PROJECT_DIR="$SB/opt"; LOG_DIR="$PROJECT_DIR/logs"; LOG_MANAGER_DIR="$LOG_DIR/manager"
LOG_RUNTIME_DIR="$LOG_DIR/runtime"; LOG_BUNDLE_DIR="$LOG_DIR/bundles"; LOG_FULL_DIR="$LOG_DIR/full"
DPI_NFT_BIN="$SB/bin/nft"
install -d -m 0700 "$BASE_DIR" "$INSTANCES_DIR" "$BACKENDS_DIR" "$MTPROXY_DATA_DIR" >/dev/null 2>&1
install -d -m 0700 "$PROJECT_DIR" "$LOG_DIR" "$LOG_MANAGER_DIR" "$LOG_RUNTIME_DIR" "$LOG_BUNDLE_DIR" "$LOG_FULL_DIR" >/dev/null 2>&1
mkdir -p "$SB/systemd" "$SB/libexec" "$SB/srv" "$SB/bin"
UI_LANGUAGE=en
mkdir -p "$INSTANCES_DIR/alpha.example/profiles.d"
cat > "$INSTANCES_DIR/alpha.example/instance.env" <<INST
HOSTNAME=alpha.example
RELAY_PORT=18080
ADMIN_PORT=18081
TLS_MODE=manual
SITE_MODE=placeholder
SOURCE_SITE_DIR=
SITE_UPSTREAM=
NGINX_CERT=
NGINX_KEY=
LE_EMAIL=
INST
chmod 0600 "$INSTANCES_DIR/alpha.example/instance.env"
printf 'SECRET=%s\nCARRIER_MODE=https\n' "$FAKE_WEB_SECRET" > "$INSTANCES_DIR/alpha.example/profiles.d/default.env"
chmod 0600 "$INSTANCES_DIR/alpha.example/profiles.d/default.env"
printf 'MTPROXY_SECRET=%s\nMTPROXY_CLIENT_PORT=23980\nMTPROXY_STATS_PORT=28980\n' "$FAKE_MT_SECRET" \
  > "$BACKENDS_DIR/alpha.example--default.env"
chmod 0600 "$BACKENDS_DIR/alpha.example--default.env"
systemctl() { return 0; }
# A journal that emits a recognizable secret, so redaction is exercised on the
# exact-window journal path rather than only on files we control.
journalctl() { printf 'Jan 01 00:00:00 host svc[1]: starting -S %s\n' "$FAKE_MT_SECRET"; return 0; }
getent() { case "${1:-}" in ahostsv4) printf '198.51.100.10 STREAM alpha.example\n';; *) return 1;; esac; }
dpi_local_ipv4_addresses() { printf '%s\n' 198.51.100.10; }
# A read-only nft stand-in. `-a list table` prints handles/counters so the
# before/after comparison the bundle is meant to support is actually exercised;
# any mutating verb fails loudly so an accidental write would be caught.
cat > "$SB/bin/nft" <<'NFTSTUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in add|delete|flush|insert|replace|-f) echo "MUTATION ATTEMPTED: $*" >&2; exit 99;; esac; done
case " $* " in
  *" list "*)
    fam=inet; name=t
    for i in $(seq 1 $#); do
      eval "cur=\${$i}"
      case "$cur" in ip|ip6|inet|arp|bridge|netdev) fam="$cur";; twebproxy_*) name="$cur";; esac
    done
    printf 'table %s %s {\n  chain c {\n    counter packets 41 bytes 5000 # handle 4\n  }\n}\n' "$fam" "$name"
    exit 0;;
esac
exit 0
NFTSTUB
chmod 0755 "$SB/bin/nft"
PRE

mkdrv() { # $1=name $2=body
  { printf '#!/usr/bin/env bash\nSB="$1"; shift\n'
    printf 'FAKE_WEB_SECRET=%s\nFAKE_MT_SECRET=%s\n' "$SECRET_WEB" "$SECRET_MT"
    printf 'source "%s"\n' "$MGR"
    cat "$TMP/preamble.sh"
    printf '%s\n' "$2"
  } > "$TMP/$1"; }

run() { # $1=driver $2=tag ; extra args after -> passed to driver. Sets SB,OUT,RC
  local drv="$1" tag="$2"; shift 2
  SB="$TMP/sb-$tag"; rm -rf "$SB"; mkdir -p "$SB"
  OUT="$(timeout 300 bash "$TMP/$drv" "$SB" "$@" 2>&1)"; RC=$?
}
bundle_of() { find "$1/opt/logs/bundles" -name 'twebproxy-field-*.tar.gz' 2>/dev/null | head -n1; }
extract() { local b="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"; tar -xzf "$b" -C "$d"; }
meta() { grep -E "^$2=" "$1/FIELD-TEST.txt" 2>/dev/null | head -n1 | cut -d= -f2-; }

# =====================================================================
# 1. --instant
# =====================================================================
mkdrv drv-instant.sh 'field_report_cmd alpha.example --instant'
run drv-instant.sh instant </dev/null
(( RC == 0 )) && t_ok "fd1_instant_exits_zero" || t_bad "fd1_instant_exits_zero: rc=$RC :: $(tail -3 <<<"$OUT" | tr '\n' ' ')"
B="$(bundle_of "$SB")"
if [[ -n "$B" && -f "$B" ]]; then
  t_ok "fd1_instant_archive_produced"
  [[ "$(stat -c '%U:%G:%a' "$B")" == "root:root:600" ]] \
    && t_ok "fd1_instant_archive_mode_0600" || t_bad "fd1_instant_archive_mode_0600: $(stat -c '%U:%G:%a' "$B")"
  [[ "$(basename "$B")" == twebproxy-field-alpha.example-* ]] \
    && t_ok "fd1_instant_archive_named_by_host" || t_bad "fd1_instant_archive_named_by_host"
  D="$TMP/x-instant"; extract "$B" "$D"
  for f in FIELD-TEST.txt current-runtime.log journal-window.log nft-current.txt MANIFEST.sha256; do
    [[ -f "$D/$f" ]] && t_ok "fd1_instant_has_$f" || t_bad "fd1_instant_has_$f"
  done
  ( cd "$D" && sha256sum -c MANIFEST.sha256 >/dev/null 2>&1 ) \
    && t_ok "fd1_instant_manifest_verifies" || t_bad "fd1_instant_manifest_verifies"
  [[ "$(meta "$D" capture_mode)" == instant ]] \
    && t_ok "fd1_instant_capture_mode" || t_bad "fd1_instant_capture_mode: $(meta "$D" capture_mode)"
  [[ "$(meta "$D" client_observation)" == not_recorded ]] \
    && t_ok "fd1_instant_observation_not_recorded" || t_bad "fd1_instant_observation_not_recorded"
  [[ ! -f "$D/packet-trace.pcap" ]] \
    && t_ok "fd1_instant_no_raw_pcap" || t_bad "fd1_instant_no_raw_pcap"
  [[ -n "$(meta "$D" hostname)" && -n "$(meta "$D" manager_version)" ]] \
    && t_ok "fd1_instant_metadata_populated" || t_bad "fd1_instant_metadata_populated"
else
  t_bad "fd1_instant_archive_produced"
fi

# =====================================================================
# 9. secret redaction (uses the instant bundle above)
# =====================================================================
if [[ -n "${D:-}" && -d "$D" ]]; then
  hits="$(grep -rlF -e "$SECRET_WEB" -e "$SECRET_MT" "$D" 2>/dev/null || true)"
  [[ -z "$hits" ]] && t_ok "fd1_no_plaintext_secrets_in_archive" \
    || t_bad "fd1_no_plaintext_secrets_in_archive: $hits"
  grep -rqF 'REDACTED' "$D" 2>/dev/null \
    && t_ok "fd1_redaction_marker_present" || t_skip "fd1_redaction_marker_present: no secret reached a sanitized stream here"
fi

# =====================================================================
# 2. normal flow, simulated Enter
# =====================================================================
mkdrv drv-normal.sh 'FIELD_CAPTURE_SECONDS=30; field_report_cmd alpha.example'
SB="$TMP/sb-normal"; rm -rf "$SB"; mkdir -p "$SB"
OUT="$(printf '\n' | timeout 300 bash "$TMP/drv-normal.sh" "$SB" 2>&1)"; RC=$?
(( RC == 0 )) && t_ok "fd1_normal_exits_zero" || t_bad "fd1_normal_exits_zero: rc=$RC :: $(tail -3 <<<"$OUT" | tr '\n' ' ')"
B="$(bundle_of "$SB")"
if [[ -n "$B" ]]; then
  D="$TMP/x-normal"; extract "$B" "$D"
  for f in FIELD-TEST.txt before-runtime.log after-runtime.log journal-window.log nft-before.txt nft-after.txt packet-trace.txt MANIFEST.sha256; do
    [[ -f "$D/$f" ]] && t_ok "fd1_normal_has_$f" || t_bad "fd1_normal_has_$f"
  done
  [[ "$(meta "$D" capture_mode)" == reproduction ]] \
    && t_ok "fd1_normal_capture_mode" || t_bad "fd1_normal_capture_mode"
  s="$(meta "$D" started_at)"; e="$(meta "$D" ended_at)"
  [[ -n "$s" && -n "$e" && "$s" != unknown && "$e" != unknown ]] \
    && t_ok "fd1_normal_window_timestamps_present" || t_bad "fd1_normal_window_timestamps_present"
  [[ "$(meta "$D" duration_seconds)" =~ ^[0-9]+$ ]] \
    && t_ok "fd1_normal_duration_numeric" || t_bad "fd1_normal_duration_numeric"
  case "$(meta "$D" client_observation)" in
    connected|disconnected|unstable|not_tested) t_ok "fd1_normal_observation_normalized";;
    *) t_bad "fd1_normal_observation_normalized: $(meta "$D" client_observation)";;
  esac
  ( cd "$D" && sha256sum -c MANIFEST.sha256 >/dev/null 2>&1 ) \
    && t_ok "fd1_normal_manifest_verifies" || t_bad "fd1_normal_manifest_verifies"
  [[ ! -f "$D/packet-trace.pcap" ]] \
    && t_ok "fd1_normal_no_raw_pcap_by_default" || t_bad "fd1_normal_no_raw_pcap_by_default"
  [[ -z "$(find "$SB/opt/logs/bundles" -name '*.partial' 2>/dev/null)" ]] \
    && t_ok "fd1_normal_no_leftover_partial_name" || t_bad "fd1_normal_no_leftover_partial_name"
  grep -q 'counter packets' "$D/nft-before.txt" && grep -q 'counter packets' "$D/nft-after.txt" \
    && t_ok "fd1_normal_nft_evidence_has_counters" || t_bad "fd1_normal_nft_evidence_has_counters"
  grep -q 'twebproxy_backend' "$D/nft-before.txt" && grep -q 'twebproxy_dpi' "$D/nft-before.txt" \
    && t_ok "fd1_normal_nft_covers_both_tables" || t_bad "fd1_normal_nft_covers_both_tables"
  grep -rq 'MUTATION ATTEMPTED' "$D" \
    && t_bad "fd1_normal_nft_never_mutated" || t_ok "fd1_normal_nft_never_mutated"
else
  t_bad "fd1_normal_archive_produced"
fi

# =====================================================================
# 3. timeout path is a normal completion (stdin stays open, no input)
# =====================================================================
mkdrv drv-timeout.sh 'FIELD_CAPTURE_SECONDS=2; field_report_cmd alpha.example'
SB="$TMP/sb-timeout"; rm -rf "$SB"; mkdir -p "$SB"
start=$(date +%s)
OUT="$(timeout 300 bash "$TMP/drv-timeout.sh" "$SB" < <(sleep 8) 2>&1)"; RC=$?
elapsed=$(( $(date +%s) - start ))
(( RC == 0 )) && t_ok "fd1_timeout_is_normal_completion" || t_bad "fd1_timeout_is_normal_completion: rc=$RC"
(( elapsed < 120 )) && t_ok "fd1_timeout_does_not_hang (${elapsed}s)" || t_bad "fd1_timeout_does_not_hang (${elapsed}s)"
grep -qE 'Error at line|Ошибка на строке' <<<"$OUT" \
  && t_bad "fd1_timeout_no_errexit_abort" || t_ok "fd1_timeout_no_errexit_abort"
[[ -n "$(bundle_of "$SB")" ]] && t_ok "fd1_timeout_archive_produced" || t_bad "fd1_timeout_archive_produced"

# =====================================================================
# 4. tcpdump unavailable
# =====================================================================
mkdrv drv-notcpdump.sh 'PATH="$SB/emptybin:/usr/bin:/bin"; FIELD_CAPTURE_SECONDS=2; field_report_cmd alpha.example'
SB="$TMP/sb-notcpdump"; rm -rf "$SB"; mkdir -p "$SB/emptybin"
OUT="$(printf '\n' | timeout 300 bash "$TMP/drv-notcpdump.sh" "$SB" 2>&1)"; RC=$?
(( RC == 0 )) && t_ok "fd1_no_tcpdump_still_succeeds" || t_bad "fd1_no_tcpdump_still_succeeds: rc=$RC"
B="$(bundle_of "$SB")"
if [[ -n "$B" ]]; then D="$TMP/x-notcpdump"; extract "$B" "$D"
  [[ "$(meta "$D" packet_trace)" == unavailable ]] \
    && t_ok "fd1_no_tcpdump_records_unavailable" || t_bad "fd1_no_tcpdump_records_unavailable: $(meta "$D" packet_trace)"
else t_bad "fd1_no_tcpdump_archive_produced"; fi

# =====================================================================
# 5. tcpdump present but fails to start
# =====================================================================
mkdrv drv-badtcpdump.sh 'PATH="$SB/bin:$PATH"; FIELD_CAPTURE_SECONDS=2; field_report_cmd alpha.example'
SB="$TMP/sb-badtcpdump"; rm -rf "$SB"; mkdir -p "$SB/bin"
printf '#!/bin/sh\nexit 1\n' > "$SB/bin/tcpdump"; chmod 755 "$SB/bin/tcpdump"
before_td=$(pgrep -f "$SB/bin/tcpdump" 2>/dev/null | wc -l)
OUT="$(printf '\n' | timeout 300 bash "$TMP/drv-badtcpdump.sh" "$SB" 2>&1)"; RC=$?
(( RC == 0 )) && t_ok "fd1_tcpdump_start_fail_still_succeeds" || t_bad "fd1_tcpdump_start_fail_still_succeeds: rc=$RC"
B="$(bundle_of "$SB")"
if [[ -n "$B" ]]; then D="$TMP/x-badtcpdump"; extract "$B" "$D"
  [[ "$(meta "$D" packet_trace)" == start_failed ]] \
    && t_ok "fd1_tcpdump_start_fail_recorded" || t_bad "fd1_tcpdump_start_fail_recorded: $(meta "$D" packet_trace)"
else t_bad "fd1_tcpdump_start_fail_archive"; fi
after_td=$(pgrep -f "$SB/bin/tcpdump" 2>/dev/null | wc -l)
(( after_td == 0 && before_td == 0 )) \
  && t_ok "fd1_tcpdump_start_fail_no_orphan" \
  || t_bad "fd1_tcpdump_start_fail_no_orphan: before=$before_td after=$after_td"

# =====================================================================
# 6 + 7. successful trace, and --keep-pcap
# =====================================================================
mkshim() { mkdir -p "$1"; cat > "$1/tcpdump" <<'SHIM'
#!/usr/bin/env bash
# Stand-in for tcpdump: -w writes a capture file and stays alive until signalled;
# -r renders a header-only text summary. Never emits payload hexdumps.
out=""; read_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -w) out="$2"; shift 2;;
    -r) read_file="$2"; shift 2;;
    *) shift;;
  esac
done
if [ -n "$read_file" ]; then
  echo "2026-01-01 00:00:00.000001 IP 203.0.113.10.443 > 198.51.100.20.51000: Flags [S.], seq 1, ack 2, win 1152, options [mss 88,sackOK], length 0"
  echo "2026-01-01 00:00:00.000002 IP 198.51.100.20.51000 > 203.0.113.10.443: Flags [.], ack 2, win 502, length 0"
  exit 0
fi
if [ -n "$out" ]; then printf 'FAKEPCAP' > "$out"; trap 'exit 0' TERM INT; while :; do sleep 0.2; done; fi
exit 0
SHIM
chmod 755 "$1/tcpdump"; }

mkdrv drv-trace.sh 'PATH="$SB/bin:$PATH"; FIELD_CAPTURE_SECONDS=2; field_report_cmd alpha.example'
SB="$TMP/sb-trace"; rm -rf "$SB"; mkdir -p "$SB"; mkshim "$SB/bin"
OUT="$(printf '\n' | timeout 300 bash "$TMP/drv-trace.sh" "$SB" 2>&1)"; RC=$?
(( RC == 0 )) && t_ok "fd1_trace_exits_zero" || t_bad "fd1_trace_exits_zero: rc=$RC"
B="$(bundle_of "$SB")"
if [[ -n "$B" ]]; then D="$TMP/x-trace"; extract "$B" "$D"
  [[ "$(meta "$D" packet_trace)" == captured ]] \
    && t_ok "fd1_trace_recorded_captured" || t_bad "fd1_trace_recorded_captured: $(meta "$D" packet_trace)"
  grep -q 'Flags \[S\.\]' "$D/packet-trace.txt" 2>/dev/null \
    && t_ok "fd1_trace_text_has_tcp_flags" || t_bad "fd1_trace_text_has_tcp_flags"
  grep -qE 'mss 88|win 1152' "$D/packet-trace.txt" 2>/dev/null \
    && t_ok "fd1_trace_text_has_options_and_window" || t_bad "fd1_trace_text_has_options_and_window"
  grep -qE '^\s+0x[0-9a-f]{4}:' "$D/packet-trace.txt" 2>/dev/null \
    && t_bad "fd1_trace_text_has_no_payload_hexdump" || t_ok "fd1_trace_text_has_no_payload_hexdump"
  [[ ! -f "$D/packet-trace.pcap" ]] \
    && t_ok "fd1_trace_raw_pcap_absent_by_default" || t_bad "fd1_trace_raw_pcap_absent_by_default"
  [[ "$(meta "$D" raw_pcap_included)" == no ]] \
    && t_ok "fd1_trace_raw_pcap_included_no" || t_bad "fd1_trace_raw_pcap_included_no"
  find "$D" -name '*.pcap' | grep -q . \
    && t_bad "fd1_trace_no_pcap_anywhere_in_bundle" || t_ok "fd1_trace_no_pcap_anywhere_in_bundle"
else t_bad "fd1_trace_archive_produced"; fi

mkdrv drv-keeppcap.sh 'PATH="$SB/bin:$PATH"; FIELD_CAPTURE_SECONDS=2; field_report_cmd alpha.example --keep-pcap'
SB="$TMP/sb-keeppcap"; rm -rf "$SB"; mkdir -p "$SB"; mkshim "$SB/bin"
OUT="$(printf '\n' | timeout 300 bash "$TMP/drv-keeppcap.sh" "$SB" 2>&1)"; RC=$?
(( RC == 0 )) && t_ok "fd1_keeppcap_exits_zero" || t_bad "fd1_keeppcap_exits_zero: rc=$RC"
grep -qi 'raw PCAP contains network metadata' <<<"$OUT" \
  && t_ok "fd1_keeppcap_warning_shown" || t_bad "fd1_keeppcap_warning_shown"
B="$(bundle_of "$SB")"
if [[ -n "$B" ]]; then D="$TMP/x-keeppcap"; extract "$B" "$D"
  [[ -f "$D/packet-trace.pcap" ]] \
    && t_ok "fd1_keeppcap_raw_pcap_included" || t_bad "fd1_keeppcap_raw_pcap_included"
  [[ "$(meta "$D" raw_pcap_included)" == yes ]] \
    && t_ok "fd1_keeppcap_metadata_yes" || t_bad "fd1_keeppcap_metadata_yes"
  ( cd "$D" && sha256sum -c MANIFEST.sha256 >/dev/null 2>&1 ) \
    && t_ok "fd1_keeppcap_manifest_verifies" || t_bad "fd1_keeppcap_manifest_verifies"
else t_bad "fd1_keeppcap_archive_produced"; fi

# =====================================================================
# 8. SIGINT / SIGTERM lifecycle.
#
# The signal must be delivered to the ACTUAL driver process running
# field_report_cmd, never to a `timeout` wrapper: a wrapper absorbs the signal
# and proves nothing about the manager's own handler. A Bash INT/TERM trap that
# does not terminate simply RESUMES the interrupted command, so the command
# would carry on collecting and packaging with an emptied staging variable and
# write "$FIELD_STAGING/after-runtime.log" as /after-runtime.log.
#
# Every wait here is a bounded poll, never a bare `wait`, so a broken handler
# cannot hang the suite.
# =====================================================================
ROOT_DIAG_FILES=(/packet-trace.txt /after-runtime.log /nft-after.txt /journal-window.log /FIELD-TEST.txt)
root_diag_count() { local f n=0; for f in "${ROOT_DIAG_FILES[@]}"; do [[ -e "$f" ]] && n=$((n+1)); done; printf '%s' "$n"; }
root_diag_clean() { rm -f "${ROOT_DIAG_FILES[@]}" 2>/dev/null || true; }

if (( $(root_diag_count) > 0 )); then
  t_bad "fd1_signal_precondition_no_root_diag_files: pre-existing root diagnostic files; removing"
  root_diag_clean
fi
# Earlier subtests (and any prior red run of this suite) can leave staging dirs
# behind, so count only directories this subtest is responsible for.
staging_now() { find /tmp -maxdepth 1 -name 'twebproxy-field.*' 2>/dev/null | sort; }

mkdrv drv-signal.sh 'PATH="$SB/bin:$PATH"; FIELD_CAPTURE_SECONDS=60; field_report_cmd alpha.example'

for sig in INT TERM; do
  SB="$TMP/sb-signal-$sig"; rm -rf "$SB"; mkdir -p "$SB"; mkshim "$SB/bin"
  root_diag_clean
  staging_before="$(staging_now)"

  # An unrelated capture that must survive: same shim binary, different sandbox.
  DECOY_DIR="$TMP/decoy-$sig"; mkdir -p "$DECOY_DIR"; mkshim "$DECOY_DIR"
  "$DECOY_DIR/tcpdump" -w "$DECOY_DIR/decoy.pcap" >/dev/null 2>&1 &
  decoy_pid=$!

  # Launch the driver DIRECTLY. No `timeout` wrapper in front of it.
  #
  # Job control matters here: in a non-interactive shell WITHOUT it, `cmd &`
  # starts the child with SIGINT and SIGQUIT set to SIG_IGN (verified: SigIgn
  # 0x6), and Bash cannot trap a signal that was ignored on entry. The SIGINT
  # case would then be untestable and would look like a hung handler. `set -m`
  # gives the child its own process group and the default dispositions, which is
  # what a real terminal does when the operator presses Ctrl+C.
  set -m
  bash "$TMP/drv-signal.sh" "$SB" >"$TMP/sig-$sig.log" 2>&1 < <(sleep 60) &
  drvpid=$!
  set +m

  ready=0
  for _ in $(seq 1 80); do
    grep -q 'Reproduce the problem' "$TMP/sig-$sig.log" 2>/dev/null && { ready=1; break; }
    kill -0 "$drvpid" 2>/dev/null || break
    sleep 0.5
  done
  if (( ! ready )); then
    t_bad "fd1_signal_${sig}_reached_capture_window"
    kill -KILL "$drvpid" 2>/dev/null || true
  else
    t_ok "fd1_signal_${sig}_reached_capture_window"
    kill -"$sig" "$drvpid" 2>/dev/null || true

    # Independent watchdog: bounded poll, then force-kill and fail.
    exited=0
    for _ in $(seq 1 30); do
      kill -0 "$drvpid" 2>/dev/null || { exited=1; break; }
      sleep 0.5
    done
    if (( exited )); then
      t_ok "fd1_signal_${sig}_process_exits_promptly"
    else
      t_bad "fd1_signal_${sig}_process_exits_promptly: still running 15s after SIG$sig"
      kill -KILL "$drvpid" 2>/dev/null || true
      for _ in $(seq 1 20); do kill -0 "$drvpid" 2>/dev/null || break; sleep 0.5; done
    fi
  fi
  wait "$drvpid" 2>/dev/null; drv_rc=$?
  sleep 1

  (( drv_rc != 0 )) \
    && t_ok "fd1_signal_${sig}_nonzero_exit (rc=$drv_rc)" \
    || t_bad "fd1_signal_${sig}_nonzero_exit: reported success after a signal"

  own_td=$(pgrep -f "$SB/bin/tcpdump" 2>/dev/null | wc -l)
  (( own_td == 0 )) && t_ok "fd1_signal_${sig}_owned_tcpdump_terminated" \
    || t_bad "fd1_signal_${sig}_owned_tcpdump_terminated: $own_td still running"

  if kill -0 "$decoy_pid" 2>/dev/null; then
    t_ok "fd1_signal_${sig}_unrelated_capture_survived"
  else
    t_bad "fd1_signal_${sig}_unrelated_capture_survived: an unrelated capture was killed"
  fi
  kill -TERM "$decoy_pid" 2>/dev/null || true; wait "$decoy_pid" 2>/dev/null || true

  leftover="$(comm -13 <(printf '%s\n' "$staging_before") <(staging_now) | sed '/^$/d' | wc -l)"
  (( leftover == 0 )) && t_ok "fd1_signal_${sig}_staging_removed" \
    || t_bad "fd1_signal_${sig}_staging_removed: $leftover new staging dir(s) left"

  arch="$(find "$SB/opt/logs/bundles" -name 'twebproxy-field-*.tar.gz' 2>/dev/null | wc -l)"
  (( arch == 0 )) && t_ok "fd1_signal_${sig}_no_archive_produced" \
    || t_bad "fd1_signal_${sig}_no_archive_produced: an archive was completed after the signal"

  # No post-signal collection: the "after" snapshot must never have been taken.
  post="$(find "$SB/opt/logs/runtime" -name '*-field-after.log' 2>/dev/null | wc -l)"
  (( post == 0 )) && t_ok "fd1_signal_${sig}_no_post_signal_collection" \
    || t_bad "fd1_signal_${sig}_no_post_signal_collection: after-snapshot was collected"

  # Deterministic discriminator: a handler that merely cleans up and returns
  # leaves no trace of a cancellation and resumes the workflow instead.
  if grep -qiE 'cancel|отмен' "$TMP/sig-$sig.log" 2>/dev/null; then
    t_ok "fd1_signal_${sig}_reports_cancellation"
  else
    t_bad "fd1_signal_${sig}_reports_cancellation: no cancellation notice; handler returned into the workflow"
  fi
  if grep -q 'Collecting final state' "$TMP/sig-$sig.log" 2>/dev/null; then
    t_bad "fd1_signal_${sig}_no_collection_after_signal: collection started after the signal"
  else
    t_ok "fd1_signal_${sig}_no_collection_after_signal"
  fi

  partial="$(find "$SB/opt/logs/bundles" \( -name '*.tar.gz' -o -name '*.partial' \) 2>/dev/null | wc -l)"
  (( partial == 0 )) && t_ok "fd1_signal_${sig}_no_partial_archive_left" \
    || t_bad "fd1_signal_${sig}_no_partial_archive_left: $partial truncated archive(s)"

  n_root=$(root_diag_count)
  (( n_root == 0 )) && t_ok "fd1_signal_${sig}_no_root_level_files" \
    || t_bad "fd1_signal_${sig}_no_root_level_files: $n_root created at / (empty staging prefix)"
  root_diag_clean
done

grep -qE '^[^#]*\bpkill\b' "$MGR" && t_bad "fd1_never_uses_pkill" || t_ok "fd1_never_uses_pkill"
grep -qE '^[^#]*\bkillall\b' "$MGR" && t_bad "fd1_never_uses_killall" || t_ok "fd1_never_uses_killall"

# =====================================================================
# 10b. manager session transcript is included when the manager log exists
# =====================================================================
mkdrv drv-session.sh 'CURRENT_LOG="$SB/opt/logs/manager/session.log"
printf "manager transcript line -S %s\n" "$FAKE_MT_SECRET" > "$CURRENT_LOG"
field_report_cmd alpha.example --instant'
run drv-session.sh session </dev/null
B="$(bundle_of "$SB")"
if [[ -n "$B" ]]; then D="$TMP/x-session"; extract "$B" "$D"
  [[ -f "$D/manager-session.log" ]] \
    && t_ok "fd1_manager_session_log_included" || t_bad "fd1_manager_session_log_included"
  ( cd "$D" && sha256sum -c MANIFEST.sha256 >/dev/null 2>&1 ) \
    && t_ok "fd1_session_manifest_verifies" || t_bad "fd1_session_manifest_verifies"
else t_bad "fd1_manager_session_archive_produced"; fi

# =====================================================================
# 11. existing logs-pack remains operational and unchanged in shape
# =====================================================================
# logs-pack must remain semantically unchanged by this pass. Asserting "it must
# succeed" would be wrong here: logs_pack_cmd calls collect_runtime_snapshot
# unguarded, and that collector returns non-zero in this stubbed sandbox. That
# is pre-existing behaviour, so the meaningful assertion is PARITY against the
# fieldfix2 baseline manager rather than an absolute outcome.
BASELINE_MGR=""
for z in "$ROOT/TWebProxy-Manager-v0.2.8-dpi-beta-fieldfix2.zip"; do
  [[ -f "$z" ]] || continue
  rm -rf "$TMP/basezip"; mkdir -p "$TMP/basezip"
  if tar -tzf /dev/null >/dev/null 2>&1 || true; then :; fi
  ( cd "$TMP/basezip" && unzip -q "$z" ) 2>/dev/null || continue
  BASELINE_MGR="$(find "$TMP/basezip" -name twebproxy-manager.sh | head -n1)"
done
mkdrv drv-logspack.sh 'logs_pack_cmd'
if [[ -n "$BASELINE_MGR" && -f "$BASELINE_MGR" ]]; then
  run drv-logspack.sh logspack </dev/null
  cur_rc=$RC
  cur_n=$(find "$SB/opt/logs/bundles" -name 'twebproxy-logs-*.tar.gz' 2>/dev/null | wc -l)
  saved_mgr="$MGR"; MGR="$BASELINE_MGR"; mkdrv drv-logspack-base.sh 'logs_pack_cmd'
  run drv-logspack-base.sh logspackbase </dev/null
  base_rc=$RC
  base_n=$(find "$SB/opt/logs/bundles" -name 'twebproxy-logs-*.tar.gz' 2>/dev/null | wc -l)
  MGR="$saved_mgr"
  (( cur_rc == base_rc )) \
    && t_ok "fd1_logs_pack_exit_parity_with_baseline (rc=$cur_rc)" \
    || t_bad "fd1_logs_pack_exit_parity_with_baseline: baseline=$base_rc current=$cur_rc"
  (( cur_n == base_n )) \
    && t_ok "fd1_logs_pack_bundle_parity_with_baseline (bundles=$cur_n)" \
    || t_bad "fd1_logs_pack_bundle_parity_with_baseline: baseline=$base_n current=$cur_n"
  a="$(awk '/^logs_pack_cmd\(\) \{/,/^\}$/' "$BASELINE_MGR" | sha256sum | cut -c1-32)"
  b="$(awk '/^logs_pack_cmd\(\) \{/,/^\}$/' "$MGR" | sha256sum | cut -c1-32)"
  [[ "$a" == "$b" ]] \
    && t_ok "fd1_logs_pack_body_byte_identical" || t_bad "fd1_logs_pack_body_byte_identical"
else
  t_skip "fd1_logs_pack_parity: fieldfix2 baseline ZIP not available beside the tests"
fi

# =====================================================================
# 11/12/13. usage, dispatch parity, syntax
# =====================================================================
mkdrv drv-badflag.sh 'field_report_cmd alpha.example --bogus || printf "REJECTED rc=%s\n" "$?"'
run drv-badflag.sh badflag </dev/null
grep -qi 'Usage: twebproxy field-report' <<<"$OUT" \
  && t_ok "fd1_unknown_flag_usage_message" || t_bad "fd1_unknown_flag_usage_message: $(tail -2 <<<"$OUT" | tr '\n' ' ')"
grep -q 'field-report) field_report_cmd "\$@" ;;' "$MGR" \
  && t_ok "fd1_cli_dispatches_to_core" || t_bad "fd1_cli_dispatches_to_core"
grep -q 'field_report_cmd "\$host"; pause;;' "$MGR" \
  && t_ok "fd1_tui_dispatches_to_same_core" || t_bad "fd1_tui_dispatches_to_same_core"
[[ "$(grep -c 'field_report_cmd()' "$MGR")" == 1 ]] \
  && t_ok "fd1_single_core_implementation" || t_bad "fd1_single_core_implementation"
grep -q 'field-report HOST \[--instant\] \[--keep-pcap\]' "$MGR" \
  && t_ok "fd1_usage_documents_command" || t_bad "fd1_usage_documents_command"
bash -n "$MGR" && t_ok "fd1_bash_n_manager" || t_bad "fd1_bash_n_manager"
# read-only guarantee: the field path must not mutate proxy/firewall/DPI state
awk '/^field_report_cmd\(\) \{/,/^\}$/' "$MGR" > "$TMP/fnbody.txt"
awk '/^field_collect_nft\(\) \{/,/^\}$/' "$MGR" >> "$TMP/fnbody.txt"
if grep -qE 'systemctl (restart|reload|start|stop|enable|disable)|nft (add|delete|flush|-f)|dpi_transaction_|dpi_reconcile_runtime|certbot|rebuild_firewall|configure_tls' "$TMP/fnbody.txt"; then
  t_bad "fd1_field_path_is_read_only: mutating call found"
else
  t_ok "fd1_field_path_is_read_only"
fi

printf 'fd1: pass=%s fail=%s neel=%s\n' "$pass" "$fail" "$neel"
(( fail == 0 ))
