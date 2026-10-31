#!/bin/bash
set -euo pipefail
# Read-only source comparison. Requires exact accepted baseline checkout.
base=${1:?baseline checkout};candidate=${2:-$(cd "$(dirname "$0")/../.." && pwd)}
tmp=$(mktemp -d);trap 'rm -rf "$tmp"' EXIT
for side in base candidate; do
 path=$base;[[ $side != candidate ]] || path=$candidate
 TWEBPROXY_NO_LOG=1 TWEBPROXY_ERROR_SNAPSHOT=1 bash -c 'source "$1"; trap - ERR; while read -r f; do printf "%s " "$f"; declare -f "$f" | sha256sum; done < <(compgen -A function | sort)' _ "$path/twebproxy-manager.sh" > "$tmp/$side"
done
python3 - "$tmp/base" "$tmp/candidate" <<'PY'
import sys,json
from pathlib import Path
b,c=[dict(line.split()[:2] for line in Path(p).read_text().splitlines()) for p in sys.argv[1:]]
critical=[f for f in b if f.startswith(('proc_','backend_fw_','fw_guard_'))]
changed=[f for f in b if b[f]!=c.get(f)]
assert not set(critical)&set(changed),set(critical)&set(changed)
print(json.dumps({'baseline_functions':len(b),'changed':changed,'added':sorted(set(c)-set(b)),'critical_firewall_proc_functions_unchanged':critical},indent=2))
PY
