#!/usr/bin/env python3
"""Compare durable policy/config/daemon state, retaining raw observations.

DHCP/RA expiry and the agent's watch timestamp are observations, not config.
The explicit pending-node fault fixture triggers the existing watchdog to stop
the forwarder. Only --pending-fixture permits that recorded lifecycle difference;
positive-update and rollback comparisons require exact daemon/socket state.
Foreign MTProxy/guard/relay/SSH PID, start time, restart count and policy stay exact.
"""
import json
from pathlib import Path
import sys


def normalize(obj):
    if isinstance(obj, dict): return {k: normalize(v) for k, v in obj.items() if k != 'expires'}
    if isinstance(obj, list): return [normalize(v) for v in obj]
    return obj


before, after = [json.loads(Path(p).read_text()) for p in sys.argv[1:3]]
allowed = []; changes = []
for item in [before, after]:
    item['configuration'] = {k: v for k, v in item['configuration'].items() if not k.endswith('/watch.json')}
    item['routes'] = sorted(normalize(item['routes']), key=lambda v: json.dumps(v, sort_keys=True))
for name in before['units'].keys() | after['units'].keys():
    a, b = before['units'].get(name), after['units'].get(name)
    if '--pending-fixture' in sys.argv[3:] and name.endswith(('-forward.service', '-forward.socket')) and a is not None and b is not None:
        assert a.get('Result') == b.get('Result') == 'success', name
        assert a.get('NRestarts') == b.get('NRestarts'), name
        if a != b: allowed.append({'unit': name, 'before': a.copy(), 'after': b.copy(), 'reason': 'deliberate pending-node fixture triggers unchanged watchdog; Result success, unchanged NRestarts and policy; journal correlates with fixture timestamp'})
        for values in [a, b]:
            for k in ['MainPID', 'ExecMainStartTimestampMonotonic', 'ActiveState', 'SubState']: values.pop(k, None)
for k in before:
    if before[k] != after.get(k): changes.append(k)
print(json.dumps({'status': 'FAIL' if changes else 'PASS', 'host': before['host'],
    'changed_sections': changes, 'allowed_dynamic_unit_observations': allowed,
    'ignored_observations': ['RA/DHCP expires countdown', 'watch.json heartbeat/timestamp'],
    'durable_configuration_files': len(before['configuration']), 'units': len(before['units'])}, indent=2))
raise SystemExit(bool(changes))
