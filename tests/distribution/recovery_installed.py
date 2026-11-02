#!/usr/bin/env python3
"""Real installed rollback/crash recovery. Disposable marked KVM only.

SIGKILL is injected at an Engine event boundary, with real installed files,
systemd services, journal and CLI startup recovery; health is NOT mocked.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time

assert os.geteuid() == 0 and socket.gethostname() == 'update01-final-entry'
assert Path('/etc/twebproxy-disposable-lab').read_bytes() == Path('/etc/machine-id').read_bytes()
os.umask(0o077)
OUT = Path('/root/distribution-recovery-private'); OUT.mkdir(mode=0o700, exist_ok=True)
PACKAGE = Path(sys.argv[1]); PIN = hashlib.sha256(PACKAGE.read_bytes()).hexdigest()
ENGINE = Path('/root/newengine.py')
BIN = Path('/usr/local/sbin/twebproxy'); COPY = Path('/opt/twebproxy-manager/twebproxy-manager.sh')
GLOBAL = Path('/etc/twebproxy/global.env'); HELPER = '/usr/local/libexec/twebproxy/restore-distribution-backup'
BACKUPS = Path('/var/lib/twebproxy/distribution-backups'); PENDING = Path('/var/lib/twebproxy/distribution-update/pending.json')
ENV = {**os.environ, 'TWEBPROXY_NO_LOG': '1', 'TWEBPROXY_ERROR_SNAPSHOT': '1', 'TWEBPROXY_UI_LANGUAGE': 'ru', 'NO_COLOR': '1'}
ROWS = []


def sha(b): return hashlib.sha256(b).hexdigest()


def state():
    files = {}
    for root in ['/etc/twebproxy', '/srv/twebproxy', '/etc/caddy', '/etc/nginx']:
        for p in Path(root).rglob('*'):
            if p.is_file() and p != GLOBAL: files[str(p)] = sha(p.read_bytes())
    return {'files': files, 'global_nonversion': sha(b'\n'.join(l for l in GLOBAL.read_bytes().splitlines() if not l.startswith(b'MANAGER_VERSION=')))}


def run(name, args, expected=0, stdin=''):
    start = time.time_ns()
    p = subprocess.run(args, input=stdin, capture_output=True, text=True, env=ENV, timeout=240)
    (OUT/(name+'.raw')).write_text(p.stdout+p.stderr)
    row = {'test': name, 'return_code': p.returncode, 'expected': expected,
           'start_ns': start, 'end_ns': time.time_ns(),
           'outcomes': [s for s in p.stdout.splitlines() if s.startswith(('UPDATE_', 'RESTORE_'))]}
    ROWS.append(row); print(json.dumps(row), flush=True)
    assert p.returncode == expected and 'pop_var_context' not in p.stdout+p.stderr, name
    row['status'] = 'PASS'; return p


try:
    candidates = [json.loads(p.read_text()) for p in BACKUPS.glob('dist-*/metadata.json')]
    old_id = sorted(m['id'] for m in candidates if m['version'] == '0.2.25')[-1]
    old = (BACKUPS/old_id/'manager.sh').read_bytes()
    # Late settings must survive explicit version rollback; automatic failure
    # compensation instead restores its exact pre-transaction metadata snapshot.
    with GLOBAL.open('ab') as f: f.write(b'\nOPERATOR_AFTER_UPDATE=preserve-late-setting\n')
    before = state(); current = BIN.read_bytes(); current_meta = GLOBAL.read_bytes()
    subprocess.run(['chattr', '+i', str(GLOBAL)], check=True)
    try:
        p = run('immutable-global-manual-rollback-refusal', [HELPER, 'restore', old_id], 1)
        assert 'RESTORE_FAILED_ROLLBACK_SUCCESS' in p.stdout
        assert BIN.read_bytes() == COPY.read_bytes() == current and GLOBAL.read_bytes() == current_meta
    finally: subprocess.run(['chattr', '-i', str(GLOBAL)], check=True)
    run('CLI-Russian-affirmative-rollback-to25', [str(BIN), 'manager-rollback', old_id], stdin='да\n')
    assert BIN.read_bytes() == COPY.read_bytes() == old and state() == before
    assert b'OPERATOR_AFTER_UPDATE=preserve-late-setting' in GLOBAL.read_bytes()
    run('rollback25-installed-Bridge-status', [str(BIN), 'foreign-node', 'status'])
    baseline_meta = GLOBAL.read_bytes()
    observer = OUT/'kill-observer.py'
    observer.write_text('''import importlib.util,os,signal,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('observer_engine',sys.argv[1])
m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m)
def event(phase):
 if phase=='primary-replaced':os.kill(os.getpid(),signal.SIGKILL)
m.Engine(event=event).install(Path(sys.argv[2]),sys.argv[3],True)
''')
    start = time.time_ns()
    p = subprocess.run([sys.executable, str(observer), str(ENGINE), str(PACKAGE), PIN], capture_output=True, env=ENV, timeout=240)
    (OUT/'SIGKILL-boundary.raw').write_bytes(p.stdout+p.stderr)
    assert p.returncode == -signal.SIGKILL and PENDING.exists()
    assert BIN.read_bytes() != COPY.read_bytes() and COPY.read_bytes() == old
    record = json.loads(PENDING.read_text())
    ROWS.append({'test': 'SIGKILL-after-first-rename-real-install', 'status': 'PASS', 'return_code': p.returncode,
                 'mixed_copies_observed': True, 'durable_backup_id': record['backup_id'], 'start_ns': start, 'end_ns': time.time_ns()})
    # Execute the new primary. Its production startup must restore old copies
    # through the independently installed helper before serving the request.
    run('canonical-startup-recovers-interrupted-update', [str(BIN), '--help'])
    assert BIN.read_bytes() == COPY.read_bytes() == old and GLOBAL.read_bytes() == baseline_meta and not PENDING.exists()
    assert state() == before
    run('after-crash-Bridge-status', [str(BIN), 'foreign-node', 'status'])
    run('verified-full-upgrade-after-recovery', [sys.executable, '-I', str(ENGINE), 'install', '--archive', str(PACKAGE), '--sha256', PIN])
    assert state() == before
    run('final-installed-Bridge-status', [str(BIN), 'foreign-node', 'status'])
    run('final-installed-Bridge-diagnose', [str(BIN), 'foreign-node', 'diagnose'])
    run('final-JSON-overview', [str(BIN), '--json', 'overview'])
finally:
    (OUT/'RESULTS.json').write_text(json.dumps({'environment': 'actual Ubuntu24.04 KVM installed paths, no health doubles',
        'archive_sha256': PIN, 'rows': ROWS}, indent=2)+'\n')
