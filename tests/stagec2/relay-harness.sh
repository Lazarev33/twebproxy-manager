#!/usr/bin/env bash
# Behavioral sandbox for the Stage C2 relay lifecycle regressions.
#
# Extends tests/stagec1/state-harness.sh (same rules: the manager code under
# test is unmodified, commands run through c1_run/c1_eval in a separate bash
# process with production `set -Eeuo pipefail`, nothing outside $TMP is read or
# written). Added host-boundary models:
#   - the installed relay binary ($TPROXY_BIN) is a script carrying a build
#     marker ("# relay-build: <name>"); `go test`/`go build` produce a candidate
#     with marker $C2_BUILD (default "candidate");
#   - systemctl start/restart of twebproxy@HOST records which build the relay
#     runs and its admin port; curl http://127.0.0.1:<admin>/readyz answers from
#     that record.
# This proves control flow, binary/state postconditions and reported results,
# not real systemd, curl or Go behaviour.
#
# Faults (files in $TMP):
#   fail-go-test, fail-go-build          upstream test / build fails
#   check-fail-<build>-<host>            `<build> -check` rejects that host's config
#   fail-restart-<unit>                  systemctl start/restart/enable of <unit> fails
#   fail-start-<build>-<host>            starting the relay of <host> fails while <build> is installed
#   fail-stop-<unit>                     (C1 model) stop/disable of <unit> fails
#   unready-<build>-<host>               relay of <host> running <build> never gets ready
#   slow-<host>                          the first 2 probes after each start are refused
#   crash-<build>-<host>                 ready once, then the unit is failed
#   fail-bin-write                       a write to $TPROXY_BIN* stops half-way (ENOSPC-like)
# Barrier: C2_AT_PROBE=<name>:<host> parks the first readiness probe of <host>
# (touch <name>.reached, write the manager pid to <name>.pid, wait for <name>.go).

C2_HARNESS="${BASH_SOURCE[0]}"
# shellcheck source=/dev/null
source "$(dirname "$C2_HARNESS")/../stagec1/state-harness.sh"

c2_harness() {
  export C2_HARNESS
  if [[ ! -e "$TMP/bin/.c2-models" ]]; then
    install -d -m 0700 "$TMP/bin" "$TMP/units"
    ( C1_ROOT="$TMP"; c1_write_models )
    c2_write_models
    c2_relay_binary old > "$TMP/bin/tproxy-server"; chmod 0755 "$TMP/bin/tproxy-server"
    : > "$TMP/bin/.c2-models"
  fi
  export C2_TPROXY_BIN="$TMP/bin/tproxy-server" C2_INSTANCES_DIR="$TMP/etc/instances"
  c1_harness
  TPROXY_SRC="$TMP/tproxy-src"; GO_BIN="$TMP/bin/go"; install -d -m 0700 "$TPROXY_SRC"
  # Network, package and host-install steps are never reached from a test.
  install_base_deps() { :; }
  ensure_go() { GO_BIN="$TMP/bin/go"; }
  sync_tproxy_upstream() { UPSTREAM_COMMIT="${C2_UPSTREAM_COMMIT:-1111111111111111111111111111111111111111}"; }
  install_manager_copy() { :; }
  c1_instance_stubs
  c2_faults
}

c2_run() { bash -c 'source "$C2_HARNESS"; c2_harness; set -Eeuo pipefail; "$@"' c2-run "$@"; }
c2_eval() { bash -c 'source "$C2_HARNESS"; c2_harness; set -Eeuo pipefail; eval "$1"' c2-eval "$1"; }

# A write to the relay binary path (or a temporary file next to it) that stops
# half-way: the destination is left truncated and the command fails.
c2_faults() {
  c2_bin_write_fault() { # $1=src $2=dest
    [[ -e "$TMP/fail-bin-write" && "$2" == "$TPROXY_BIN"* ]] || return 1
    rm -f "$TMP/fail-bin-write"; head -c 64 "$1" > "$2"; echo "model: write to $2 interrupted" >&2
  }
  install() {
    local a=("$@"); local n=${#a[@]}
    if (( n >= 2 )) && c2_bin_write_fault "${a[n-2]}" "${a[n-1]}"; then return 1; fi
    command install "$@"
  }
  cp() {
    local a=("$@"); local n=${#a[@]}
    if (( n >= 2 )) && c2_bin_write_fault "${a[n-2]}" "${a[n-1]}"; then return 1; fi
    command cp "$@"
  }
}

c2_relay_binary() { # $1=build name -> model relay binary on stdout
  cat <<SH
#!/bin/bash
# relay-build: $1
build=$1
SH
  cat <<'SH'
# -check model: config and profiles must parse, profile names unique,
# injectable per-build/per-host rejection.
[[ ! -e "$C1_ROOT/fail-validate" ]] || { echo 'model: injected validation failure' >&2; exit 1; }
cfg="" prof=""
while (( $# )); do case "$1" in -config) cfg="$2"; shift;; -profiles-file) prof="$2"; shift;; esac; shift; done
host="$(basename "$(dirname "$cfg")")"
[[ ! -e "$C1_ROOT/check-fail-$build-$host" ]] || { echo "model: $build rejects $host" >&2; exit 1; }
jq -e . "$cfg" >/dev/null && jq -e '(.profiles|length) >= 1 and ((.profiles|map(.name)|unique|length) == (.profiles|length))' "$prof" >/dev/null
SH
}

c2_write_models() {
  cat > "$TMP/bin/go" <<'SH'
#!/bin/bash
# Go toolchain model: `go test ./...`, `go build ... -o OUT ./cmd/tproxy-server`.
printf 'go %s\n' "$*" >> "$C1_ROOT/events"
case "$1" in
  test) [[ ! -e "$C1_ROOT/fail-go-test" ]] || { echo 'model: upstream test failed' >&2; exit 1; }; exit 0;;
  build)
    [[ ! -e "$C1_ROOT/fail-go-build" ]] || { echo 'model: build failed' >&2; exit 1; }
    out=""; while (( $# )); do [[ "$1" == -o ]] && { out="$2"; shift; }; shift; done
    [[ -n "$out" ]] || exit 2
    source "$C2_HARNESS"; c2_relay_binary "${C2_BUILD:-candidate}" > "$out"; exit 0;;
  version) echo 'go version model'; exit 0;;
esac
exit 0
SH
  # systemctl: C1 unit model plus relay units. A started twebproxy@HOST records
  # the build of the installed binary at start time and the instance admin port.
  mv "$TMP/bin/systemctl" "$TMP/bin/systemctl-c1"
  cat > "$TMP/bin/systemctl" <<'SH'
#!/bin/bash
args=("$@"); unit="${args[-1]}"
if [[ "$unit" == twebproxy@*.service ]]; then
  printf '%s\n' "$*" >> "$C1_ROOT/systemctl.calls"
  printf 'systemctl %s\n' "$*" >> "$C1_ROOT/events"
  host="${unit#twebproxy@}"; host="${host%.service}"
  quiet=0; [[ "${2:-}" == --quiet ]] && quiet=1
  failed() { rm -f "$C1_ROOT/units/$unit"; echo failed > "$C1_ROOT/state-$unit"; echo "model: $1" >&2; exit 1; }
  start() {
    [[ ! -e "$C1_ROOT/fail-restart-$unit" ]] || failed "start of $unit failed"
    [[ -x "$C2_TPROXY_BIN" ]] && b="$(sed -n 's/^# relay-build: //p' "$C2_TPROXY_BIN")" && [[ -n "$b" ]] ||
      failed "$unit exec failed"
    [[ ! -e "$C1_ROOT/fail-start-$b-$host" ]] || failed "$unit with build $b failed to start"
    admin="$(sed -n 's/^ADMIN_PORT=//p' "$C2_INSTANCES_DIR/$host/instance.env" 2>/dev/null)"
    rm -f "$C1_ROOT/state-$unit"
    printf 'BUILD=%s\nADMIN=%s\nPROBES=0\n' "$b" "$admin" > "$C1_ROOT/units/$unit"
    printf 'relay %s started build=%s\n' "$host" "$b" >> "$C1_ROOT/events"
  }
  case "$1" in
    reset-failed|daemon-reload) exit 0;;
    enable) [[ "${2:-}" == --now ]] || exit 0; [[ -e "$C1_ROOT/units/$unit" ]] || start; exit 0;;
    start) [[ -e "$C1_ROOT/units/$unit" ]] || start; exit 0;;
    restart) start; exit 0;;
    disable|stop)
      [[ ! -e "$C1_ROOT/fail-stop-$unit" ]] || { echo "model: stop of $unit failed" >&2; exit 1; }
      rm -f "$C1_ROOT/units/$unit" "$C1_ROOT/state-$unit"; exit 0;;
    is-active)
      if [[ -e "$C1_ROOT/state-$unit" ]]; then (( quiet )) || cat "$C1_ROOT/state-$unit"; exit 3; fi
      [[ -e "$C1_ROOT/units/$unit" ]] || { (( quiet )) || echo inactive; exit 3; }
      (( quiet )) || echo active; exit 0;;
    *) exit 0;;
  esac
fi
exec "$(dirname "$0")/systemctl-c1" "$@"
SH
  cat > "$TMP/bin/curl" <<'SH'
#!/bin/bash
# Relay admin endpoint model: http://127.0.0.1:<admin>/(readyz|healthz).
url="${*: -1}"
[[ "$url" =~ ^http://127\.0\.0\.1:([0-9]+)/(readyz|healthz)$ ]] || exit 0
port="${BASH_REMATCH[1]}"
printf 'curl %s\n' "$url" >> "$C1_ROOT/events"
f=""; for u in "$C1_ROOT"/units/twebproxy@*.service; do
  [[ -f "$u" ]] && grep -qx "ADMIN=$port" "$u" && { f="$u"; break; }
done
if [[ -n "${C2_AT_PROBE:-}" && -n "$f" ]]; then
  name="${C2_AT_PROBE%%:*}"; h="${C2_AT_PROBE#*:}"; uh="${f##*/twebproxy@}"; uh="${uh%.service}"
  if [[ "$uh" == "$h" && ! -e "$C1_ROOT/$name.reached" ]]; then
    echo "$PPID" > "$C1_ROOT/$name.pid"; : > "$C1_ROOT/$name.reached"
    for ((i = 0; i < 600; i++)); do [[ -e "$C1_ROOT/$name.go" ]] && break; sleep 0.05; done
  fi
fi
[[ -n "$f" && -f "$f" ]] || exit 7                     # nothing listening: connection refused
host="${f##*/twebproxy@}"; host="${host%.service}"
build="$(sed -n 's/^BUILD=//p' "$f")"; probes="$(sed -n 's/^PROBES=//p' "$f")"
sed -i "s/^PROBES=.*/PROBES=$((probes + 1))/" "$f"
if [[ -e "$C1_ROOT/slow-$host" ]] && (( probes < 2 )); then exit 7; fi
[[ ! -e "$C1_ROOT/unready-$build-$host" ]] || exit 22
if [[ -e "$C1_ROOT/crash-$build-$host" ]] && (( probes >= 1 )); then
  rm -f "$f"; echo failed > "$C1_ROOT/state-twebproxy@$host.service"; exit 7
fi
exit 0
SH
  chmod 0755 "$TMP/bin/go" "$TMP/bin/systemctl" "$TMP/bin/curl"
}

# Helpers for assertions.
c2_build_of() { sed -n 's/^# relay-build: //p' "$1" 2>/dev/null; }          # $1=binary
c2_relay_build() { sed -n 's/^BUILD=//p' "$TMP/units/twebproxy@$1.service" 2>/dev/null; }   # $1=host
c2_relay_up() { [[ -f "$TMP/units/twebproxy@$1.service" ]]; }
