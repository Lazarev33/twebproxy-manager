#!/usr/bin/env bash
# Behavioral model only. It does not establish nft kernel transaction semantics.
backend_harness() {
  export TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1
  source "$MGR"
  trap - ERR
  set +e
  BASE_DIR="$TMP/etc"; BACKENDS_DIR="$BASE_DIR/backends"
  FIREWALL_FILE="$BASE_DIR/firewall.nft"
  LIBEXEC_DIR="$TMP/libexec"; SYSTEMD_DIR="$TMP/systemd"
  install -d -m 0700 "$BASE_DIR" "$BACKENDS_DIR" "$SYSTEMD_DIR" "$TMP/bin"
  # As prepare_users_and_dirs() leaves it: service accounts execute from here.
  install -d -o root -g root -m 0755 "$LIBEXEC_DIR"
  export BF_TEST_ROOT="$TMP" BF_TEST_CANONICAL="$FIREWALL_FILE"
  export BF_TEST_HELPER="$LIBEXEC_DIR/apply-firewall"
  export BF_TEST_UNIT="$SYSTEMD_DIR/twebproxy-firewall.service"
  cp "$ROOT/tests/stageb/nft-model.sh" "$TMP/bin/nft"
  cp "$ROOT/tests/stageb/systemctl-model.sh" "$TMP/bin/systemctl"
  cat > "$TMP/bin/mv" <<'SH'
#!/bin/bash
if [[ -f "$BF_TEST_ROOT/interrupt-before-publish" && "${*: -1}" == "$BF_TEST_CANONICAL" ]]; then
  rm "$BF_TEST_ROOT/interrupt-before-publish"
  kill -TERM "$PPID"
  exit 143
fi
if [[ -f "$BF_TEST_ROOT/fail-publish" && "${*: -1}" == "$BF_TEST_CANONICAL" ]]; then exit 1; fi
exec /usr/bin/mv "$@"
SH
  chmod 0700 "$TMP/bin/"*
  export PATH="$TMP/bin:$PATH"
  # A caller may have sourced a model function earlier; execute these fixtures.
  unset -f systemctl 2>/dev/null || true
}
backend_state() {
  printf 'MTPROXY_CLIENT_PORT=%s\nMTPROXY_STATS_PORT=%s\n' "$2" "$3" > "$BACKENDS_DIR/$1.env"
  chmod 0600 "$BACKENDS_DIR/$1.env"
}
