#!/usr/bin/env bash
# Stage A.1 regression-first tests. Only the disposable harness paths mutate.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${2:-$ROOT/twebproxy-manager.sh}"
CASE="${1:-all}"
if [[ -f "$CASE" ]]; then MGR="$CASE"; CASE=all; fi
if [[ "$CASE" == all ]]; then
  failed=0
  for name in proposed-copy snapshot-copy partial-copy snapshot-partial prepare-mkdir interrupted-set interrupted-reinvoke interrupted-disable ambiguous-state corrupt-retired stock-binary stock-delete stock-query-failure stock-cli-error stock-other-scopes stock-symlink-libexec verify-prefix verify-mode verify-good verify-multi verify-parameters verify-json-fields tui-yes tui-no tui-default-no tui-eof tui-core-error tui-die-error tui-ru cli-no-flag cli-flag cli-not-local; do
    if timeout 45 bash "$0" "$name" "$MGR"; then printf 'PASS a1_%s\n' "$name"
    else printf 'FAIL a1_%s\n' "$name" >&2; failed=$((failed+1)); fi
  done
  printf 'stage-a1-targeted: failed=%s\n' "$failed"
  (( failed == 0 )); exit
fi
TMP="${A1_REUSE_TMP:-$(mktemp -d /tmp/twebproxy-a1-targeted.XXXXXX)}"
[[ -n "${A1_REUSE_TMP:-}" ]] || trap 'rm -rf -- "$TMP"' EXIT
export TWEBPROXY_ERROR_SNAPSHOT=1
source "$ROOT/tests/lib/dpi-harness.sh"
dpi_harness_env "$TMP"
source "$MGR"
trap - ERR
set +e
dpi_harness_bind "$ROOT" "$TMP"
disable_colors
need_root() { :; }; need_systemd() { :; }
dpi_local_ipv4_addresses() { printf '%s\n' 198.51.100.10 198.51.100.20; }
dpi_resolve_ipv4() { printf '%s' 198.51.100.10; }
dpi_hosts_for_ipv4() { printf '%s\n' alpha.example alias.example; }
instance_exists() { return 0; }
CURRENT_LOG="$TMP/trace.log"; : > "$CURRENT_LOG"
has() { [[ -f "$DPI_STATE_DIR/$1.env" ]] && dpi_load_scope_file "$DPI_STATE_DIR/$1.env"; }
seed() { dpi_transaction_set 198.51.100.10 mss88 alpha.example; }
case "$CASE" in
  proposed-copy|snapshot-copy|partial-copy|snapshot-partial|prepare-mkdir)
    seed || exit 90
    old_state="$(sha256sum "$DPI_STATE_DIR/198.51.100.10.env")"
    old_runtime="$(sha256sum "$MOCK_NFT_LIVE")"
    cp() {
      if [[ "$CASE" == snapshot-copy && "${1:-}" == -a && "${2:-}" == "$DPI_DIR" ]]; then return 73; fi
      if [[ "$CASE" == proposed-copy && "${1:-}" == -a && "${2:-}" == "$DPI_STATE_DIR/." ]]; then return 73; fi
      command cp "$@" || return
      if [[ "$CASE" == snapshot-partial && "${2:-}" == "$DPI_DIR" ]]; then
        command rm -f "${!#}/scopes/198.51.100.10.env"
        return 0
      fi
      if [[ "$CASE" == partial-copy && "${2:-}" == "$DPI_STATE_DIR/." ]]; then
        command rm -f "${!#}/198.51.100.10.env"
        return 0
      fi
    }
    mkdir() { [[ "$CASE" == prepare-mkdir && "${1:-}" == -p && "${2:-}" == */snapshot ]] && return 73; command mkdir "$@"; }
    TWEBPROXY_DPI_TEST_FAIL_POINT=""
    [[ "$CASE" == snapshot-copy ]] && TWEBPROXY_DPI_TEST_FAIL_POINT=after_state
    rc=0; dpi_transaction_set 198.51.100.20 window1152 beta.example || rc=$?
    printf 'operation_rc=%s\n' "$rc"
    (( rc != 0 )) && has 198.51.100.10 && [[ ! -e "$DPI_STATE_DIR/198.51.100.20.env" ]] &&
      [[ "$old_state" == "$(sha256sum "$DPI_STATE_DIR/198.51.100.10.env")" ]] &&
      [[ "$old_runtime" == "$(sha256sum "$MOCK_NFT_LIVE")" ]]
    ;;
  interrupted-reinvoke)
    seed || exit 90
    command mv -T "$DPI_STATE_DIR" "$DPI_DIR/.scopes.old"
    A1_REUSE_TMP="$TMP" timeout 30 bash "$0" interrupted-resume "$MGR" &&
      has 198.51.100.10 && has 198.51.100.20
    ;;
  interrupted-resume)
    dpi_transaction_set 198.51.100.20 window1152 beta.example
    ;;
  interrupted-set|interrupted-disable)
    seed || exit 90
    command mv -T "$DPI_STATE_DIR" "$DPI_DIR/.scopes.old"
    if [[ "$CASE" == interrupted-set ]]; then
      dpi_transaction_set 198.51.100.20 window1152 beta.example && has 198.51.100.10 && has 198.51.100.20
    else
      dpi_resolve_ipv4() { printf '%s' 198.51.100.20; }
      dpi_disable_cmd beta.example && has 198.51.100.10 && [[ ! -e "$DPI_DIR/.scopes.old" ]]
    fi
    ;;
  ambiguous-state|corrupt-retired)
    seed || exit 90
    command cp -a "$DPI_STATE_DIR" "$DPI_DIR/.scopes.old"
    if [[ "$CASE" == corrupt-retired ]]; then
      command rm -rf "$DPI_STATE_DIR"
      printf 'broken\n' > "$DPI_DIR/.scopes.old/198.51.100.10.env"
    fi
    before="$(sha256sum "$DPI_DIR/.scopes.old/198.51.100.10.env")"
    rc=0; dpi_transaction_set 198.51.100.20 window1152 beta.example || rc=$?
    (( rc != 0 )) && [[ -f "$DPI_DIR/.scopes.old/198.51.100.10.env" ]] &&
      [[ "$before" == "$(sha256sum "$DPI_DIR/.scopes.old/198.51.100.10.env")" ]]
    ;;
  stock-binary)
    printf corrupt > "$DPI_NFQWS_BIN"; printf checksum > "$DPI_NFQWS_SUM_FILE"
    dpi_disable_cmd alpha.example &&
      [[ ! -e "$DPI_NFQWS_BIN" && ! -e "$DPI_NFQWS_SUM_FILE" && ! -e "$MOCK_NFT_LIVE" ]]
    ;;
  stock-delete)
    seed || exit 90
    export MOCK_NFT_DELETE_FAIL=1
    # Fault only the exact delete; all other nft calls go to the same model.
    rc=0; dpi_cleanup_stock_runtime || rc=$?
    (( rc != 0 )) && [[ -s "$MOCK_NFT_LIVE" ]]
    ;;
  stock-cli-error)
    dpi_disable_reconcile_stock() { return 73; }
    ( dpi_disable_cmd alpha.example ) > "$TMP/cli.out" 2>&1; rc=$?
    (( rc != 0 )) && ! grep -q 'returned to STOCK' "$TMP/cli.out"
    ;;
  stock-query-failure)
    export MOCK_NFT_LIST_FAIL=1
    ( dpi_disable_cmd alpha.example ) > "$TMP/cli.out" 2>&1; rc=$?
    (( rc != 0 ))
    ;;
  stock-other-scopes)
    seed || exit 90
    before="$(sha256sum "$DPI_STATE_DIR/198.51.100.10.env")"
    dpi_resolve_ipv4() { printf '%s' 198.51.100.20; }
    dpi_disable_cmd beta.example && has 198.51.100.10 &&
      [[ "$before" == "$(sha256sum "$DPI_STATE_DIR/198.51.100.10.env")" ]] &&
      [[ -s "$MOCK_NFT_LIVE" ]]
    ;;
  stock-symlink-libexec)
    mkdir -p "$TMP/unrelated"
    printf 'operator helper\n' > "$TMP/unrelated/apply-dpi-firewall"
    printf 'operator binary\n' > "$TMP/unrelated/twebproxy-nfqws"
    printf 'operator checksum\n' > "$TMP/unrelated/twebproxy-nfqws.sha256"
    command mv "$LIBEXEC_DIR" "$TMP/old-libexec"
    ln -s "$TMP/unrelated" "$LIBEXEC_DIR"
    rc=0; dpi_cleanup_stock_runtime || rc=$?
    (( rc != 0 )) &&
      [[ "$(command cat "$TMP/unrelated/apply-dpi-firewall")" == 'operator helper' ]] &&
      [[ "$(command cat "$TMP/unrelated/twebproxy-nfqws")" == 'operator binary' ]] &&
      [[ "$(command cat "$TMP/unrelated/twebproxy-nfqws.sha256")" == 'operator checksum' ]]
    ;;
  verify-prefix|verify-mode|verify-good)
    seed || exit 90
    case "$CASE" in
      verify-prefix) sed -i 's/198\.51\.100\.10/198.51.100.100/g' "$MOCK_NFT_LIVE";;
      verify-mode) sed -i 's/tcp option maxseg size set 88/accept/g' "$MOCK_NFT_LIVE";;
    esac
    rc=0; dpi_verify_runtime 0 || rc=$?
    if [[ "$CASE" == verify-good ]]; then (( rc == 0 )); else (( rc != 0 )); fi
    ;;
  verify-multi)
    seed && dpi_transaction_set 198.51.100.20 window1152 beta.example && dpi_verify_runtime 0
    ;;
  verify-parameters)
    seed || exit 90
    sed -i 's/size set 88/size set 89/' "$MOCK_NFT_LIVE"
    rc=0; dpi_verify_runtime 0 || rc=$?
    (( rc != 0 )) || exit 1
    seed || exit 90
    sed -i 's/tcp sport 443/tcp sport 444/' "$MOCK_NFT_LIVE"
    rc=0; dpi_verify_runtime 0 || rc=$?
    (( rc != 0 ))
    ;;
  verify-json-fields)
    dpi_harness_seed_scope 198.51.100.10 window1152_nfqws alpha.example || exit 90
    dpi_render_rules "$DPI_STATE_DIR" "$DPI_NFT_FILE" || exit 90
    "$DPI_NFT_BIN" -f "$DPI_NFT_FILE" || exit 90
    dpi_verify_runtime 0 || exit 90
    bash "$TWEBPROXY_TEST_NFT_JSON_MODEL" "$MOCK_NFT_LIVE" > "$TMP/good.json" || exit 90
    for filter in \
      '(.nftables[]|select(has("rule"))|.rule.expr[]|select(has("mangle"))|.mangle.value)=1153' \
      '(.nftables[]|select(has("rule"))|.rule.expr[]|select(has("queue"))|.queue.num)=218' \
      '(.nftables[]|select(has("rule"))|.rule.expr[]|select(has("queue"))|.queue.flags)=["fanout"]' \
      '(.nftables[]|select(has("chain"))|.chain.hook)="input"' \
      '(.nftables[]|select(has("chain"))|.chain.prio)=0' \
      '(.nftables[]|select(has("rule"))|.rule.expr[]|select(.match.left["&"][0]? == {"meta":{"key":"mark"}})|.match.left["&"][1])=1' \
      '(.nftables[]|select(has("rule"))|.rule.expr[]|select(.match.left.ct? != null)|.match.right.range)=[2,6]' \
      '(.nftables[]|select(has("rule"))|.rule.expr[]|select(.match.left["&"][0]? == {"payload":{"protocol":"tcp","field":"flags"}})|.match.right)=2'; do
      jq "$filter" "$TMP/good.json" > "$TMP/bad.json" || exit 90
      export MOCK_NFT_LIVE_JSON="$TMP/bad.json"
      rc=0; dpi_verify_runtime 0 || rc=$?
      (( rc != 0 )) || exit 1
    done
    unset MOCK_NFT_LIVE_JSON
    dpi_verify_runtime 0
    ;;
  tui-yes|tui-no|tui-default-no|tui-eof|tui-core-error|tui-die-error|tui-ru)
    # Actual menu and its real stdin/stdout command substitutions. No TTY.
    dpi_status_cmd() { :; }; clear() { :; }
    select_instance() { printf alpha.example; }
    dpi_set_cmd() {
      printf '%s|%s|%s\n' "$1" "$2" "${3:-}" >> "$TMP/core.calls"
      [[ "$CASE" != tui-die-error ]] || exit 73
      [[ "$CASE" != tui-core-error ]]
    }
    case "$CASE" in
      tui-yes|tui-core-error|tui-die-error) input=$'3\n1\ny\n\n0\n';;
      tui-no) input=$'3\n1\nn\n\n0\n';;
      tui-default-no) input=$'3\n1\n\n\n0\n';;
      tui-eof) input=$'3\n1\n';;
      tui-ru) UI_LANGUAGE=ru; input=$'3\n1\nда\n\n0\n';;
    esac
    ( set -e; printf '%s' "$input" | menu_network_compatibility ) > "$TMP/tui.out" 2>&1; rc=$?
    command cat "$TMP/tui.out"
    (( rc == 0 )) || exit 1
    grep -q '198.51.100.10' "$TMP/tui.out" && grep -q 'alias.example' "$TMP/tui.out" || exit 1
    if [[ "$CASE" == tui-ru ]]; then grep -q 'Невозможно автоматически подтвердить выделенность' "$TMP/tui.out" || exit 1
    else grep -q 'cannot be proven' "$TMP/tui.out" || exit 1; fi
    case "$CASE" in
      tui-yes|tui-core-error|tui-die-error|tui-ru)
        [[ "$(command cat "$TMP/core.calls")" == 'alpha.example|window1152|--accept-shared-scope' ]] || exit 1
        case "$CASE" in tui-core-error|tui-die-error) grep -qi 'failed' "$TMP/tui.out";; esac;;
      *) [[ ! -e "$TMP/core.calls" ]];;
    esac
    ;;
  cli-no-flag|cli-flag|cli-not-local)
    dpi_transaction_set() { printf called >> "$TMP/mutation"; }
    if [[ "$CASE" == cli-no-flag ]]; then
      ( dpi_set_cmd alpha.example window1152 ) </dev/null > "$TMP/cli.out" 2>&1; rc=$?
      (( rc != 0 )) && [[ ! -e "$TMP/mutation" ]]
    elif [[ "$CASE" == cli-not-local ]]; then
      dpi_local_ipv4_addresses() { printf '%s\n' 198.51.100.99; }
      ( dpi_set_cmd alpha.example window1152 --accept-shared-scope ) </dev/null > "$TMP/cli.out" 2>&1; rc=$?
      (( rc != 0 )) && [[ ! -e "$TMP/mutation" ]]
    else
      ( dpi_set_cmd alpha.example window1152 --accept-shared-scope ) </dev/null > "$TMP/cli.out" 2>&1; rc=$?
      (( rc == 0 )) && [[ -s "$TMP/mutation" ]]
    fi
    ;;
  *) exit 2;;
esac
