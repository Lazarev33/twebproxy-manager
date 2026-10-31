#!/usr/bin/env python3
"""Evidence that isolation does not depend on nftables: from a recorder run
(fw_owner_loss_probe.py OUTDIR), find every interval in which the state
watcher saw NO TWebProxy nftables table (neither twebproxy_guard nor
twebproxy_backend) while MTProxy processes were alive, and classify the
backend probe samples taken inside those intervals.

Usage: no_table_windows.py OUTDIR  -> prints JSON, writes OUTDIR/no-table-windows.json
"""
import collections
import json
import sys
from pathlib import Path

out = Path(sys.argv[1])
analysis = json.loads((out / 'analysis.json').read_text())
control = analysis['control_port']
states = [json.loads(l) for l in (out / 'state-changes.jsonl').read_text().splitlines() if l.strip()]
samples = []
for line in (out / 'probe.tsv').read_text().splitlines():
    try:
        mono, _w, port, status = line.split('\t')
        samples.append((int(mono), int(port), status))
    except ValueError:
        pass


def unprotected(d):
    t = d.get('tables')
    return isinstance(t, dict) and 'twebproxy_guard' not in t and 'twebproxy_backend' not in t \
        and d.get('mtproxy_pid_count', 0) > 0


windows = []
for i, d in enumerate(states):
    if unprotected(d):
        start = d['time']['mono_ns']
        end = states[i + 1]['time']['mono_ns'] if i + 1 < len(states) else start
        windows.append((start, end))
inside = [s for s in samples if s[1] != control and any(a <= s[0] < b for a, b in windows)]
res = {
    'windows_without_any_twebproxy_table_while_backends_alive': len(windows),
    'total_window_ms': round(sum(b - a for a, b in windows) / 1e6, 1),
    'backend_samples_inside': len(inside),
    'status_inside': dict(collections.Counter(s[2] for s in inside)),
    'open_inside': sum(1 for s in inside if s[2] == 'OPEN'),
}
(out / 'no-table-windows.json').write_text(json.dumps(res, indent=1) + '\n')
print(json.dumps(res))
