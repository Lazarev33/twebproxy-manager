#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export PYTHONDONTWRITEBYTECODE=1
bash -n twebproxy-manager.sh
bash -n tests/tui-smart-defaults/fresh-quick-negative.sh
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=error twebproxy-manager.sh tests/tui-smart-defaults/fresh-quick-negative.sh
else
  printf 'ShellCheck: NOT_EXECUTED (not installed)\n'
fi
python3 tests/tui-smart-defaults/test_corrections.py
bash tests/localization-static-audit.sh
python3 tests/tui-smart-defaults/test_smart_defaults.py
python3 tests/bridge-gate3/test_bridge_menu.py
python3 tests/bridge-gate2/test_safety.py
python3 tests/bridge-gate3/test_default_site.py
bash tests/read-only-core-fixture.sh
bash tests/localization-flow-fixture.sh
bash tests/stagec1/state-persistence-fixture.sh
bash tests/stagec1/port-allocation-fixture.sh
