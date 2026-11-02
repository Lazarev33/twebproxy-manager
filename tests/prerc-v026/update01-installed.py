#!/usr/bin/env python3
"""RED and recovery evidence, NOT a correction. Disposable installed KVM only.

The real installed v025 updater handles authenticated exact v026 over trusted
loopback TLS. Only API/raw origins are redirected; transaction code is unchanged.
The final exit is 1 while the reproduced component gap remains. Raw logs and
generated TLS private keys stay inside the disposable guest, never the handoff.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import subprocess
import threading
import time

assert os.geteuid() == 0 and socket.gethostname() == 'update01-lab'
assert Path('/etc/twebproxy-disposable-lab').read_bytes() == Path('/etc/machine-id').read_bytes()
assert Path('/proc/1/comm').read_text().strip() == 'systemd'
assert 'VERSION_ID="24.04"' in Path('/etc/os-release').read_text()
caps = int(next(l.split()[1] for l in Path('/proc/self/status').read_text().splitlines() if l.startswith('CapEff:')), 16)
assert caps & (1 << 12) and caps & (1 << 21)
subprocess.run(['nft', 'list', 'tables'], check=True, capture_output=True)
subprocess.run(['systemctl', 'show', '-p', 'Version'], check=True, capture_output=True)
OUT = Path('/root/update01-private')
OUT.mkdir(mode=0o700, exist_ok=False)
BIN = Path('/usr/local/sbin/twebproxy')
COPY = Path('/opt/twebproxy-manager/twebproxy-manager.sh')
ORIGINAL = Path('/root/baseline25/twebproxy-manager.sh').read_bytes()
CANDIDATE = Path('/root/candidate26/twebproxy-manager.sh').read_bytes()
assert BIN.read_bytes() == COPY.read_bytes() == ORIGINAL
assert hashlib.sha256(CANDIDATE).hexdigest() == 'c592c71b045c4eb780ccd95318a4230b2f4d51f311b4b624274f7b2d7976fe77'
payload = CANDIDATE
mode = 'normal'
arrived = threading.Event()
release = threading.Event()
requests = []
rows = []


def sha(data):
    return hashlib.sha256(data).hexdigest()


def snapshot():
    files = {}
    for root in ['/etc/twebproxy/instances', '/etc/twebproxy/backends', '/srv/twebproxy']:
        for p in sorted(Path(root).rglob('*')):
            if p.is_file():
                files[str(p)] = sha(p.read_bytes())
    components = {str(p): sha(p.read_bytes()) for p in sorted(Path('/opt/twebproxy-manager').glob('bridge-*/*')) if p.is_file()}
    for root in Path('/opt/twebproxy-manager').glob('bridge-*'):
        if root.is_dir():
            components.update({str(p): sha(p.read_bytes()) for p in root.rglob('*') if p.is_file()})
    global_lines = Path('/etc/twebproxy/global.env').read_text().splitlines()
    return {'canonical': files, 'components': components, 'manager': sha(BIN.read_bytes()),
            'copy': sha(COPY.read_bytes()),
            'global_except_manager': sha('\n'.join(l for l in global_lines if not l.startswith('MANAGER_VERSION=')).encode())}


def state_preserved(before, exact_manager=True):
    after = snapshot()
    assert before['canonical'] == after['canonical'], 'profile/secret/site/TLS changed'
    assert before['components'] == after['components'], 'original component bytes changed'
    assert before['global_except_manager'] == after['global_except_manager']
    if exact_manager:
        assert before['manager'] == after['manager'] == after['copy']
    return after


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        if self.path == '/api/releases/latest':
            body = json.dumps({'tag_name': 'v0.2.26', 'draft': False, 'prerelease': False,
                'html_url': 'https://github.com/Lazarev33/twebproxy-manager/releases/tag/v0.2.26'}).encode()
        elif self.path == '/raw/v0.2.26/twebproxy-manager.sh':
            if mode == 'missing':
                self.send_error(404)
                return
            if mode == 'hold':
                arrived.set()
                release.wait(60)
            body = payload
        else:
            self.send_error(404)
            return
        try:
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (OSError, ssl.SSLError):
            pass

    def log_message(self, *args):
        pass


cert, key = OUT/'loopback.crt', OUT/'loopback.key'
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
    '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1',
    '-keyout', str(key), '-out', str(cert)], capture_output=True, check=True)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
wrapper = OUT/'update-wrapper.sh'
wrapper.write_text('source /usr/local/sbin/twebproxy\nMANAGER_API_URL="$TEST_BASE/api"\nMANAGER_RAW_URL="$TEST_BASE/raw"\nmanager_update_cmd "$@"\n')
env = {**os.environ, 'TEST_BASE': 'https://127.0.0.1:'+str(server.server_port),
    'CURL_CA_BUNDLE': str(cert), 'TWEBPROXY_NO_LOG': '1', 'TWEBPROXY_ERROR_SNAPSHOT': '1',
    'TWEBPROXY_UI_LANGUAGE': 'ru', 'NO_COLOR': '1'}


def record(label, p, expected):
    (OUT/(label+'.raw')).write_text(p.stdout+p.stderr)
    row = {'test': label, 'return_code': p.returncode, 'expected': expected,
        'outcomes': [s for s in (p.stdout+p.stderr).splitlines() if s.startswith(('UPDATE_', 'RESTORE_', 'ROLLBACK_'))]}
    rows.append(row)
    print(json.dumps(row), flush=True)
    if expected is not None:
        assert p.returncode == expected, row
    return p


def run(label, cmd, expected, stdin=''):
    return record(label, subprocess.run(cmd, input=stdin, capture_output=True, text=True, env=env, timeout=300), expected)


def update(label, expected=1, digest=None):
    return run(label, ['bash', str(wrapper), '--sha256', digest or sha(payload)], expected)


def service_snapshot():
    return subprocess.check_output(['systemctl', 'show', 'twebproxy@upgrade-lab.invalid.service',
        'twebproxy-mtproxy@upgrade-lab.invalid--default.service', 'ssh.service',
        '-p', 'MainPID', '-p', 'ActiveState', '-p', 'NRestarts', '-p', 'ExecMainStartTimestamp'], text=True)


blocked = True
try:
    site = Path('/srv/twebproxy/upgrade-lab.invalid/index.html')
    site.write_text(site.read_text()+'\n<!-- operator-edit UPDATE01 preservation -->\n')
    before = snapshot()
    services_before = service_snapshot()
    (OUT/'before.json').write_text(json.dumps(before, indent=2)+'\n')
    run('baseline-local-status', [str(BIN), 'status', 'upgrade-lab.invalid', '--json'], 0)
    run('baseline-bridge-status', [str(BIN), 'foreign-node', 'status'], 0)
    update('RED-exact-candidate-update', 0)
    assert BIN.read_bytes() == COPY.read_bytes() == CANDIDATE
    state_preserved(before, exact_manager=False)
    run('RED-updated-local-status', [str(BIN), 'status', 'upgrade-lab.invalid', '--json'], 0)
    bridge = run('RED-updated-bridge-status', [str(BIN), 'foreign-node', 'status'], None)
    blocked = bridge.returncode != 0
    assert blocked, 'Original RED no longer reproduces; investigate before proceeding'
    run('rollback-to25', [str(BIN), 'manager-rollback', 'latest'], 0, 'да\n')
    state_preserved(before)
    update('wrong-digest', 1, '0'*64)
    state_preserved(before)
    mode = 'missing'
    update('failed-download')
    state_preserved(before)
    mode = 'hold'
    p = subprocess.Popen(['bash', str(wrapper), '--sha256', sha(payload)], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True)
    assert arrived.wait(30), 'candidate request not observed before interrupt'
    os.killpg(p.pid, signal.SIGTERM)
    release.set()
    stdout, stderr = p.communicate(timeout=35)
    record('interrupted-before-mutation', subprocess.CompletedProcess(p.args, p.returncode, stdout, stderr), 143)
    mode = 'normal'
    state_preserved(before)
    state = Path('/etc/twebproxy/bridge/node.json')
    assert not state.exists()
    state.parent.mkdir(mode=0o700, exist_ok=True)
    for phase in ['active', 'cleanup_pending']:
        state.write_text(json.dumps({'schema': 1, 'id': 'b'*32, 'phase': phase}))
        state.chmod(0o600)
        h, count = sha(state.read_bytes()), len(requests)
        try:
            update('bridge-'+phase+'-refusal')
            assert len(requests) == count and sha(state.read_bytes()) == h
            state_preserved(before)
        finally:
            state.unlink()
    fault = b'\nif [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == --help ]]; then exit 42; fi\n'
    payload = CANDIDATE.replace(b'\nAPP="twebproxy"', fault+b'\nAPP="twebproxy"', 1)
    assert payload != CANDIDATE
    p = update('health-failure-exact-rollback')
    assert 'UPDATE_FAILED_ROLLBACK_SUCCESS' in p.stdout
    state_preserved(before)
    run('offline-helper-restore', ['/usr/local/libexec/twebproxy/restore-update-backup', 'restore-latest'], 0)
    state_preserved(before)
    run('final-local-status', [str(BIN), 'status', 'upgrade-lab.invalid', '--json'], 0)
    run('final-bridge-status', [str(BIN), 'foreign-node', 'status'], 0)
    services_after = service_snapshot()
    assert services_before == services_after, 'unintended service restart'
    (OUT/'services.json').write_text(json.dumps({'before': services_before, 'after': services_after, 'unchanged': True}, indent=2)+'\n')
    (OUT/'after.json').write_text(json.dumps(snapshot(), indent=2)+'\n')
    print('STATE_COMPONENTS_TLS_SITE_SERVICES_PRESERVED=PASS', flush=True)
finally:
    release.set()
    server.shutdown()
    server.server_close()
    key.unlink(missing_ok=True)
    (OUT/'RESULTS.json').write_text(json.dumps({'rows': rows, 'blocker': 'PRERC-UPDATE-01',
        'status': 'OPEN' if blocked else 'CLOSED', 'candidate_SHA256': sha(CANDIDATE),
        'baseline_SHA256': sha(ORIGINAL), 'public_TLS': False, 'authenticated_loopback_TLS': True,
        'active_bridge_states': 'synthetic refusal fixture, no real tunnel or foreign RPC',
        'corrected_GREEN': 'NOT_EXECUTED; no product correction applied'}, indent=2)+'\n')
raise SystemExit(1 if blocked else 0)
