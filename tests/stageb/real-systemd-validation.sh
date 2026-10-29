#!/usr/bin/env bash
# Disposable lab host ONLY (tests/LAB.md); the former --disposable-vm argument
# alone no longer authorizes it. Creates one temporary /run systemd unit; all nft
# activity (including the systemd helper) is inside a separate network namespace.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
source "$ROOT/tests/lib/lab-gate.sh"
lab_gate_or_exit stageb-real-systemd
if [[ "${2:-}" != --inside ]]; then
  command -v nft >/dev/null || { echo 'NOT_EXECUTED_ENVIRONMENT_LIMITATION: nft unavailable'; exit 77; }
  timeout 5 systemctl list-units --no-legend >/dev/null ||
    { echo 'NOT_EXECUTED_ENVIRONMENT_LIMITATION: running systemd unavailable'; exit 77; }
  timeout 5 unshare --net true ||
    { echo 'NOT_EXECUTED_ENVIRONMENT_LIMITATION: isolated namespace unavailable'; exit 77; }
  export STAGEB_PARENT_NETNS="$(readlink /proc/self/ns/net)"
  exec timeout 240 unshare --net bash "$0" "$MGR" --inside
fi
[[ -n "${STAGEB_PARENT_NETNS:-}" && "$(readlink /proc/self/ns/net)" != "$STAGEB_PARENT_NETNS" ]] ||
  { echo 'FAIL: refusing host namespace'; exit 1; }
TMP="$(mktemp -d /tmp/twebproxy-stageb-systemd.XXXXXX)"
unit="twebproxy-stageb-$BASHPID.service"
unit_path="/run/systemd/system/$unit"
[[ ! -e "$unit_path" && ! -L "$unit_path" ]]
cleanup() {
  rc=$?; trap - EXIT
  timeout 15 systemctl stop "$unit" || rc=1
  rm -f -- "$unit_path" || rc=1
  timeout 15 systemctl daemon-reload || rc=1
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
export TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1
source "$MGR"; trap - ERR
BASE_DIR="$TMP/etc"; BACKENDS_DIR="$BASE_DIR/backends"; FIREWALL_FILE="$BASE_DIR/firewall.nft"
LIBEXEC_DIR="$TMP/libexec"; SYSTEMD_DIR="$TMP/systemd"
install -d -m 0700 "$BASE_DIR" "$BACKENDS_DIR" "$LIBEXEC_DIR" "$SYSTEMD_DIR"
write_backend_firewall_helper
write_backend_firewall_unit
# Identical ExecStart/Reload/Stop semantics; only this test unit enters our netns.
sed "/^Type=oneshot$/a NetworkNamespacePath=/proc/$BASHPID/ns/net" \
  "$SYSTEMD_DIR/twebproxy-firewall.service" > "$unit_path"
chmod 0644 "$unit_path"
timeout 15 systemctl daemon-reload
printf 'MTPROXY_CLIENT_PORT=23980\nMTPROXY_STATS_PORT=28980\n' > "$BACKENDS_DIR/a.env"
timeout 45 systemctl start "$unit"
nft -j -n list table inet twebproxy_backend > "$TMP/initial"
[[ "$(backend_fw_ports_json "$TMP/initial")" == 23980,28980 ]]
echo 'PASS real-systemd-start'
printf 'MTPROXY_CLIENT_PORT=23981\nMTPROXY_STATS_PORT=28981\n' > "$BACKENDS_DIR/b.env"
timeout 45 systemctl reload "$unit"
nft -j -n list table inet twebproxy_backend > "$TMP/multiple"
[[ "$(backend_fw_ports_json "$TMP/multiple")" == 23980,23981,28980,28981 ]]
echo 'PASS real-systemd-reload'
printf 'MTPROXY_CLIENT_PORT=23982\n' > "$BACKENDS_DIR/broken.env"
if timeout 45 systemctl reload "$unit"; then echo 'FAIL invalid reload returned success'; exit 1; fi
nft -j -n list table inet twebproxy_backend > "$TMP/after"
cmp "$TMP/multiple" "$TMP/after"
echo 'PASS real-systemd-invalid-reload-keeps-isolation'
if timeout 45 systemctl restart "$unit"; then echo 'FAIL invalid restart returned success'; exit 1; fi
nft -j -n list table inet twebproxy_backend > "$TMP/after"
cmp "$TMP/multiple" "$TMP/after"
echo 'PASS real-systemd-no-ExecStop-gap'
rm "$BACKENDS_DIR/broken.env"
timeout 45 systemctl start "$unit"
timeout 15 systemctl stop "$unit"
nft -j -n list table inet twebproxy_backend > "$TMP/after"
[[ "$(backend_fw_ports_json "$TMP/after")" == 23980,23981,28980,28981 ]]
echo 'PASS real-systemd-stop-retains-isolation'
