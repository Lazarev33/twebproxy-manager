"""Drive the installed `twebproxy add` Quick Setup on a real hostname, waiting for each prompt.
Args: <out dir> <hostname> <tls: 1=caddy|2=nginx-le> [email]"""
import json, os, pty, re, select, signal, sys, time
OUT, HOST, TLS = sys.argv[1], sys.argv[2], sys.argv[3]; EMAIL = sys.argv[4] if len(sys.argv) > 4 else 'audit@example.com'
os.makedirs(OUT, exist_ok=True)
ANSI = re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Z0-9]|\x1b[=>]'); HEX = re.compile(rb'\b[0-9a-f]{32}\b')
pid, fd = pty.fork()
if pid == 0:
    os.execvpe('twebproxy', ['twebproxy', 'add'], dict(os.environ, TERM='xterm', COLUMNS='110', LINES='45', TWEBPROXY_UI_LANGUAGE='en'))
buf = b''; seen = [0]
def rd(t):
    r, _, _ = select.select([fd], [], [], t)
    if not r: return False
    try: d = os.read(fd, 65536)
    except OSError: d = b''
    if not d: return None
    globals()['buf'] += d; return True
def expect(pat, timeout=240):
    rx = re.compile(pat.encode(), re.S); end = time.time() + timeout
    while time.time() < end:
        if rx.search(ANSI.sub(b'', buf[seen[0]:])): seen[0] = len(buf); return
        if rd(0.3) is None: break
    raise TimeoutError(f'not seen {pat!r}; tail={ANSI.sub(b"", buf[-300:])!r}')
def send(s): time.sleep(0.3); os.write(fd, s.encode() + b'\r')
steps = [(r'(?i)hostname[^\n]*:\s*$', HOST), (r'Setup type:.*>\s*$', '1'),
         (r'Regular website on the hostname:.*>\s*$', '1'), (r'SSL / reverse proxy:.*>\s*$', TLS)]
if TLS == '2': steps.append((r'(?i)email[^\n]*:\s*$', EMAIL))
steps.append((r'Create it\? \[Y/n\]:\s*$', 'y'))
err = None
try:
    for pat, ans in steps: expect(pat); send(ans)
except TimeoutError as e: err = str(e)
# drain until exit
end = time.time() + 300; rc = None
while time.time() < end:
    rd(0.3); p, st = os.waitpid(pid, os.WNOHANG)
    if p:
        while rd(0.1): pass
        rc = os.waitstatus_to_exitcode(st); break
if rc is None:
    os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0); rc = 124
txt = HEX.sub(b'<secret>', ANSI.sub(b'', buf)).decode('utf-8', 'replace').replace('\r', '')
open(f'{OUT}/quick-setup-{HOST}.transcript.txt', 'w').write(txt)
res = {'host': HOST, 'tls_choice': TLS, 'exit_code': rc, 'error': err,
       'created': os.path.isfile(f'/etc/twebproxy/instances/{HOST}/instance.env'),
       'plan_quick': 'Setup:          quick' in txt, 'plan_stock': 'Network mode:   STOCK' in txt,
       'client_help': 'How to connect Telegram' in txt}
json.dump(res, open(f'{OUT}/quick-setup-{HOST}.json', 'w'), indent=1)
print(json.dumps(res))
sys.exit(0 if rc == 0 and res['created'] and err is None else 1)
