"""REAL-HOST harness (v0.2.23 pre-RC corrections): P1-G-01 offline restore truthfulness.

On the INSTALLED paths of a disposable test host: a trusted update to a
version-labelled candidate (loopback TLS release server; operator --sha256),
then `chattr +i /etc/twebproxy/global.env` and the real offline helper
`restore-update-backup restore-latest`. Records exit code, machine-readable
outcome line, both executable hashes and MANAGER_VERSION; then the same through
`twebproxy manager-rollback latest`; then the documented recovery path. Restores
the original installation and global.env bytes at the end. No secret is read.
Runs only with TWEBPROXY_PRERC_REAL=installed-test-host (else exit 77).
Usage: python3 -I restore-metadata-real.py <out dir>"""
import hashlib, http.server, json, os, pathlib, re, shutil, ssl, subprocess, sys, threading, time
def _marker_ok():
    try: return open('/etc/twebproxy-disposable-lab').readline().strip() == open('/etc/machine-id').readline().strip() and os.stat('/etc/twebproxy-disposable-lab').st_uid == 0
    except OSError: return False
if os.environ.get('TWEBPROXY_PRERC_REAL') != 'installed-test-host' or os.geteuid() != 0 or not os.path.exists('/usr/local/sbin/twebproxy') or not _marker_ok():
    print('NOT_EXECUTED: needs TWEBPROXY_PRERC_REAL=installed-test-host, root and an installed TWebProxy'); sys.exit(77)
OUT = pathlib.Path(sys.argv[1]).resolve(); OUT.mkdir(parents=True, exist_ok=True)
BIN = pathlib.Path('/usr/local/sbin/twebproxy'); COPY = pathlib.Path('/opt/twebproxy-manager/twebproxy-manager.sh')
GENV = pathlib.Path('/etc/twebproxy/global.env'); HELPER = '/usr/local/libexec/twebproxy/restore-update-backup'
TEXT = BIN.read_text(); ORIG = hashlib.sha256(BIN.read_bytes()).hexdigest(); GENV_ORIG = GENV.read_bytes()
V = re.search(r'^MANAGER_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$', TEXT, re.M).group(1)
a, b, c = map(int, V.split('.')); CV = f'{a}.{b}.{c + 50}'
CT = TEXT.replace(f'MANAGER_VERSION="{V}"', f'MANAGER_VERSION="{CV}"', 1).replace(f'MANAGER_RELEASE_VERSION="{V}-beta"', f'MANAGER_RELEASE_VERSION="{CV}-beta"', 1)
assert CT != TEXT
CAND = OUT / 'candidate.sh'; CAND.write_text(CT); DIG = hashlib.sha256(CT.encode()).hexdigest()
W = OUT / 'wrapper.sh'; W.write_text('#!/usr/bin/env bash\nsource /usr/local/sbin/twebproxy\nMANAGER_API_URL="$TEST_BASE/api"; MANAGER_RAW_URL="$TEST_BASE/raw"\nmanager_update_cmd "$@"\n'); W.chmod(0o700)
CRT, KEY = OUT / 'lo.crt', OUT / 'lo.key'
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(KEY), '-out', str(CRT), '-days', '1', '-subj', '/CN=127.0.0.1',
                '-addext', 'subjectAltName=IP:127.0.0.1'], check=True, capture_output=True)
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/api/releases/latest':
            body = json.dumps({'tag_name': f'v{CV}', 'draft': False, 'prerelease': False, 'html_url': f'https://github.com/Lazarev33/twebproxy-manager/releases/tag/v{CV}'}).encode()
        elif self.path == f'/raw/v{CV}/twebproxy-manager.sh': body = CT.encode()
        else: self.send_error(404); return
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *x): pass
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H); ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(str(CRT), str(KEY))
srv.socket = ctx.wrap_socket(srv.socket, server_side=True); threading.Thread(target=srv.serve_forever, daemon=True).start()
ENV = {**os.environ, 'TEST_BASE': f'https://127.0.0.1:{srv.server_port}', 'CURL_CA_BUNDLE': str(CRT)}
def sha(p): return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()[:16]
def gver(): return next((l.split('=', 1)[1] for l in GENV.read_text().splitlines() if l.startswith('MANAGER_VERSION=')), None)
def st(): return {'bin': sha(BIN), 'copy': sha(COPY), 'global_env_version': gver()}
ROWS = []
def run(label, args, stdin=''):
    t = time.monotonic(); p = subprocess.run(args, input=stdin, capture_output=True, text=True, env=ENV, timeout=600)
    (OUT / f'{label}.log').write_text(re.sub(r'\b[0-9a-f]{32}\b', '<hex32>', p.stdout + p.stderr))
    lines = (p.stdout + p.stderr).splitlines()
    r = {'step': label, 'command': ' '.join(args), 'exit_code': p.returncode, 'seconds': round(time.monotonic() - t, 2),
         'outcome_lines': [l for l in lines if re.match(r'^(RESTORE_\w+|ROLLBACK_\w+|UPDATE_\w+)', l)], 'stderr_tail': p.stderr.strip().splitlines()[-3:], 'state': st()}
    ROWS.append(r); print(label, r['exit_code'], r['outcome_lines'], r['state'], flush=True); return r
R = {'installed_version': V, 'candidate_version': CV, 'installed_sha256': ORIG[:16]}
immutable = False
try:
    R['start'] = st()
    u = run('update', ['bash', str(W), '--sha256', DIG]); assert u['exit_code'] == 0, u
    subprocess.run(['chattr', '+i', str(GENV)], check=True); immutable = True
    h = run('helper-restore-latest-immutable', [HELPER, 'restore-latest'])
    R['helper'] = {'exit_code': h['exit_code'], 'outcome': h['outcome_lines'], 'executables_restored': h['state']['bin'] == ORIG[:16] == h['state']['copy'],
                   'metadata': h['state']['global_env_version'], 'false_success': h['exit_code'] == 0 and any(l.startswith('RESTORE_SUCCESS') for l in h['outcome_lines'])}
    # second partial path through the CLI: update again, rollback via the manager command
    subprocess.run(['chattr', '-i', str(GENV)], check=True); immutable = False
    u2 = run('update-2', ['bash', str(W), '--sha256', DIG, '--force'])
    subprocess.run(['chattr', '+i', str(GENV)], check=True); immutable = True
    cl = run('cli-rollback-immutable', ['twebproxy', 'manager-rollback', 'latest'], stdin='y\n')
    R['cli'] = {'update2_exit': u2['exit_code'], 'exit_code': cl['exit_code'], 'outcome': cl['outcome_lines'], 'executables_restored': cl['state']['bin'] == ORIG[:16] == cl['state']['copy'],
                'metadata': cl['state']['global_env_version'], 'false_success': cl['exit_code'] == 0 and any(l.startswith('RESTORE_SUCCESS') for l in cl['outcome_lines'])}
    rp = run('repair-while-immutable', ['twebproxy', 'repair', os.listdir('/etc/twebproxy/instances')[0]])
    R['repair_while_immutable'] = {'exit_code': rp['exit_code'], 'metadata': rp['state']['global_env_version'], 'stderr_tail': rp['stderr_tail']}
    subprocess.run(['chattr', '-i', str(GENV)], check=True); immutable = False
    rp2 = run('repair-after-clearing', ['twebproxy', 'repair', os.listdir('/etc/twebproxy/instances')[0]])
    R['recovery'] = {'exit_code': rp2['exit_code'], 'metadata': rp2['state']['global_env_version'], 'consistent': rp2['state']['global_env_version'] == V}
finally:
    if immutable: subprocess.run(['chattr', '-i', str(GENV)])
    srv.shutdown(); srv.server_close()
    if sha(BIN) != ORIG[:16]: subprocess.run(['twebproxy', 'manager-rollback', 'latest'], input='y\n', text=True, capture_output=True)
    GENV.write_bytes(GENV_ORIG); os.chmod(GENV, 0o600)
    R['end'] = st(); R['end_matches_start'] = R['end'] == R.get('start'); R['runs'] = ROWS
    for f in (CAND, KEY): f.unlink(missing_ok=True)
    (OUT / 'restore-metadata-results.json').write_text(json.dumps(R, indent=1) + '\n')
bad = R['helper']['false_success'] or R['cli']['false_success'] or R['helper']['exit_code'] == 0 or R['cli']['exit_code'] == 0 or not R['recovery']['consistent']
print('VERDICT:', 'FAIL (P1-G-01 reproducible)' if bad else 'PASS (partial restore reported non-zero, recovery consistent)')
sys.exit(1 if bad else 0)
