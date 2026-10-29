#!/usr/bin/env bash
# Behavioral sandbox for the Stage E operations and diagnostics regressions.
#
# Extends tests/staged/frontend-harness.sh (same rules: the manager code under
# test is unmodified, commands run through e_run/e_eval in a separate bash
# process with production `set -Eeuo pipefail`, nothing outside $TMP is read or
# written, the real audit/diagnose/snapshot code runs). Added host-boundary
# models in $TMP/bin: nft, ip, hostnamectl, dig, getent, openssl s_client (the
# rest of openssl is real), plus fault layers over systemctl, curl, journalctl
# and tar. DPI_NFT_BIN is rebound to the nft model. fetch_public_leaf_cert (a
# network boundary) answers from $TMP/public-cert-<host>.
#
# Faults (files in $TMP):
#   hang-systemctl     systemctl is-active/status/show/cat never return
#   fail-systemctl     systemctl is-active/status fail with no output (no bus)
#   hang-admin         the relay admin endpoint accepts but never answers; curl
#                      returns only when given --max-time (exit 28)
#   hang-journalctl, hang-nft, hang-dig, hang-hostnamectl   never return
#   fail-https         public strict HTTPS check fails
#   fail-copy-<name>   cp of a file named <name> fails (vanished or unreadable log)
# E_PIDFILE=<file> receives the pid of the manager process (for signal cases).
# Barrier: E_AT_TAR=<name> parks the first tar run (pid of the manager in name.pid).

E_HARNESS="${BASH_SOURCE[0]}"
# shellcheck source=/dev/null
source "$(dirname "$E_HARNESS")/../staged/frontend-harness.sh"

e_harness() {
  export E_HARNESS
  d_harness
  if [[ ! -e "$TMP/bin/.e-models" ]]; then
    e_write_models
    : > "$TMP/bin/.e-models"
  fi
  DPI_NFT_BIN="$TMP/bin/nft"
  # Sourced inside a function, the manager's top-level `declare -A` catalog
  # became local; the human renderers need it global.
  declare -gA UI_EN=() UI_RU=()
  # Stage E exercises the real audit and the real prompts (the C1 harness
  # replaces them with scripted answers): input comes from stdin.
  eval "$(TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 bash -c 'source "$1" >/dev/null 2>&1; trap - ERR
    declare -f audit_instance_impl ask yesno choose menu_choose pause' _ "$MGR")"
  fetch_public_leaf_cert() { [[ -f "$TMP/public-cert-$1" ]] && command cp "$TMP/public-cert-$1" "$2"; }
  # fail-copy-<name>: copying a file with that basename fails (vanished/unreadable).
  eval "e_prev_cp() $(declare -f cp | tail -n +2)"
  cp() {
    local a
    for a in "$@"; do
      [[ "$a" == -* || ! -e "$TMP/fail-copy-${a##*/}" ]] || { echo "cp: cannot open '$a': model failure" >&2; return 1; }
    done
    e_prev_cp "$@"
  }
  [[ -z "${E_PIDFILE:-}" ]] || echo "$$" > "$E_PIDFILE"
}

e_run() { bash -c 'source "$E_HARNESS"; e_harness; set -Eeuo pipefail; "$@"' e-run "$@"; }
e_eval() { bash -c 'source "$E_HARNESS"; e_harness; set -Eeuo pipefail; eval "$1"' e-eval "$1"; }

e_write_models() {
  local hang='exec sleep 3600'
  cat > "$TMP/bin/nft" <<SH
#!/bin/bash
printf 'nft %s\n' "\$*" >> "\$D_ROOT/events"
[[ ! -e "\$D_ROOT/hang-nft" ]] || $hang
case "\$*" in
  *'list table inet twebproxy_backend'*)
    ports="\$(sed -n 's/^MTPROXY_\(CLIENT\|STATS\)_PORT=//p' "\$C1_BACKENDS_DIR"/*.env 2>/dev/null | sort -n | paste -sd, -)"
    printf 'table inet twebproxy_backend {\n  chain input {\n    iifname != "lo" tcp dport { %s } drop\n  }\n}\n' "\$ports";;
  *list*) exit 1;;
esac
exit 0
SH
  cat > "$TMP/bin/ip" <<'SH'
#!/bin/bash
case "$*" in
  *'-br addr'*) echo 'lo UNKNOWN 127.0.0.1/8';;
  *'table all'*) echo 'default via 192.0.2.1 dev eth0'; echo 'local 127.0.0.1 dev lo table local proto kernel scope host src 127.0.0.1'; echo 'broadcast 192.0.2.255 dev eth0 table local';;
  *route*) echo 'default via 192.0.2.1 dev eth0';;
esac
exit 0
SH
  cat > "$TMP/bin/hostnamectl" <<SH
#!/bin/bash
[[ ! -e "\$D_ROOT/hang-hostnamectl" ]] || $hang
echo ' Static hostname: model'
SH
  cat > "$TMP/bin/dig" <<SH
#!/bin/bash
printf 'dig %s\n' "\$*" >> "\$D_ROOT/events"
[[ ! -e "\$D_ROOT/hang-dig" ]] || $hang
exit 0
SH
  cat > "$TMP/bin/getent" <<'SH'
#!/bin/bash
exit 2
SH
  cat > "$TMP/bin/openssl" <<'SH'
#!/bin/bash
# s_client is a network boundary: never connect; everything else is real openssl.
[[ "${1:-}" == s_client ]] && { echo 'model: connect: no route' >&2; exit 1; }
exec /usr/bin/openssl "$@"
SH
  mv "$TMP/bin/systemctl" "$TMP/bin/systemctl-d"
  cat > "$TMP/bin/systemctl" <<SH
#!/bin/bash
case "\${1:-}" in
  is-active|status|show|cat)
    [[ ! -e "\$D_ROOT/hang-systemctl" ]] || { printf 'systemctl %s (hung)\n' "\$*" >> "\$D_ROOT/events"; $hang; }
    if [[ -e "\$D_ROOT/fail-systemctl" && "\$1" != cat && "\$1" != show ]]; then
      echo 'System has not been booted with systemd as init system (PID 1). Can'"'"'t operate.' >&2; exit 1
    fi;;
esac
exec "\$(dirname "\$0")/systemctl-d" "\$@"
SH
  mv "$TMP/bin/curl" "$TMP/bin/curl-c2"
  cat > "$TMP/bin/curl" <<'SH'
#!/bin/bash
url="${*: -1}"
if [[ -e "$D_ROOT/hang-admin" && "$url" =~ ^http://127\.0\.0\.1:[0-9]+/(healthz|readyz)$ ]]; then
  t=""; a=("$@"); for ((i = 0; i < ${#a[@]}; i++)); do [[ "${a[i]}" == --max-time ]] && t="${a[i+1]}"; done
  [[ -n "$t" ]] || exec sleep 3600
  sleep "$t"; exit 28
fi
if [[ -e "$D_ROOT/fail-https" && "$url" == https://* ]]; then exit 35; fi
exec "$(dirname "$0")/curl-c2" "$@"
SH
  mv "$TMP/bin/journalctl" "$TMP/bin/journalctl-c1"
  cat > "$TMP/bin/journalctl" <<SH
#!/bin/bash
[[ ! -e "\$D_ROOT/hang-journalctl" ]] || $hang
exec "\$(dirname "\$0")/journalctl-c1" "\$@"
SH
  # ss: honour the "sport = :PORT" filter the manager uses (the C1 model prints everything).
  mv "$TMP/bin/ss" "$TMP/bin/ss-d"
  cat > "$TMP/bin/ss" <<'SH'
#!/bin/bash
if [[ "$*" =~ sport\ =\ :([0-9]+) ]]; then
  port="${BASH_REMATCH[1]}"
  [[ "$port" != 80 && "$port" != 443 ]] || exec "$(dirname "$0")/ss-d" "$@"
  "$(dirname "$0")/ss-c1" "$@" | awk -v p=":$port" '$4 ~ (p "$")'
  exit 0
fi
exec "$(dirname "$0")/ss-d" "$@"
SH
  cat > "$TMP/bin/tar" <<'SH'
#!/bin/bash
"$D_ROOT/bin/d-barrier" "${E_AT_TAR:-}"
exec /usr/bin/tar "$@"
SH
  chmod 0755 "$TMP"/bin/*
}
