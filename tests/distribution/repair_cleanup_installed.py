#!/usr/bin/env python3
"""Installed Manager repair/remove after updater acceptance; marked guest only."""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import time

assert os.geteuid() == 0 and socket.gethostname() == 'update01-final-entry'
assert Path('/etc/twebproxy-disposable-lab').read_bytes() == Path('/etc/machine-id').read_bytes()
os.umask(0o077)
OUT = Path('/root/distribution-cleanup-private'); OUT.mkdir(mode=0o700, exist_ok=True)
BIN = '/usr/local/sbin/twebproxy'; NODE = Path('/etc/twebproxy/bridge/node.json')
ENV = {**os.environ, 'TWEBPROXY_NO_LOG': '1', 'TWEBPROXY_ERROR_SNAPSHOT': '1', 'TWEBPROXY_UI_LANGUAGE': 'ru'}
ROWS = []


def digest(b): return hashlib.sha256(b).hexdigest()


def files():
    names = [Path('/etc/twebproxy/instances/upgrade-lab.invalid/profiles.d/default.env'),
             Path('/etc/twebproxy/instances/upgrade-lab.invalid/instance.env')]
    names += [p for p in Path('/srv/twebproxy').rglob('*') if p.is_file()]
    return {str(p): digest(p.read_bytes()) for p in names}


def run(name, args):
    start = time.time_ns(); p = subprocess.run(args, capture_output=True, env=ENV, timeout=600)
    (OUT/(name+'.raw')).write_bytes(p.stdout+p.stderr)
    r = {'test': name, 'return_code': p.returncode, 'start_ns': start, 'end_ns': time.time_ns()}
    ROWS.append(r); print(json.dumps(r), flush=True)
    assert p.returncode == 0 and b'pop_var_context' not in p.stdout+p.stderr, name
    r['status'] = 'PASS'; return p


try:
    node = json.loads(NODE.read_text()); before = files()
    credentials = {str(p): digest(p.read_bytes()) for p in (NODE.parent/'credentials').rglob('*') if p.is_file()}
    run('installed-Bridge-repair', [BIN, 'foreign-node', 'repair'])
    repaired = json.loads(NODE.read_text())
    for k in ['id', 'executor_digest', 'entry', 'exit', 'previous_port', 'management_user', 'host_key', 'fingerprint']:
        assert node[k] == repaired[k], 'identity/mapping changed: '+k
    assert repaired['phase'] == 'active' and not repaired.get('cleanup_debt')
    assert files() == before and credentials == {str(p): digest(p.read_bytes()) for p in (NODE.parent/'credentials').rglob('*') if p.is_file()}
    run('installed-Bridge-remove-owned-node', [BIN, 'foreign-node', 'remove', '--approve'])
    assert not NODE.exists()
    assert not Path('/etc/twebproxy/instances/upgrade-lab.invalid/bridge.json').exists()
    subprocess.run(['systemctl', 'is-active', '--quiet', 'twebproxy@upgrade-lab.invalid.service',
                    'twebproxy-mtproxy@upgrade-lab.invalid--default.service', 'ssh.service'], check=True)
    run('restored-local-profile-status', [BIN, 'status', 'upgrade-lab.invalid', '--json'])
    p = run('removed-node-status', [BIN, 'foreign-node', 'status'])
    assert json.loads(p.stdout)['state'] == 'NO_NODE'
    assert all(digest(Path(n).read_bytes()) == h for n, h in before.items() if n.startswith('/srv/twebproxy'))
    profile = Path('/etc/twebproxy/instances/upgrade-lab.invalid/profiles.d/default.env')
    original = json.loads(Path('/root/prerc-upgrade-repro-private/before.json').read_text())['canonical_files']
    assert digest(profile.read_bytes()) == original[str(profile)], 'original baseline profile not exactly restored'
    assert b'OPERATOR_AFTER_UPDATE=preserve-late-setting' in Path('/etc/twebproxy/global.env').read_bytes()
    ROWS.append({'test': 'original-profile-site-late-settings-after-cleanup', 'status': 'PASS'})
finally:
    (OUT/'RESULTS.json').write_text(json.dumps({'environment': 'actual Ubuntu24.04 KVM canonical CLI', 'rows': ROWS}, indent=2)+'\n')
