#!/usr/bin/env bash
# Shared sandbox for the Stage A DPI regressions.
#
# Deliberately thin: it stands up the disposable directories, an external nft
# mock and the systemctl model, and then binds the manager's own path variables
# to them. Everything the regressions actually exercise - state publication,
# verification, cleanup, pruning, the public CLI - stays production code.
#
#   dpi_harness_env  "$TMP"          # BEFORE sourcing the manager
#   source "$MGR"
#   dpi_harness_bind "$ROOT" "$TMP"  # AFTER sourcing the manager
#
# The nft mock is a real external program, so a pipeline that reads from it has
# a real producer process that can really receive SIGPIPE. MOCK_NFT_PAD_LINES
# makes its `list table` output arbitrarily large, which is what a busy ruleset
# looks like and what makes the SIGPIPE window deterministic.

dpi_harness_env() {
  local tmp="${1:?dpi_harness_env: TMP required}"
  export TWEBPROXY_NO_LOG=1
  export TWEBPROXY_TEST_NFT_JSON_MODEL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/nft-json-model.sh"
  export TWEBPROXY_UI_LANGUAGE=en
  export TWEBPROXY_LANGUAGE_FILE="$tmp/ui-language"
  export TWEBPROXY_DPI_DIR="$tmp/etc/twebproxy/dpi"
  export TWEBPROXY_DPI_NFQWS_BIN="$tmp/libexec/twebproxy-nfqws"
  export TWEBPROXY_DPI_NFQWS_SUM_FILE="$tmp/libexec/twebproxy-nfqws.sha256"
  export TWEBPROXY_DPI_DOC_DIR="$tmp/doc"
  export TWEBPROXY_NFT_BIN="$tmp/bin/nft"
  mkdir -p "$tmp/bin" "$tmp/systemd" "$tmp/libexec" "$tmp/doc" "$tmp/instances"
  export MOCK_NFT_LIVE="$tmp/live.nft"
  export MOCK_NFT_LOG="$tmp/nft.log"
  export MOCK_NFT_PAD_LINES="${MOCK_NFT_PAD_LINES:-0}"
  cat > "$tmp/bin/nft" <<'MOCK'
#!/usr/bin/env bash
# Minimal nft model. `list table` streams the live ruleset followed by
# MOCK_NFT_PAD_LINES of additional rule text, the way a real busy table does.
set -Eeuo pipefail
live="${MOCK_NFT_LIVE:?}"
[[ -z "${MOCK_NFT_LOG:-}" ]] || { printf '%q ' "$@" >> "$MOCK_NFT_LOG"; printf '\n' >> "$MOCK_NFT_LOG"; }
if [[ "${1:-}" == -j ]]; then
  shift; [[ "${1:-}" != -n ]] || shift
  [[ "${MOCK_NFT_LIST_FAIL:-0}" != 1 ]] || exit 77
  if [[ "${1:-}" == list && "${2:-}" == tables ]]; then
    if [[ -s "$live" ]]; then printf '%s\n' '{"nftables":[{"table":{"family":"ip","name":"twebproxy_dpi"}}]}'
    else printf '%s\n' '{"nftables":[]}'; fi
  elif [[ "${1:-}" == list && "${2:-}" == table ]]; then
    bash "${TWEBPROXY_TEST_NFT_JSON_MODEL:?}" "$live"
  else exit 2; fi
  exit
fi
if [[ "${1:-}" == -c && "${2:-}" == -f ]]; then
  [[ "${MOCK_NFT_CHECK_FAIL:-0}" != 1 ]] && grep -q '^table ip twebproxy_dpi {' "$3"
elif [[ "${1:-}" == -f ]]; then
  [[ "${MOCK_NFT_APPLY_FAIL:-0}" != 1 ]] || exit 1
  cp "$2" "$live"
elif [[ "${1:-}" == list && "${2:-}" == table ]]; then
  [[ -s "$live" ]] || exit 1
  cat "$live"
  n="${MOCK_NFT_PAD_LINES:-0}"
  (( n > 0 )) && awk -v n="$n" 'BEGIN{for(i=0;i<n;i++) printf "    ip saddr 203.0.113.%d tcp sport 443 counter comment \"pad:%d\"\n", i%254+1, i}'
  exit 0
elif [[ "${1:-}" == delete && "${2:-}" == table ]]; then
  [[ "${MOCK_NFT_DELETE_FAIL:-0}" != 1 ]] || exit 77
  rm -f "$live"
else
  exit 2
fi
MOCK
  chmod 0755 "$tmp/bin/nft"
}

dpi_harness_bind() {
  local root="${1:?}" tmp="${2:?}"
  BASE_DIR="$tmp/etc/twebproxy"
  # DPI_LOCK_FILE is expanded from BASE_DIR at source time, i.e. BEFORE this
  # function rebinds BASE_DIR. Left alone it keeps pointing at the production
  # /etc/twebproxy, so the tests would create and contend on the real host lock.
  DPI_LOCK_FILE="$tmp/etc/twebproxy/.dpi-mutation.lock"
  INSTANCES_DIR="$tmp/instances"
  PROJECT_DIR="$tmp/opt/twebproxy-manager"
  DPI_DIR="$TWEBPROXY_DPI_DIR"
  DPI_STATE_DIR="$DPI_DIR/scopes"
  DPI_NFT_FILE="$DPI_DIR/firewall.nft"
  DPI_NFT_BIN="$tmp/bin/nft"
  DPI_NFQWS_BIN="$tmp/libexec/twebproxy-nfqws"
  DPI_NFQWS_SUM_FILE="$tmp/libexec/twebproxy-nfqws.sha256"
  DPI_DOC_DIR="$tmp/doc"
  LIBEXEC_DIR="$tmp/libexec"
  SYSTEMD_DIR="$tmp/systemd"
  DPI_FIREWALL_UNIT=twebproxy-dpi-firewall.service
  DPI_NFQWS_UNIT=twebproxy-dpi-nfqws.service
  UI_LANGUAGE=en
  mkdir -p "$PROJECT_DIR"
  SYSTEMCTL_ACTIVE_DIR="$tmp/systemctl-active"
  SYSTEMCTL_LOG="$tmp/systemctl.log"
  SYSTEMCTL_TRACE="$tmp/systemctl-trace.log"
  # shellcheck source=/dev/null
  source "$root/tests/lib/systemctl-model.sh"
  id() { [[ "${1:-}" == twebproxy-dpi ]] && return 0; command id "$@"; }
  useradd() { return 0; }
  userdel() { return 0; }
}

# Writes a valid scope state file straight into the authoritative directory.
dpi_harness_seed_scope() {
  local ip="$1" mode="${2:-window1152}" host="${3:-alpha.example}"
  install -d -o root -g root -m 0700 "$DPI_STATE_DIR" || return 1
  dpi_write_scope_state "$DPI_STATE_DIR" "$ip" "$mode" "$host"
}
