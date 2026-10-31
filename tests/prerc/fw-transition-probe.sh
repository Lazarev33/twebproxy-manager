#!/usr/bin/env bash
# REAL-HOST harness (v0.2.23 pre-RC corrections): backend isolation and instance
# availability across systemd/nftables transitions, observed from a non-loopback
# peer. A network namespace joined by a veth pair probes every listening MTProxy
# client port (and 443 as control) every ~50 ms during each transition, while
# `nft monitor` records every table delete/add. After each transition the state
# of every relay/backend unit and the nft tables is recorded.
# Destructive (starts/stops nftables.service and the TWebProxy firewall unit):
# runs only with TWEBPROXY_PRERC_REAL=installed-test-host on an installed,
# disposable test host; otherwise exit 77 (NOT_EXECUTED).
# Usage: fw-transition-probe.sh <out dir>
set -u
source "$(dirname "${BASH_SOURCE[0]}")/../lib/lab-gate.sh"
installed_host_gate_or_exit prerc-fw-transitions
OUT="$(realpath -m "${1:?out dir}")"; mkdir -p "$OUT"
NS=twpprobe$$; HA=10.213.91.1; NA=10.213.91.2; VH=twpv$$h; VN=twpv$$n
mapfile -t PORTS < <(ss -Hltn | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):[0-9]+$' | sed 's/.*://' |
  while read -r p; do grep -qs "^MTPROXY_CLIENT_PORT=['\"]\?$p['\"]\?$" /etc/twebproxy/backends/*.env && echo "$p"; done | sort -un)
cleanup() { kill "${PROBER:-}" "${MON:-}" 2>/dev/null; ip netns del "$NS" 2>/dev/null; ip link del "$VH" 2>/dev/null; true; }
trap cleanup EXIT
ip netns add "$NS"; ip link add "$VH" type veth peer name "$VN"; ip link set "$VN" netns "$NS"
ip addr add "$HA/30" dev "$VH"; ip link set "$VH" up
ip netns exec "$NS" ip addr add "$NA/30" dev "$VN"; ip netns exec "$NS" ip link set "$VN" up; ip netns exec "$NS" ip link set lo up
sleep 2
ip netns exec "$NS" ping -c1 -W2 "$HA" >/dev/null 2>&1 || { echo "FAIL veth path"; exit 1; }
echo "backend client ports under test: ${PORTS[*]} (control: 443); external peer $NA -> $HA (veth, non-loopback)"
ip netns exec "$NS" python3 -I -c '
import socket, sys, time
host, ports = sys.argv[1], [int(p) for p in sys.argv[2:]]
out = open("'"$OUT"'/probe.log", "w", buffering=1)
while True:
    for p in ports + [443]:
        s = socket.socket(); s.settimeout(0.05)
        try:
            s.connect((host, p)); r = "OPEN"
        except (socket.timeout, TimeoutError): r = "blocked"
        except OSError as e: r = "refused" if e.errno == 111 else "err%d" % e.errno
        finally: s.close()
        out.write("%.3f %d %s\n" % (time.time(), p, r))
' "$HA" "${PORTS[@]}" & PROBER=$!
nft monitor tables > "$OUT/nft-monitor.log" 2>&1 & MON=$!
sleep 1
units() { systemctl list-units --all --no-legend --plain 'twebproxy@*' 'twebproxy-mtproxy@*' 'twebproxy-firewall.service' | awk '{print $1"="$3}' | sed -E 's/@[^=]*([.-]-?[a-z0-9]+)?\.service/@*.service/' | sort | uniq -c | tr '\n' ' '; }
tables() { nft list tables | awk '{print $3}' | tr '\n' ' '; }
step() { # $1 label, rest command
  local label="$1"; shift; local t0 t1 rc
  t0=$(date +%s.%N); "$@" >/dev/null 2>&1; rc=$?; sleep 2; t1=$(date +%s.%N)
  local opens; opens=$(awk -v a="$t0" -v b="$t1" -v ctl=443 '$1>=a && $1<=b && $2!=ctl && $3=="OPEN"' "$OUT/probe.log" | wc -l)
  local samples; samples=$(awk -v a="$t0" -v b="$t1" -v ctl=443 '$1>=a && $1<=b && $2!=ctl' "$OUT/probe.log" | wc -l)
  local ctl; ctl=$(awk -v a="$t0" -v b="$t1" '$1>=a && $1<=b && $2==443 && $3=="OPEN"' "$OUT/probe.log" | wc -l)
  printf '%-44s rc=%s backend_OPEN=%s/%s samples control443_OPEN=%s | tables=[%s] | units: %s\n' "$label" "$rc" "$opens" "$samples" "$ctl" "$(tables)" "$(units)"
  # Availability: except right after an explicit firewall stop, every relay and
  # backend unit must be active (never failed/start-limit-hit).
  if [[ "$label" != *"stop twebproxy-firewall"* ]]; then
    local down; down=$(systemctl list-units --all --no-legend --plain 'twebproxy@*' 'twebproxy-mtproxy@*' | awk '$3!="active"' | wc -l)
    (( down == 0 )) || { echo "   AVAILABILITY FAIL: $down relay/backend unit(s) not active"; AVAIL_FAIL=1; }
  fi
}
step "baseline (no action)" true
step "systemctl start nftables.service" systemctl start nftables.service
step "systemctl reload nftables.service" systemctl reload nftables.service
step "systemctl restart nftables.service" systemctl restart nftables.service
step "systemctl stop nftables.service" systemctl stop nftables.service
step "systemctl restart twebproxy-firewall" systemctl restart twebproxy-firewall.service
step "systemctl reload twebproxy-firewall" systemctl reload twebproxy-firewall.service
step "systemctl stop twebproxy-firewall" systemctl stop twebproxy-firewall.service
step "systemctl start twebproxy-firewall" systemctl start twebproxy-firewall.service
# Foreign table preservation across TWebProxy's own transitions (nftables.service
# itself flushes everything by design of the host's /etc/nftables.conf).
nft -f - <<'NFT'
table inet twpforeign_probe {
  set keep {
    type inet_service
    elements = { 4711 }
  }
  chain c {
    type filter hook input priority 10; policy accept;
    tcp dport @keep counter accept
  }
}
NFT
fh() { nft list table inet twpforeign_probe 2>/dev/null | grep -v 'packets' | sha256sum | cut -c1-16; }
f0=$(fh)
step "foreign table: restart twebproxy-firewall" systemctl restart twebproxy-firewall.service
step "foreign table: reload twebproxy-firewall" systemctl reload twebproxy-firewall.service
step "foreign table: twebproxy repair <host-1>" twebproxy repair "$(ls /etc/twebproxy/instances | head -1)"
f1=$(fh); echo "foreign table inet twpforeign_probe unchanged: $([[ -n "$f0" && "$f0" == "$f1" ]] && echo yes || echo NO) ($f0 -> $f1)"
nft delete table inet twpforeign_probe
[[ -n "$f0" && "$f0" == "$f1" ]] || FOREIGN_FAIL=1
# Cold-start ordering without a reboot: everything down, then the boot target.
cold() {
  systemctl stop twebproxy-firewall.service $(systemctl list-units --no-legend --plain 'twebproxy@*' | awk '{print $1}')
  systemctl start multi-user.target
}
step "cold start: stop all, start multi-user.target" cold
kill "$PROBER" "$MON" 2>/dev/null; sleep 0.3
echo "nft monitor events (table level):"; grep -E 'table' "$OUT/nft-monitor.log" | sed 's/{.*//' | sort | uniq -c
total=$(awk '$2!=443 && $3=="OPEN"' "$OUT/probe.log" | wc -l)
echo "TOTAL backend OPEN samples from the external peer: $total of $(awk '$2!=443' "$OUT/probe.log" | wc -l)"
echo "units after the run: $(units)"
(( total == 0 && ${FOREIGN_FAIL:-0} == 0 && ${AVAIL_FAIL:-0} == 0 ))
