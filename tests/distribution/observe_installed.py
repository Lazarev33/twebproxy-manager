#!/usr/bin/env python3
"""Read-only, sanitized before/after observations on explicitly marked guests."""
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess

assert os.geteuid() == 0 and socket.gethostname() in ('update01-final-entry', 'update01-final-exit', 'update01-final-replay')
assert Path('/etc/twebproxy-disposable-lab').read_bytes() == Path('/etc/machine-id').read_bytes()


def cmd(args): return subprocess.check_output(args, timeout=30).decode()
def sha(raw): return hashlib.sha256(raw).hexdigest()


def normalized(obj):
    if isinstance(obj, dict): return {k: normalized(v) for k, v in obj.items() if k not in ('handle', 'packets', 'bytes', 'last', 'expires')}
    if isinstance(obj, list): return [normalized(v) for v in obj]
    return obj


units = {}
names = cmd(['systemctl', 'list-units', '--all', '--no-legend', '--plain', 'twb-*', 'twebproxy-*', 'twebproxy@*', 'ssh.service']).splitlines()
for line in names:
    name = line.split()[0]
    if not name.endswith(('.service', '.socket')) or any(x in name for x in ('watch.', 'refresh.', 'apply-', 'material', 'oneshot')): continue
    text = cmd(['systemctl', 'show', name, '-p', 'ActiveState', '-p', 'SubState', '-p', 'MainPID', '-p', 'NRestarts',
                '-p', 'ExecMainStartTimestampMonotonic', '-p', 'IPAddressDeny', '-p', 'IPAddressAllow', '-p', 'Result'])
    units[name] = dict(l.split('=', 1) for l in text.splitlines() if '=' in l)
files = {}
for root in ['/etc/twebproxy', '/srv/twebproxy', '/etc/ssh/twebproxy-bridge', '/etc/ssh/sshd_config.d', '/etc/sudoers.d', '/etc/caddy', '/etc/nginx', '/var/lib/twebproxy-bridge', '/usr/local/libexec/twebproxy-bridge']:
    for p in Path(root).rglob('*'):
        if not p.is_file() or p.name in ('global.env', 'watch.json') or p.name.startswith('op-') or p.suffix == '.lock': continue
        files[str(p)] = {'sha256': sha(p.read_bytes()), 'mode': oct(p.stat().st_mode & 0o777)}
for p in Path('/etc/systemd/system').glob('twb-*'):
    if p.is_file(): files[str(p)] = {'sha256': sha(p.read_bytes()), 'mode': oct(p.stat().st_mode & 0o777)}
out = {'host': socket.gethostname(), 'kernel': cmd(['uname', '-r']).strip(), 'PID1': Path('/proc/1/comm').read_text().strip(),
       'units': units, 'configuration': files, 'nftables': normalized(json.loads(cmd(['nft', '-j', 'list', 'ruleset']))),
       'wireguard_interfaces': cmd(['wg', 'show', 'interfaces']).strip(),
       'routes': normalized(json.loads(cmd(['ip', '-j', 'route', 'show', 'table', 'all'])))}
print(json.dumps(out, sort_keys=True, indent=2))
