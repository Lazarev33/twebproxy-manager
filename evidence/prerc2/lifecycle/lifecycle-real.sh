#!/usr/bin/env bash
# Real-host lifecycle regression for v0.2.24 on the disposable lab VPS:
# delete both instances -> core-uninstall -> clean-host checks -> core-install
# (candidate script) -> restore the saved instance state -> repair both ->
# audits, socket filter, procfs, HTTPS. Root-only state backup stays outside
# any deliverable (it contains secrets). Logs are sanitized afterwards.
# Usage: lifecycle-real.sh CANDIDATE_SCRIPT OUTDIR
set -uo pipefail
export LC_ALL=C
M="$(realpath "${1:?candidate}")"; OUT="$(realpath -m "${2:?out}")"; mkdir -p "$OUT"
cmp -s /etc/twebproxy-disposable-lab /etc/machine-id || { echo NOT_EXECUTED; exit 77; }
BK=<dev>/backup; install -d -m 0700 "$BK"
mapfile -t HOSTS < <(ls /etc/twebproxy/instances)
step() { local n="$1"; shift; local s=$SECONDS; "$@" > "$OUT/$n.log" 2>&1; local r=$?
  printf '%s\trc=%s\t%ss\n' "$n" "$r" "$((SECONDS - s))" | tee -a "$OUT/steps.tsv"; return $r; }
post() { # name -> JSON of clean-host / installed-host facts
  python3 -I - "$1" "$OUT" <<'PY'
import json, os, subprocess, sys, glob
name, out = sys.argv[1], sys.argv[2]
sh = lambda a: subprocess.run(a, text=True, capture_output=True).stdout
links = [p for p in glob.glob('/etc/systemd/system/*.wants/*') if 'twebproxy' in p]
dangling = [p for p in links if not os.path.exists(p)]
try: tables = [t['table']['name'] for t in json.loads(sh(['nft', '-j', 'list', 'tables']))['nftables'] if 'table' in t]
except Exception: tables = 'error'
r = {
 'paths_exist': {p: os.path.exists(p) for p in ['/etc/twebproxy', '/usr/local/libexec/twebproxy/firewall-guard',
   '/usr/local/libexec/twebproxy/apply-firewall', '/usr/local/libexec/twebproxy/backend-start-check',
   '/usr/local/bin/tproxy-server', '/etc/systemd/system/nftables.service.d/twebproxy-reassert.conf',
   '/etc/systemd/system/twebproxy-mtproxy@.service']},
 'unitfiles': sorted(os.path.basename(p) for p in glob.glob('/etc/systemd/system/twebproxy*') if os.path.isfile(p)),
 'wants_links': len(links), 'dangling_links': len(dangling),
 'loaded_units': [l.split()[0] for l in sh(['systemctl', 'list-units', '--all', '--no-legend', '--plain', 'twebproxy*']).splitlines() if l.split()],
 'nft_tables': tables,
 'mtproxy_pids': len(sh(['pgrep', '-x', 'mtproto-proxy']).split()),
 'proc_options_top': sh(['findmnt', '-no', 'OPTIONS', '/proc']).strip().splitlines()[-1:],
 'caddy_active': sh(['systemctl', 'is-active', 'caddy']).strip(),
}
open(f'{out}/{name}.json', 'w').write(json.dumps(r, indent=1) + '\n'); print(json.dumps(r))
PY
}
: > "$OUT/steps.tsv"
tar -C / -cpzf "$BK/lifecycle-state.tgz" etc/twebproxy srv/twebproxy etc/caddy && chmod 0600 "$BK/lifecycle-state.tgz"
post pre
i=0; for h in "${HOSTS[@]}"; do i=$((i + 1)); step "audit-pre-$i" twebproxy audit "$h"; done
i=0; for h in "${HOSTS[@]}"; do i=$((i + 1)); printf 'y\n' | step "delete-$i" twebproxy delete "$h"; done
printf 'y\n' | step core-uninstall twebproxy core-uninstall
post after-uninstall
step core-install bash "$M" core-install </dev/null
post after-install
# Restore the saved instance state (instances, backends, sites, Caddyfile), as an operator restoring a backup.
tar -C / -xpzf "$BK/lifecycle-state.tgz" etc/twebproxy/instances etc/twebproxy/backends srv/twebproxy etc/caddy/Caddyfile
i=0; for h in "${HOSTS[@]}"; do i=$((i + 1)); step "restore-repair-$i" bash "$M" repair "$h" </dev/null; done
i=0; for h in "${HOSTS[@]}"; do i=$((i + 1)); step "audit-final-$i" twebproxy audit "$h"
  code="$(curl -s -o /dev/null -w '%{http_code} %{ssl_verify_result}' --max-time 15 "https://$h/")"
  printf 'https-%s\t%s\n' "$i" "$code" | tee -a "$OUT/steps.tsv"; done
post final
sha256sum /usr/local/sbin/twebproxy "$M" | tee "$OUT/manager-sha.txt"
# sanitize
for f in "$OUT"/*.log "$OUT"/*.json "$OUT"/*.tsv; do
  i=0; for h in "${HOSTS[@]}"; do i=$((i + 1)); sed -i "s/${h//./\\.}/<test-host-$i>/g" "$f"; done
  sed -i -E 's/\b[0-9a-fA-F]{32}\b/<hex32>/g; s#(tg://proxy\?)[^ ]*#\1<redacted>#g; s#https://t\.me/proxy\?[^ ]*#https://t.me/proxy?<redacted> "$f"
done
