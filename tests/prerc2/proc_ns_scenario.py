#!/usr/bin/env python3
"""Inner part of the P1-B gate. MUST run under
    unshare -m --propagation private python3 -I proc_ns_scenario.py ...
so every mount it makes stays in a private mount namespace; the host /proc
policy and /etc/fstab are not changed by it.

Usage: proc_ns_scenario.py OUTFILE MANAGER STUB(none|mount-fail) MANAGER-ARGS...

1. Mounts a fresh proc WITHOUT hidepid over /proc (stacked on the host's
   hidden proc mount): the effective /proc of this namespace is unprotected.
2. Optionally puts a failing `mount` and the acceptance's `findmnt` stub
   (identical to its proc_failure_namespace.py) first in PATH.
3. Runs the manager command, then reports - booleans only, never the secret -
   how many live MTProxy processes an unprivileged account (nobody) can read
   the -S argument of, through the effective /proc of this namespace.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

out, manager, stub = sys.argv[1], sys.argv[2], sys.argv[3]
margs = sys.argv[4:]


def run(argv, **kw):
    return subprocess.run(argv, text=True, capture_output=True, **kw)


def top_proc_options():
    rows = {}
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        f = line.split()
        sep = f.index('-')
        if f[4] == '/proc' and f[sep + 1] == 'proc':
            rows[f[0]] = (f[1], f[5] + ',' + f[sep + 3])
    tops = [v[1] for k, v in rows.items() if not any(p == k for p, _ in rows.values())]
    return {'proc_mounts': len(rows), 'top_options': tops}


before = top_proc_options()
m = run(['mount', '-t', 'proc', 'proc', '/proc', '-o', 'nosuid,nodev,noexec,hidepid=0'])
if m.returncode:
    sys.exit('private proc mount failed: ' + m.stderr)
after_mount = top_proc_options()

env = dict(os.environ)
stubdir = None
if stub == 'mount-fail':
    stubdir = tempfile.mkdtemp(prefix='tpx-stub.')
    Path(stubdir, 'mount').write_text('#!/bin/sh\necho "$*" >> %s/calls.log\necho injected-mount-failure >&2\nexit 73\n' % stubdir)
    Path(stubdir, 'findmnt').write_text('#!/bin/sh\nif [ "$*" = "-no OPTIONS /proc" ]; then echo rw,nosuid,nodev,noexec,relatime; else exec /usr/bin/findmnt "$@"; fi\n')
    for n in ('mount', 'findmnt'):
        os.chmod(Path(stubdir, n), 0o755)
    env['PATH'] = stubdir + ':' + env['PATH']

t0 = time.monotonic_ns()
p = run(['bash', manager] + margs, env=env, stdin=subprocess.DEVNULL, timeout=420)
t1 = time.monotonic_ns()
text = p.stdout + '\n' + p.stderr
# Outcome lines only; hex32 redacted defensively, client links dropped.
keep = re.compile(r'(?i)proc|mount|fail-closed|ИТОГ|AUDIT|audit|refus|stopp|остановл')
lines = [re.sub(r'(?i)\b[0-9a-f]{32}\b', '<hex32>', s) for s in text.splitlines()
         if keep.search(s) and 'tg://' not in s and 'https://t.me' not in s][:40]

pids = run(['pgrep', '-x', 'mtproto-proxy']).stdout.split()
reader = ('import sys\np=sys.argv[1]\ntry: a=open("/proc/"+p+"/cmdline","rb").read().split(b"\\0")\n'
          'except OSError: a=[]\n'
          'print(int(any(a[i]==b"-S" and i+1<len(a) and len(a[i+1])==32 for i in range(len(a)-1))))')
readable = 0
for pid in pids:
    q = run(['setpriv', '--reuid=nobody', '--regid=nogroup', '--clear-groups', 'python3', '-I', '-c', reader, pid])
    readable += q.returncode == 0 and q.stdout.strip() == '1'
units = run(['systemctl', 'list-units', '--all', '--no-legend', '--plain', 'twebproxy-mtproxy@*.service']).stdout
calls = Path(stubdir, 'calls.log').read_text().count('\n') if stubdir and Path(stubdir, 'calls.log').exists() else 0
res = {
    'manager_args': margs[:1] + ['<host>'] * (len(margs) - 1),
    'stub': stub,
    'stub_mount_calls': calls,
    'proc_before': before,
    'proc_after_private_mount': after_mount,
    'proc_after_command': top_proc_options(),
    'rc': p.returncode,
    'duration_ms': (t1 - t0) // 1000000,
    'outcome_lines': lines,
    'backend_units_active': sum(1 for l in units.splitlines() if ' active running ' in l),
    'mtproxy_pids': len(pids),
    'nobody_readable_secrets': readable,
}
Path(out).write_text(json.dumps(res, indent=1, ensure_ascii=False) + '\n')
print(json.dumps({k: res[k] for k in ('rc', 'backend_units_active', 'mtproxy_pids', 'nobody_readable_secrets')}))
