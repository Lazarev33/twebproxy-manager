#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TESTS="$ROOT/tests"

timeout 60 bash -n "$ROOT/twebproxy-manager.sh"
printf 'StageX-DPI-A-bash-syntax: PASS\n'

timeout 900 "$TESTS/run-stage4-mandatory-suite.sh"
printf 'StageX-DPI-B-accepted-Stage4-A-V-and-Stage1-3: PASS\n'

for locale in C POSIX C.UTF-8; do
  LC_ALL="$locale" timeout 180 "$TESTS/localization-static-audit.sh"
  LC_ALL="$locale" timeout 180 "$TESTS/localization-flow-fixture.sh"
  LC_ALL="$locale" timeout 180 "$TESTS/stage-x-fixui-fixture.sh"
  printf 'StageX-DPI-C-localization-%s: PASS\n' "$locale"
done

timeout 240 "$TESTS/stage-x-dpi-fixture.sh"
printf 'StageX-DPI-D-six-mode-transaction-matrix: PASS\n'

timeout 300 "$TESTS/stage-x-dpi-installed-asset-fixture.sh"
printf 'StageX-DPI-E-installed-manager-nfqws-lifecycle: PASS\n'

expected=f34615964d7321650197cd69d3f7cbfdaabe8118b5a0d57c6e41dccdff658999
actual="$(sha256sum "$ROOT/assets/nfqws-linux-x86_64" | awk '{print $1}')"
[[ "$actual" == "$expected" ]]
timeout 30 "$ROOT/assets/nfqws-linux-x86_64" --version | grep -Fq \
  'github version v72.13 (87e058624c72863db53bdaf7fb6f16576dddb6ab)'
timeout 30 "$ROOT/assets/nfqws-linux-x86_64" --dry-run \
  --qnum=217 --filter-l3=ipv4 --dpi-desync=fake,multisplit \
  --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq \
  --dpi-desync-cutoff=d2 --dpi-desync-fwmark=0x40000000 >/dev/null
printf 'StageX-DPI-F-nfqws-pin-and-arguments: PASS\n'

printf 'stage-x-dpi-suite: PASS (all mandatory autonomous tests executed; mandatory_skips=0)\n'
