#!/usr/bin/env python3
"""Canonical installed CLI acceptance, ONLY in an explicitly marked disposable KVM.

Usage: python3 installed_matrix.py /root/distribution.tar.gz
No mocked health, filesystem paths, controller or system services. The loopback
HTTPS release feed is a fixture with its own explicitly trusted one-day CA.
Raw subprocess output stays in a private guest directory; RESULTS is sanitized.
"""
import base64
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import re
import signal
import socket
import ssl
import subprocess
import sys
import tarfile
import threading
import time

assert os.geteuid() == 0
assert socket.gethostname() in ('update01-final-entry', 'update01-final-replay')
assert Path('/etc/twebproxy-disposable-lab').read_bytes() == Path('/etc/machine-id').read_bytes()
os.umask(0o077)
OUT = Path('/root/distribution-matrix-private'); OUT.mkdir(mode=0o700, exist_ok=True)
ARCHIVE = Path(sys.argv[1]); BODY = ARCHIVE.read_bytes()
BIN = Path('/usr/local/sbin/twebproxy')
COPY = Path('/opt/twebproxy-manager/twebproxy-manager.sh')
GLOBAL = Path('/etc/twebproxy/global.env')
NODE = Path('/etc/twebproxy/bridge/node.json')
ROWS = []
ENV = {**os.environ, 'TWEBPROXY_NO_LOG': '1', 'TWEBPROXY_ERROR_SNAPSHOT': '1',
       'TWEBPROXY_UI_LANGUAGE': 'ru', 'NO_COLOR': '1'}


def sha(raw): return hashlib.sha256(raw).hexdigest()


def snapshot():
    files = {}
    for root in ['/etc/twebproxy', '/srv/twebproxy', '/etc/caddy', '/etc/nginx']:
        for f in sorted(Path(root).rglob('*')):
            if f.is_file() and f != GLOBAL:
                files[str(f)] = sha(f.read_bytes())
    raw = b'\n'.join(l for l in GLOBAL.read_bytes().splitlines() if not l.startswith(b'MANAGER_VERSION='))
    return {'files': files, 'global_nonversion': sha(raw),
            'primary': sha(BIN.read_bytes()), 'secondary': sha(COPY.read_bytes()),
            'global': sha(GLOBAL.read_bytes())}


def preserved(before, exact=True):
    after = snapshot()
    assert before['files'] == after['files'], 'profile/secret/site/TLS/Bridge configuration changed'
    assert before['global_nonversion'] == after['global_nonversion'], 'nonversion settings changed'
    if exact:
        assert before == after, 'installed bytes changed after refusal/undo'


def run(name, args, expected=0, stdin='', timeout=180):
    start = time.time_ns()
    p = subprocess.run(args, input=stdin, text=True, capture_output=True, env=ENV, timeout=timeout)
    (OUT/(name+'.raw')).write_text(p.stdout+p.stderr)
    assert 'pop_var_context' not in p.stdout+p.stderr
    row = {'test': name, 'return_code': p.returncode, 'expected': expected,
           'start_ns': start, 'end_ns': time.time_ns(),
           'outcomes': [s for s in p.stdout.splitlines() if s.startswith(('UPDATE_', 'RESTORE_'))]}
    ROWS.append(row); print(json.dumps(row), flush=True)
    assert p.returncode == expected, name
    row['status'] = 'PASS'
    return p


def update_args(*extra):
    return [str(BIN), 'manager-update', '--archive', str(ARCHIVE), '--sha256', sha(BODY), '--force', *extra]


def mutant(name, edit):
    dest = OUT/(name+'.tar.gz')
    with tarfile.open(ARCHIVE, 'r:gz') as t, tarfile.open(dest, 'w:gz', format=tarfile.USTAR_FORMAT) as o:
        for m in t:
            raw = t.extractfile(m).read()
            raw = edit(m.name, raw)
            if raw is None: continue
            n = tarfile.TarInfo(m.name); n.mode = m.mode; n.size = len(raw)
            o.addfile(n, io.BytesIO(raw))
    return dest, sha(dest.read_bytes())


mode = 'normal'; requests = []; release_requested = threading.Event()
cert, key = OUT/'cert.pem', OUT/'tls-key.pem'
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1',
                '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
signkey = OUT/'signing.pem'
subprocess.run(['openssl', 'genpkey', '-algorithm', 'ED25519', '-out', str(signkey)], check=True, capture_output=True)
PUBLIC = base64.b64encode(subprocess.check_output(['openssl', 'pkey', '-in', str(signkey), '-pubout', '-outform', 'DER'])).decode()
manifest = {'format': 'twebproxy.manager-distribution-release.v1', 'repository': 'Lazarev33/twebproxy-manager',
            'channel': 'stable', 'version': '0.2.26', 'release_version': '0.2.26-beta', 'tag': 'v0.2.26',
            'commit': 'a'*40, 'artifact': {'name': 'twebproxy-manager-distribution.tar.gz', 'size': len(BODY), 'sha256': sha(BODY)}}
manifest_raw = (json.dumps(manifest, sort_keys=True, indent=2)+'\n').encode()
(OUT/'manifest').write_bytes(manifest_raw)
subprocess.run(['openssl', 'pkeyutl', '-sign', '-inkey', str(signkey), '-rawin', '-in', str(OUT/'manifest'), '-out', str(OUT/'sig')], check=True, capture_output=True)
signature = base64.b64encode((OUT/'sig').read_bytes())


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        if self.path == '/api/releases/latest':
            body = json.dumps({'tag_name': 'v0.2.26', 'draft': False, 'prerelease': False}).encode()
        elif self.path.endswith('/twebproxy-manager-release.json'): body = manifest_raw
        elif self.path.endswith('/twebproxy-manager-release.json.sig'):
            body = base64.b64encode(b'x'*64) if mode == 'bad-signature' else signature
        elif self.path.endswith('/twebproxy-manager-distribution.tar.gz'):
            release_requested.set()
            if mode == '404': self.send_error(404); return
            if mode == 'hold':
                self.send_response(200); self.send_header('Content-Length', str(len(BODY))); self.end_headers()
                time.sleep(8); return
            body = BODY
        else: self.send_error(404); return
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers()
        try: self.wfile.write(body)
        except (OSError, ssl.SSLError): pass
    def log_message(self, *args): pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = 'https://127.0.0.1:'+str(server.server_port)
ENV['CURL_CA_BUNDLE'] = str(cert)
network = [str(BIN), 'manager-update', '--api-url', base+'/api', '--release-url', base,
           '--sha256', sha(BODY), '--force']

try:
    before = snapshot(); (OUT/'before.json').write_text(json.dumps(before, indent=2)+'\n')
    run('baseline-installed-bridge-status', [str(BIN), 'foreign-node', 'status'])
    run('native-full-distribution-reinstall', update_args()); preserved(before)
    p = run('installed-json-overview', [str(BIN), '--json', 'overview'])
    assert json.loads(p.stdout)['data']['manager_version'] == '0.2.26'
    run('installed-bridge-status', [str(BIN), 'foreign-node', 'status'])
    p = run('wrong-independent-digest', [str(BIN), 'manager-update', '--archive', str(ARCHIVE), '--sha256', '0'*64, '--force'], 1)
    assert 'UPDATE_SUCCESS' not in p.stdout; preserved(before)
    for name, edit in [('missing-bundle', lambda n, r: None if n == 'bridge/controller.py' else r),
                       ('mismatched-component', lambda n, r: r+b'#corrupt' if n == 'bridge/controller.py' else r)]:
        path, digest = mutant(name, edit)
        run(name, [str(BIN), 'manager-update', '--archive', str(path), '--sha256', digest, '--force'], 1); preserved(before)
    mode = '404'; run('failed-HTTPS-download', network, 1); preserved(before)
    mode = 'bad-signature'; run('bad-signature-no-digest-fallback', [*network, '--trusted-key', PUBLIC], 1); preserved(before)
    mode = 'normal'; run('trusted-HTTPS-SHA-success', network); preserved(before)
    run('trusted-HTTPS-signed-success', [*network, '--trusted-key', PUBLIC]); preserved(before)
    mode = 'hold'; release_requested.clear()
    start = time.time_ns()
    p = subprocess.Popen(network, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV)
    assert release_requested.wait(35), 'download did not start'
    os.kill(p.pid, signal.SIGTERM); stdout, stderr = p.communicate(timeout=15)
    (OUT/'download-SIGTERM.raw').write_bytes(stdout+stderr)
    assert p.returncode == 143 and b'UPDATE_SUCCESS' not in stdout and b'pop_var_context' not in stderr
    preserved(before)
    ROWS.append({'test': 'native-CLI-download-SIGTERM', 'status': 'PASS', 'return_code': p.returncode,
                 'signal_target': 'actual CLI updater PID', 'start_ns': start, 'end_ns': time.time_ns()})
    mode = 'normal'
    original_node = NODE.read_bytes() if NODE.exists() else None
    NODE.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    pending = json.loads(original_node) if original_node else {'schema': 1}
    pending['phase'] = 'cleanup_pending'; pending['cleanup_debt'] = ['explicit-disposable-fixture']
    NODE.write_text(json.dumps(pending)); NODE.chmod(0o600)
    pending_bytes = NODE.read_bytes(); old_requests = len(requests)
    try:
        run('pending-cleanup-update-refusal', network, 1)
        assert NODE.read_bytes() == pending_bytes and len(requests) == old_requests
    finally:
        if original_node is None: NODE.unlink()
        else: NODE.write_bytes(original_node)
    preserved(before)
    if original_node:
        incompatible = json.loads(original_node); incompatible['executor_digest'] = '0'*64
        NODE.write_text(json.dumps(incompatible)); NODE.chmod(0o600)
        try:
            run('active-incompatible-executor-refusal', update_args(), 1)
            assert json.loads(NODE.read_text())['executor_digest'] == '0'*64
        finally: NODE.write_bytes(original_node)
        preserved(before)
    # Real filesystem immutable flag, no mock of open/rename or restore health.
    subprocess.run(['chattr', '+i', str(GLOBAL)], check=True)
    try:
        p = run('immutable-metadata-update-exact-undo', update_args(), 1)
        assert 'UPDATE_FAILED_ROLLBACK_SUCCESS' in p.stdout; preserved(before)
    finally: subprocess.run(['chattr', '-i', str(GLOBAL)], check=True)
    run('final-installed-bridge-status', [str(BIN), 'foreign-node', 'status'])
    (OUT/'after.json').write_text(json.dumps(snapshot(), indent=2)+'\n')
finally:
    (OUT/'RESULTS.json').write_text(json.dumps({'environment': 'real Ubuntu24.04 KVM, canonical installed CLI',
        'artifact_sha256': sha(BODY), 'active_Bridge': NODE.exists(), 'release_feed': 'trusted loopback HTTPS fixture, NOT public Release',
        'rows': ROWS}, indent=2)+'\n')
    server.shutdown(); server.server_close(); key.unlink(missing_ok=True); signkey.unlink(missing_ok=True)
