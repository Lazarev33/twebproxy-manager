"""Disposable installed-host upgrade/rollback; actual manager, curl/TLS and files.

Only release API/raw URLs are redirected to an explicitly trusted loopback test
server. No public stable release is advertised. All production transaction code
executes unchanged. The candidate is the exact integrated beta unless a scenario
explicitly injects a failed --help probe. No SSH/network topology is provisioned.
Raw output is private; export only sanitized logs and JSON summaries.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

assert socket.gethostname() == 'prerc-v026-lab'
assert os.geteuid() == 0
assert Path('/etc/twebproxy-disposable-lab').read_bytes() == Path('/etc/machine-id').read_bytes()
OUT = Path('/root/prerc-upgrade-repro-private' if '--bundle-only' in sys.argv else '/root/prerc-upgrade-private')
OUT.mkdir(mode=0o700, exist_ok=True)
BIN = Path('/usr/local/sbin/twebproxy')
COPY = Path('/opt/twebproxy-manager/twebproxy-manager.sh')
CANDIDATE = Path('/root/candidate26/twebproxy-manager.sh').read_bytes()
ORIGINAL = BIN.read_bytes()
assert b'MANAGER_VERSION="0.2.25"' in ORIGINAL
assert b'MANAGER_VERSION="0.2.26"' in CANDIDATE
payload = CANDIDATE
ROWS = []


def digest(b):
    return hashlib.sha256(b).hexdigest()


def snapshot():
    files = {}
    for root in ['/etc/twebproxy/instances', '/etc/twebproxy/backends', '/srv/twebproxy']:
        for f in sorted(Path(root).rglob('*')):
            if f.is_file():
                files[str(f)] = digest(f.read_bytes())
    global_lines = Path('/etc/twebproxy/global.env').read_text().splitlines()
    return {'canonical_files': files,
            'global_without_manager_version': digest('\n'.join(l for l in global_lines if not l.startswith('MANAGER_VERSION=')).encode()),
            'manager': digest(BIN.read_bytes()), 'copy': digest(COPY.read_bytes())}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/api/releases/latest':
            body = json.dumps({'tag_name': 'v0.2.26', 'draft': False, 'prerelease': False,
                               'html_url': 'https://github.com/Lazarev33/twebproxy-manager/releases/tag/v0.2.26'}).encode()
        elif self.path == '/raw/v0.2.26/twebproxy-manager.sh':
            body = payload
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


cert, key = OUT/'loopback.crt', OUT/'loopback.key'
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1',
                '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
wrapper = OUT/'update-wrapper.sh'
wrapper.write_text('source /usr/local/sbin/twebproxy\nMANAGER_API_URL="$TEST_BASE/api"\nMANAGER_RAW_URL="$TEST_BASE/raw"\nmanager_update_cmd "$@"\n')
env = {**os.environ, 'TEST_BASE': 'https://127.0.0.1:'+str(server.server_port),
       'CURL_CA_BUNDLE': str(cert), 'TWEBPROXY_NO_LOG': '1',
       'TWEBPROXY_ERROR_SNAPSHOT': '1', 'TWEBPROXY_UI_LANGUAGE': 'ru', 'NO_COLOR': '1'}


def run(label, command, expected=None, stdin=''):
    p = subprocess.run(command, input=stdin, text=True, capture_output=True, env=env, timeout=600)
    (OUT/(label+'.raw')).write_text(p.stdout+p.stderr)
    row = {'test': label, 'return_code': p.returncode,
           'expected': expected, 'stdout_outcomes': [l for l in p.stdout.splitlines()
                         if l.startswith(('UPDATE_', 'RESTORE_', 'ROLLBACK_'))]}
    ROWS.append(row)
    print(json.dumps(row), flush=True)
    if expected is not None:
        assert p.returncode == expected, row
    return p


def same_state(a, b):
    assert a['canonical_files'] == b['canonical_files'], 'canonical profile/site/backend change'
    assert a['global_without_manager_version'] == b['global_without_manager_version'], 'unrelated global configuration change'


try:
    site = Path('/srv/twebproxy/upgrade-lab.invalid/index.html')
    site.write_text(site.read_text()+'\n<!-- operator-preserved pre-RC edit -->\n')
    before = snapshot()
    (OUT/'before.json').write_text(json.dumps(before, indent=2)+'\n')
    run('baseline-bridge-status', [str(BIN), 'foreign-node', 'status'], 0)
    run('upgrade-25-to-26', ['bash', str(wrapper), '--sha256', digest(CANDIDATE)], 0)
    after = snapshot()
    same_state(before, after)
    assert after['manager'] == after['copy'] == digest(CANDIDATE)
    run('upgraded-local-status', [str(BIN), 'status', 'upgrade-lab.invalid', '--json'], 0)
    # Observe complete installed feature availability, without masking failures.
    bridge_result = run('upgraded-bridge-status', [str(BIN), 'foreign-node', 'status'])
    if '--bundle-only' in sys.argv:
        raise SystemExit(0 if bridge_result.returncode == 0 else 1)
    run('rollback-26-to-25', [str(BIN), 'manager-rollback', 'latest'], 0, 'да\n')
    rolled = snapshot()
    same_state(before, rolled)
    assert rolled['manager'] == rolled['copy'] == digest(ORIGINAL)
    fault = b'\nif [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == --help ]]; then exit 42; fi\n'
    payload = CANDIDATE.replace(b'\nAPP="twebproxy"', fault+b'\nAPP="twebproxy"', 1)
    assert payload != CANDIDATE
    p = run('failed-health-update-rollback', ['bash', str(wrapper), '--sha256', digest(payload)], 1)
    assert 'UPDATE_FAILED_ROLLBACK_SUCCESS' in p.stdout
    failed = snapshot()
    same_state(before, failed)
    assert failed['manager'] == failed['copy'] == digest(ORIGINAL)
    payload = CANDIDATE
    run('wrong-digest-refusal', ['bash', str(wrapper), '--sha256', '0'*64], 1)
    same_state(before, snapshot())
    state = Path('/etc/twebproxy/bridge/node.json')
    assert not state.exists(), 'Do not overwrite a real Bridge node'
    state.parent.mkdir(mode=0o700, exist_ok=True)
    state.write_text(json.dumps({'schema': 1, 'id': 'a'*32, 'phase': 'cleanup_pending',
                                 'cleanup_debt': ['fixture'], 'entry': {'local_port': 24000},
                                 'previous_port': 23980}))
    state.chmod(0o600)
    state_hash = digest(state.read_bytes())
    try:
        run('bridge-pending-update-refusal', ['bash', str(wrapper), '--sha256', digest(CANDIDATE)], 1)
        run('bridge-pending-add-refusal', ['bash', '/root/candidate26/twebproxy-manager.sh', 'foreign-node', 'add'], 1)
        assert digest(state.read_bytes()) == state_hash
        same_state(before, snapshot())
    finally:
        state.unlink()
    run('upgrade-25-to-26-final', ['bash', str(wrapper), '--sha256', digest(CANDIDATE)], 0)
    same_state(before, snapshot())
    # Supported complete-source repair installs the verified auxiliary bundle.
    run('complete-source-repair', ['bash', '/root/candidate26/twebproxy-manager.sh', 'repair', 'upgrade-lab.invalid'], 0)
    # Repair can legitimately update derived records; explicitly preserve secret,
    # site, TLS and canonical profile bytes, rather than assuming timestamps.
    repaired = snapshot()
    for name, h in before['canonical_files'].items():
        if '/profiles.d/' in name or name.endswith('/index.html') or name.endswith('/instance.env'):
            assert repaired['canonical_files'][name] == h, name
    run('complete-source-bridge-status', [str(BIN), 'foreign-node', 'status'], 0)
    (OUT/'after.json').write_text(json.dumps(repaired, indent=2)+'\n')
    print('UPGRADE_ROLLBACK_STATE_PRESERVATION=PASS', flush=True)
finally:
    server.shutdown()
    server.server_close()
    key.unlink(missing_ok=True)
    (OUT/'RESULTS.json').write_text(json.dumps({'rows': ROWS, 'loopback_trusted_TLS': True,
        'public_ACME_test': False, 'actual_candidate_SHA256': digest(CANDIDATE),
        'original_SHA256': digest(ORIGINAL)}, indent=2)+'\n')
if bridge_result.returncode:
    print('BLOCKER: updater did not preserve installed Bridge command availability', flush=True)
    raise SystemExit(1)
