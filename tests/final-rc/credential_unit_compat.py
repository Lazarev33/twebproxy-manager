#!/usr/bin/env python3
"""Execute the generated relay credential path using the guest's real PID1.

Root on a marked disposable Linux guest only. Template generation doubles only
its administrative side effects; real systemd transfers the root-only credential
to an unprivileged transient unit. No proxy or existing unit is restarted.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import uuid

assert os.geteuid() == 0
assert Path('/etc/twebproxy-disposable-lab').read_bytes() == Path('/etc/machine-id').read_bytes()
manager = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='twp-credential-compat-') as d:
    work = Path(d)
    code = 'source "$1"; trap - ERR; SYSTEMD_DIR="$2"; systemctl() { :; }; write_backend_firewall_unit() { :; }; write_systemd_templates'
    r = subprocess.run(['bash', '-c', code, '_', str(manager), d], capture_output=True, text=True,
                       env={**os.environ, 'TWEBPROXY_NO_LOG': '1', 'TWEBPROXY_ERROR_SNAPSHOT': '1'})
    assert r.returncode == 0, r.stderr
    line = next(x for x in (work / 'twebproxy@.service').read_text().splitlines() if x.startswith('ExecStart='))
    credential_path = shlex.split(line.partition('=')[2])[-1]
    fixture = work / 'config.json'
    fixture.write_text('opaque root-only credential fixture\n')
    fixture.chmod(0o600)
    unit = 'twp-credential-compat-' + uuid.uuid4().hex[:12]
    cmd = ['systemd-run', '--quiet', '--wait', '--pipe', '--collect', '--unit=' + unit,
           '--property=User=nobody', '--property=LoadCredential=config.json:' + str(fixture),
           '/usr/bin/cat', credential_path]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    passed = r.returncode == 0 and r.stdout == fixture.read_text()
    print(json.dumps({'status': 'PASS' if passed else 'FAIL', 'systemd_version': subprocess.check_output(['systemd', '--version'], text=True).splitlines()[0],
                      'generated_credential_path': credential_path, 'return_code': r.returncode,
                      'unprivileged_unit_read_root_only_credential': passed, 'stderr': r.stderr}, indent=2))
    raise SystemExit(0 if passed else 1)
