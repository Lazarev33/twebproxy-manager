#!/usr/bin/env python3
"""Stage G real-process oracle for the two P1 defects found on real Linux in Stage F.

Everything that decides the outcome is real: the manager under test runs as its
own CLI (`twebproxy manager-update --sha256 …`, real main/logging/dispatch), its
health probes run a candidate built from the real manager, downloads use the
real curl with real TLS against a loopback-only test server, and the lock,
pipes, signals and process states are observed by the kernel (/proc, flock -n).

Confinement: both the installed manager and the candidate are test artifacts of
the manager under test whose path constants (BASE_DIR, MANAGER_BIN, …, the lock
file) and release URLs are rewritten into a private sandbox, so nothing outside
it is read or written; the TLS server listens on 127.0.0.1 only. The candidate
artifact differs from the manager under test only in those constants, its
version markers (0.2.90) and, for scenario A, one injected line.

  A  The candidate's first `--help` leaves a background child holding stdout.
     Expected: the update ends within the probe bound, the child does not
     outlive the probe, the lock is free, both copies verified.
  B  The candidate download is held open by the server; only the updater
     process is SIGKILLed. Expected: only the updater holds the lock before the
     kill, the lock is free right after it, a concurrent update is refused while
     the owner lives, and the next update recovers.
  C  The candidate's first `--help` hangs ignoring SIGTERM and leaves a child
     holding stdout. Expected: the probe is killed within its bound, health
     fails, the previous manager is restored (UPDATE_FAILED_ROLLBACK_SUCCESS),
     no child is left and the lock is free.

Usage: real-process-oracle.py [manager] [A|B|C ...]   exit 0 PASS, 1 FAIL, 77 NOT_EXECUTED
"""
import hashlib, http.server, json, os, pathlib, re, shutil, signal, socketserver, ssl
import subprocess, sys, tempfile, threading, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
MGR = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 and not re.fullmatch(r'[ABC]', sys.argv[1]) else ROOT / 'twebproxy-manager.sh').resolve()
WANT = [a for a in sys.argv[1:] if re.fullmatch(r'[ABC]', a)] or ['A', 'B', 'C']
SLUG = 'Lazarev33/twebproxy-manager'
NEW = '0.2.90'
CONSTANTS = ('BASE_DIR SITES_DIR TPROXY_SRC MTPROXY_SRC TPROXY_BIN MANAGER_BIN LIBEXEC_DIR SYSTEMD_DIR CADDY_DIR '
             'NGINX_DIR LE_DIR ACME_WEBROOT DPI_NFT_BIN DPI_DOC_DIR PROJECT_DIR UPDATE_BACKUP_PARENT UPDATE_LOCK_FILE').split()
RESULTS = {'manager': str(MGR), 'scenarios': {}}
FAILS = 0


def log(*a):
    print(*a, flush=True)


def check(scn, name, ok, detail=''):
    global FAILS
    RESULTS['scenarios'][scn].setdefault('checks', []).append({'check': name, 'result': 'PASS' if ok else 'FAIL', 'detail': detail})
    log(f"{'PASS' if ok else 'FAIL'} real-{scn}.{name}{': ' + detail if detail else ''}")
    FAILS += 0 if ok else 1


def need(tool):
    if shutil.which(tool) is None:
        log(f'NOT_EXECUTED real-process-oracle: {tool} missing'); sys.exit(77)


if os.geteuid() != 0:
    log('NOT_EXECUTED real-process-oracle: needs root (sandboxed chown/flock)'); sys.exit(77)
for t in ('openssl', 'curl', 'flock', 'jq', 'timeout', 'bash'):
    need(t)

sha = lambda p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


class Server:
    """HTTPS on 127.0.0.1: releases/latest JSON and raw/<tag>/twebproxy-manager.sh."""
    def __init__(self, workdir):
        self.dir = workdir
        self.cert, self.key = workdir / 'cert.pem', workdir / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=127.0.0.1',
                        '-addext', 'subjectAltName=IP:127.0.0.1', '-keyout', str(self.key), '-out', str(self.cert)],
                       check=True, capture_output=True)
        self.artifact = b''
        self.hold = threading.Event(); self.hold.set()      # set = respond immediately
        self.arrived = threading.Event()
        self.requests = []
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_GET(self):
                outer.requests.append(self.path)
                if self.path == f'/api/repos/{SLUG}/releases/latest':
                    body = json.dumps({'tag_name': f'v{NEW}', 'draft': False, 'prerelease': False,
                                       'html_url': f'https://github.com/{SLUG}/releases/tag/v{NEW}'}).encode()
                elif self.path == f'/raw/v{NEW}/twebproxy-manager.sh':
                    outer.arrived.set(); outer.hold.wait(120)
                    body = outer.artifact
                else:
                    self.send_response(404); self.end_headers(); return
                self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers()
                try: self.wfile.write(body)
                except OSError: pass

        class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True
        self.httpd = S(('127.0.0.1', 0), H)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(self.cert, self.key)
        self.httpd.socket = ctx.wrap_socket(self.httpd.socket, server_side=True)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.hold.set(); self.httpd.shutdown(); self.httpd.server_close()


class Sandbox:
    def __init__(self, name, server):
        self.base = pathlib.Path(tempfile.mkdtemp(prefix=f'twebproxy-g-oracle-{name}.', dir='/tmp'))
        self.root = self.base / 'root'
        self.server = server
        for d in ('usr/local/sbin', 'usr/local/bin', 'usr/local/libexec', 'opt/twebproxy-manager', 'etc/twebproxy',
                  'var/lib', 'run/lock', 'srv'):
            (self.root / d).mkdir(parents=True, exist_ok=True)
        self.lock = self.root / 'run/lock/twebproxy-manager-update.lock'
        self.bin = self.root / 'usr/local/sbin/twebproxy'
        self.copy = self.root / 'opt/twebproxy-manager/twebproxy-manager.sh'
        self.env = {**os.environ, 'CURL_CA_BUNDLE': str(server.cert), 'TWEBPROXY_ERROR_SNAPSHOT': '1',
                    'TWEBPROXY_UI_LANGUAGE': 'en', 'TWEBPROXY_UPDATE_LOCK_WAIT': '2', 'G_ORACLE_SANDBOX': str(self.base)}
        self.env.pop('TWEBPROXY_NO_LOG', None)   # the real CLI logs into the sandboxed PROJECT_DIR

    def artifact(self, version=None, inject=None):
        text = MGR.read_text()
        for c in CONSTANTS:
            text, n = re.subn(rf'^{c}="/', f'{c}="{self.root}/', text, count=1, flags=re.M)
            assert n == 1, c
        port = self.server.port
        text, n = re.subn(r'^MANAGER_API_URL=.*$', f'MANAGER_API_URL="https://127.0.0.1:{port}/api/repos/$MANAGER_REPO_SLUG"', text, count=1, flags=re.M); assert n == 1
        text, n = re.subn(r'^MANAGER_RAW_URL=.*$', f'MANAGER_RAW_URL="https://127.0.0.1:{port}/raw"', text, count=1, flags=re.M); assert n == 1
        if version:
            text = re.sub(r'^MANAGER_VERSION=".*"$', f'MANAGER_VERSION="{version}"', text, count=1, flags=re.M)
            text = re.sub(r'^MANAGER_RELEASE_VERSION=".*"$', f'MANAGER_RELEASE_VERSION="{version}-beta"', text, count=1, flags=re.M)
            text = re.sub(r'^# TWebProxy Manager v.*$', f'# TWebProxy Manager v{version}-beta', text, count=1, flags=re.M)
        if inject:
            text, n = re.subn(r'^usage\(\) \{$', 'usage() {\n' + inject, text, count=1, flags=re.M); assert n == 1
        return text

    def install(self):
        text = self.artifact()
        for p in (self.bin, self.copy):
            p.write_text(text); os.chown(p, 0, 0); os.chmod(p, 0o755)
        (self.root / 'etc/twebproxy/global.env').write_text('MANAGER_VERSION=x\nTPROXY_UPSTREAM_COMMIT=unknown\nMTPROXY_COMMIT=unknown\n')
        os.chmod(self.root / 'etc/twebproxy/global.env', 0o600)
        r = subprocess.run(['bash', '-c', 'source "$1"; trap - ERR; stage4_install_restore_helper yes', '_', str(self.bin)],
                           env={**self.env, 'TWEBPROXY_NO_LOG': '1'}, capture_output=True, text=True, timeout=120)
        assert r.returncode == 0, r.stderr
        self.old = sha(self.bin)

    def cli(self, *args, extra=None):
        return [str(self.bin), 'manager-update', *args], {**self.env, **(extra or {})}

    def lock_free(self):
        return subprocess.run(['flock', '-n', str(self.lock), 'true']).returncode == 0

    def lock_holders(self):
        target = os.path.realpath(self.lock); out = []
        for pid in filter(str.isdigit, os.listdir('/proc')):
            try:
                for fd in os.listdir(f'/proc/{pid}/fd'):
                    if os.readlink(f'/proc/{pid}/fd/{fd}') == target:
                        comm = pathlib.Path(f'/proc/{pid}/comm').read_text().strip()
                        out.append(f'{pid}:{comm}'); break
            except OSError:
                pass
        return sorted(set(out))

    def copies(self):
        return {'bin': sha(self.bin), 'copy': sha(self.copy)}

    def cleanup(self):
        for pid in filter(str.isdigit, os.listdir('/proc')):
            try:
                if f'G_ORACLE_SANDBOX={self.base}'.encode() in pathlib.Path(f'/proc/{pid}/environ').read_bytes().split(b'\0'):
                    os.kill(int(pid), signal.SIGKILL)
            except OSError:
                pass
        time.sleep(0.3)
        shutil.rmtree(self.base, ignore_errors=True)


def alive(pid):
    try:
        return pathlib.Path(f'/proc/{pid}/stat').read_text().split(')')[-1].split()[0] != 'Z'
    except OSError:
        return False


def scenario_a(server):
    scn = 'A'; RESULTS['scenarios'][scn] = {'title': 'candidate --help leaves a child holding stdout (real manager candidate)'}
    sb = Sandbox('A', server)
    try:
        sb.install()
        pidfile = sb.base / 'child.pid'
        inject = (f'  if [[ ! -e {sb.base}/child.spawned ]]; then : > {sb.base}/child.spawned; '
                  f'sleep 40 & echo "$!" > {pidfile}; fi')
        cand = sb.artifact(NEW, inject).encode(); server.artifact = cand
        digest = hashlib.sha256(cand).hexdigest()
        cmd, env = sb.cli('--sha256', digest)
        RESULTS['scenarios'][scn]['command'] = ' '.join(['twebproxy', 'manager-update', '--sha256', digest])
        start = time.monotonic()
        p = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        out = b''
        try:
            out, _ = p.communicate(timeout=25)
        except subprocess.TimeoutExpired:
            pass
        t25 = round(time.monotonic() - start, 2)
        child = int(pidfile.read_text()) if pidfile.exists() else None
        state25 = {'running': p.poll() is None, 'child_alive': bool(child and alive(child)),
                   'lock_free': sb.lock_free(), 'copies': sb.copies()}
        if p.poll() is None:
            out, _ = p.communicate(timeout=120)
        elapsed = round(time.monotonic() - start, 2)
        text = out.decode(errors='replace')
        time.sleep(0.5)
        final = {'exit_code': p.returncode, 'seconds': elapsed, 'child_alive': bool(child and alive(child)),
                 'lock_free': sb.lock_free(), 'copies': sb.copies(), 'candidate_sha256': digest, 'old_sha256': sb.old,
                 'result_line': next((l for l in text.splitlines() if l.startswith('UPDATE_')), None)}
        RESULTS['scenarios'][scn].update({'observed_at_25s': state25 | {'seconds': t25}, 'final': final})
        log(f'A observed: {json.dumps(RESULTS["scenarios"][scn]["observed_at_25s"])}'); log(f'A final: {json.dumps(final)}')
        check(scn, 'child-spawned', child is not None, f'child pid {child}')
        check(scn, 'bounded', not state25['running'], f'update still running at {t25}s' if state25['running'] else f'finished in {elapsed}s')
        check(scn, 'success', p.returncode == 0 and final['result_line'] and final['result_line'].startswith('UPDATE_SUCCESS'), f"exit {p.returncode}, {final['result_line']}")
        check(scn, 'installed', final['copies'] == {'bin': digest, 'copy': digest}, 'both copies == candidate')
        check(scn, 'no-orphan-at-25s', not state25['child_alive'], 'stdout-holding child gone by 25s')
        check(scn, 'lock-free-at-25s', state25['lock_free'], 'lock free by 25s')
    finally:
        sb.cleanup()


def scenario_b(server):
    scn = 'B'; RESULTS['scenarios'][scn] = {'title': 'parent-only SIGKILL while real curl waits for the artifact'}
    sb = Sandbox('B', server)
    try:
        sb.install()
        cand = sb.artifact(NEW).encode(); server.artifact = cand
        digest = hashlib.sha256(cand).hexdigest()
        server.hold.clear(); server.arrived.clear()
        cmd, env = sb.cli('--sha256', digest)
        RESULTS['scenarios'][scn]['command'] = ' '.join(['twebproxy', 'manager-update', '--sha256', digest])
        p = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        arrived = server.arrived.wait(60); time.sleep(0.5)
        holders = sb.lock_holders()
        cmd2, env2 = sb.cli('--sha256', digest, extra={'TWEBPROXY_UPDATE_LOCK_WAIT': '1'})
        second = subprocess.run(cmd2, env=env2, capture_output=True, text=True, timeout=60)
        os.kill(p.pid, signal.SIGKILL); p.wait(10)
        time.sleep(0.3); free_03 = sb.lock_free()
        time.sleep(1.7); free_2 = sb.lock_free()
        curl_alive = [h for h in sb.lock_holders()]
        copies_kill = sb.copies()
        server.hold.set(); time.sleep(2)
        free_after_release = sb.lock_free()
        staging = (sb.root / 'var/lib/twebproxy/update-staging').exists()
        cmd3, env3 = sb.cli('--sha256', digest)
        nxt = subprocess.run(cmd3, env=env3, capture_output=True, text=True, timeout=180)
        rec = {'artifact_request_arrived': arrived, 'lock_holders_during_download': holders,
               'second_update_exit_code': second.returncode,
               'second_update_result': next((l for l in (second.stdout + second.stderr).splitlines() if 'update' in l.lower() and ('lock' in l.lower() or 'running' in l.lower())), ''),
               'parent_exit_code': p.returncode, 'lock_free_0.3s_after_kill': free_03, 'lock_free_2s_after_kill': free_2,
               'lock_holders_after_kill': curl_alive, 'lock_free_after_server_release': free_after_release,
               'stale_staging_before_next_update': staging, 'copies_after_kill': copies_kill, 'old_sha256': sb.old,
               'next_update_exit_code': nxt.returncode,
               'next_update_result': next((l for l in nxt.stdout.splitlines() if l.startswith('UPDATE_')), None),
               'staging_after_next_update': (sb.root / 'var/lib/twebproxy/update-staging').exists(),
               'copies_after_next_update': sb.copies(), 'candidate_sha256': digest}
        RESULTS['scenarios'][scn]['observed'] = rec
        log(f'B observed: {json.dumps(rec)}')
        check(scn, 'download-blocked', arrived, 'real curl request reached the test server')
        mgr = [h for h in holders if h.startswith(f'{p.pid}:')]
        check(scn, 'only-owner-holds-lock', holders == mgr and len(mgr) == 1, f'holders {holders}, updater pid {p.pid}')
        check(scn, 'concurrent-refused', second.returncode != 0, f'second update exit {second.returncode}')
        check(scn, 'lock-free-0.3s-after-parent-kill', free_03)
        check(scn, 'lock-free-2s-after-parent-kill', free_2)
        check(scn, 'copies-unchanged', rec['copies_after_kill'] == {'bin': sb.old, 'copy': sb.old})
        check(scn, 'next-update-recovers', nxt.returncode == 0 and (rec['next_update_result'] or '').startswith('UPDATE_SUCCESS')
              and rec['copies_after_next_update'] == {'bin': digest, 'copy': digest} and not rec['staging_after_next_update'],
              f"exit {nxt.returncode}, {rec['next_update_result']}")
    finally:
        server.hold.set(); sb.cleanup()


def scenario_c(server):
    scn = 'C'; RESULTS['scenarios'][scn] = {'title': 'candidate --help hangs ignoring SIGTERM, with a stdout-holding child: failed health -> rollback'}
    sb = Sandbox('C', server)
    try:
        sb.install()
        pidfile = sb.base / 'child.pid'
        inject = (f'  if [[ ! -e {sb.base}/child.spawned ]]; then : > {sb.base}/child.spawned; '
                  f'sleep 90 & echo "$!" > {pidfile}; trap "" TERM; sleep 60; fi')
        cand = sb.artifact(NEW, inject).encode(); server.artifact = cand
        digest = hashlib.sha256(cand).hexdigest()
        cmd, env = sb.cli('--sha256', digest)
        RESULTS['scenarios'][scn]['command'] = ' '.join(['twebproxy', 'manager-update', '--sha256', digest])
        start = time.monotonic()
        p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=180)
        elapsed = round(time.monotonic() - start, 2)
        time.sleep(0.5)
        child = int(pidfile.read_text()) if pidfile.exists() else None
        text = p.stdout + p.stderr
        rec = {'exit_code': p.returncode, 'seconds': elapsed, 'child_alive': bool(child and alive(child)),
               'lock_free': sb.lock_free(), 'copies': sb.copies(), 'old_sha256': sb.old, 'candidate_sha256': digest,
               'result_line': next((l for l in text.splitlines() if l.startswith('UPDATE_')), None)}
        RESULTS['scenarios'][scn]['observed'] = rec
        log(f'C observed: {json.dumps(rec)}')
        check(scn, 'bounded', elapsed < 45, f'{elapsed}s (probe 15 s + 5 s kill grace, then rollback)')
        check(scn, 'truthful-failure', p.returncode != 0 and (rec['result_line'] or '') .startswith('UPDATE_FAILED_ROLLBACK_SUCCESS'), f"exit {p.returncode}, {rec['result_line']}")
        check(scn, 'restored', rec['copies'] == {'bin': sb.old, 'copy': sb.old}, 'both copies == previous manager')
        check(scn, 'no-orphan', child is not None and not rec['child_alive'], f'child pid {child}')
        check(scn, 'lock-free', rec['lock_free'])
    finally:
        sb.cleanup()


work = pathlib.Path(tempfile.mkdtemp(prefix='twebproxy-g-oracle-tls.', dir='/tmp'))
server = Server(work)
try:
    log(f'real-process-oracle: manager {MGR} sha256 {sha(MGR)}; TLS test server 127.0.0.1:{server.port}')
    if 'A' in WANT: scenario_a(server)
    if 'B' in WANT: scenario_b(server)
    if 'C' in WANT: scenario_c(server)
finally:
    server.close(); shutil.rmtree(work, ignore_errors=True)
out = os.environ.get('G_ORACLE_RESULTS')
if out:
    pathlib.Path(out).write_text(json.dumps(RESULTS, indent=1) + '\n')
log(f'\nreal-process-oracle: {sum(len(s.get("checks", [])) for s in RESULTS["scenarios"].values()) - FAILS} pass, {FAILS} fail')
sys.exit(1 if FAILS else 0)
