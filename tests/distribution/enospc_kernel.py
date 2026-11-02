#!/usr/bin/env python3
"""Real ENOSPC + atomic undo on a private ext4 loop filesystem in marked KVM.

Health is explicitly doubled here: this verifies filesystem exhaustion/rename,
not installed application health. Canonical installed tests run separately.
"""
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

assert os.geteuid() == 0 and socket.gethostname() == 'update01-final-entry'
assert Path('/etc/twebproxy-disposable-lab').read_bytes() == Path('/etc/machine-id').read_bytes()
os.umask(0o077)
spec = importlib.util.spec_from_file_location('enospc_engine', '/root/newengine.py')
m = importlib.util.module_from_spec(spec); sys.modules[spec.name] = m; spec.loader.exec_module(m)
archive = Path(sys.argv[1]); pin = hashlib.sha256(archive.read_bytes()).hexdigest()
out = Path('/root/distribution-enospc-private'); out.mkdir(mode=0o700, exist_ok=True)
image = out/'scratch.ext4'; target = out/'mount'; target.mkdir(mode=0o700, exist_ok=True)
assert not image.exists() and not os.path.ismount(target)
with image.open('xb') as f: f.truncate(256*1024*1024)
subprocess.run(['mkfs.ext4', '-q', '-F', '-m', '0', str(image)], check=True)
subprocess.run(['mount', '-o', 'loop,nodev,nosuid,noexec', str(image), str(target)], check=True)
result = {'filesystem': 'private256MiB ext4 loop, reserve0, guest only', 'health': 'explicit fixture double', 'errno': None}
try:
    p = m.Paths(target)
    for d in [p.primary.parent, p.project, p.lock.parent, p.global_env.parent]: d.mkdir(parents=True, exist_ok=True)
    old = Path('/root/baseline25/twebproxy-manager.sh').read_bytes()
    for f in [p.primary, p.secondary]: f.write_bytes(old); f.chmod(0o755)
    config = b'MANAGER_VERSION=0.2.25\nKEEP_USER_DATA=yes\n'
    p.global_env.write_bytes(config); p.global_env.chmod(0o600)
    def fill(phase):
        if phase != 'primary-replaced': return
        with (target/'fill').open('wb', buffering=0) as f:
            try:
                while True: f.write(b'x'*1024*1024)
            except OSError as e:
                assert e.errno == errno.ENOSPC
                result['errno'] = e.errno
                raise
    try:
        m.Engine(p, health=lambda data: True, event=fill).install(archive, pin)
        raise AssertionError('disk exhaustion did not fail')
    except OSError as e:
        assert e.errno == errno.ENOSPC and getattr(e, 'distribution_outcome', '') == 'rolled-back'
    assert p.primary.read_bytes() == p.secondary.read_bytes() == old
    assert p.global_env.read_bytes() == config and not (p.state/'pending.json').exists()
    result.update(status='PASS', exact_old_copies=True, original_metadata=True, outcome='UPDATE_FAILED_ROLLBACK_SUCCESS')
finally:
    subprocess.run(['umount', str(target)], check=True)
    image.unlink()
    (out/'RESULTS.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result), flush=True)
