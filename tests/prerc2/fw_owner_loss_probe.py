#!/usr/bin/env python3
"""P1-A real-host gate: backend exposure during owner loss and concurrent
nftables / systemd transitions.

Runs ONLY on the disposable lab host (/etc/twebproxy-disposable-lab must equal
/etc/machine-id) with an installed TWebProxy and >= 1 backend. A peer network
namespace joined by a veth pair connects continuously to every backend client
and stats port (non-loopback path into the host input hook) and to a control
listener. Every scenario is recorded with monotonic timestamps; the verdict is
derived from the raw probe samples only:

  exit 0  zero backend OPEN samples in every scenario, control reachable,
          and every unit recovered after every fault
  exit 1  at least one backend OPEN sample (exposure) or a non-recovery
  exit 77 not executable here (gate refused / no installation)

Usage: TWEBPROXY_PRERC_REAL=installed-test-host fw_owner_loss_probe.py OUTDIR [--quick]
No secrets are recorded: backend env files are read for port numbers only.
"""
import collections
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(2)
OUT = Path(sys.argv[1])
QUICK = '--quick' in sys.argv[2:]
HERE = Path(__file__).resolve().parent
NS = 'tpx2p%d' % os.getpid()
VH = 'tpxh%s' % str(os.getpid())[-5:]
VN = 'tpxn%s' % str(os.getpid())[-5:]
HOST = '10.214.31.1'
PEER = '10.214.31.2'
CONTROL = 39998

rows = []
snaps = []
scen = []
stop = threading.Event()
procs = []


def not_executed(msg):
    print('NOT_EXECUTED: ' + msg)
    sys.exit(77)


def stamp():
    return {'utc': datetime.now(timezone.utc).isoformat(), 'mono_ns': time.monotonic_ns()}


def run(label, argv, timeout=60):
    st = stamp()
    try:
        p = subprocess.run(argv, text=True, capture_output=True, timeout=timeout)
        rc, so, se = p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        rc, so, se = 124, '', 'TIMEOUT'
    en = stamp()
    rows.append({'label': label, 'start': st, 'end': en, 'argv': argv, 'rc': rc,
                 'stdout': so[-2000:], 'stderr': se[-2000:]})
    print('%s rc=%d' % (label, rc), flush=True)
    return rc


def sh(argv):
    return subprocess.run(argv, text=True, capture_output=True).stdout


def backend_units():
    return [l.split()[0] for l in sh(['systemctl', 'list-units', '--all', '--no-legend', '--plain',
                                      'twebproxy-mtproxy@*.service']).splitlines() if l.split()]


def unit_props(unit, props):
    out = sh(['systemctl', 'show', unit] + ['-p' + p for p in props])
    return dict(l.split('=', 1) for l in out.splitlines() if '=' in l)


def state():
    d = {'firewall': unit_props('twebproxy-firewall.service', ['ActiveState', 'SubState', 'MainPID', 'NRestarts'])}
    for u in UNITS:
        d[u] = unit_props(u, ['ActiveState', 'SubState', 'MainPID'])
    try:
        d['tables'] = {x['table']['name']: x['table'].get('handle')
                       for x in json.loads(sh(['nft', '-j', 'list', 'tables']))['nftables'] if 'table' in x}
    except Exception:
        d['tables'] = 'error'
    d['nft_children'] = sh(['pgrep', '-P', d['firewall'].get('MainPID', '0') or '0', '-x', 'nft']).split()
    d['mtproxy_pid_count'] = len(sh(['pgrep', '-x', 'mtproto-proxy']).split())
    d['time'] = stamp()
    return d


def watch():
    prev = None
    with open(OUT / 'state-changes.jsonl', 'w', buffering=1) as f:
        while not stop.is_set():
            d = state()
            key = json.dumps({k: v for k, v in d.items() if k != 'time'}, sort_keys=True)
            if key != prev:
                f.write(json.dumps(d) + '\n')
                prev = key
            stop.wait(0.1)


def monitor():
    p = subprocess.Popen(['nft', 'monitor', 'tables'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, bufsize=1)
    procs.append(p)
    with open(OUT / 'nft-monitor.jsonl', 'w', buffering=1) as f:
        for line in p.stdout:
            f.write(json.dumps({'time': stamp(), 'line': line.rstrip()}) + '\n')


def control_server():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((HOST, CONTROL))
    s.listen(64)
    s.settimeout(0.2)
    while not stop.is_set():
        try:
            c, _ = s.accept()
            c.close()
        except socket.timeout:
            pass
    s.close()


def snap(label):
    d = state()
    d['label'] = label
    snaps.append(d)
    return d


def recovered(timeout=40):
    """All units active again, the owned guard present with a live owner."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        d = state()
        ok = d['firewall'].get('ActiveState') == 'active' and d['nft_children'] and \
            isinstance(d['tables'], dict) and 'twebproxy_guard' in d['tables'] and \
            all(d[u].get('ActiveState') == 'active' for u in UNITS)
        if ok:
            return True
        time.sleep(0.5)
    return False


def target_pid(part):
    d = state()
    if part == 'shell':
        return d['firewall'].get('MainPID', '')
    return d['nft_children'][0] if d['nft_children'] else ''


def scenario(name, kill=None, concurrent=(), settle=3.0, pre=True, expect=True, hold=0.0):
    """kill: None | 'child' | 'shell'. concurrent: list of (tag, argv) started
    at the same barrier as the kill (or alone when kill is None)."""
    if pre and not recovered():
        raise RuntimeError('system not in steady state before ' + name)
    a = time.monotonic_ns()
    snap(name + '-before')
    # 'freeze': the guard shell is stopped (SIGSTOP, a hung guard that never
    # notices), its owning nft child is killed, nothing reacts for `hold` s.
    shell = target_pid('shell') if kill == 'freeze' else ''
    pid = target_pid('child' if kill == 'freeze' else kill) if kill else ''
    if kill and not pid:
        raise RuntimeError(name + ': no %s PID' % kill)
    if shell:
        run(name + ':stop-shell', ['kill', '-STOP', shell])
    gate = threading.Event()
    threads = []
    for tag, argv in concurrent:
        t = threading.Thread(target=lambda tg=tag, av=argv: (gate.wait(), run(name + ':' + tg, av)))
        t.start()
        threads.append(t)
    gate.set()
    if kill:
        run(name + ':kill-' + ('child' if kill == 'freeze' else kill), ['kill', '-KILL', pid])
    for t in threads:
        t.join(timeout=90)
    if hold:
        time.sleep(hold)
        snap(name + '-held')
    if shell:
        run(name + ':cont-shell', ['kill', '-CONT', shell])
    time.sleep(settle)
    rec = recovered() if expect else None
    b = time.monotonic_ns()
    snap(name + '-after')
    scen.append({'name': name, 'start_mono_ns': a, 'end_mono_ns': b, 'kill': kill,
                 'concurrent': [t for t, _ in concurrent], 'recovered': rec})
    print('scenario %s recovered=%s' % (name, rec), flush=True)


def read_probe():
    out = []
    try:
        text = (OUT / 'probe.tsv').read_text()
    except FileNotFoundError:
        return out
    for line in text.splitlines():
        try:
            mono, _wall, port, status = line.split('\t')
            out.append((int(mono), int(port), status))
        except ValueError:
            pass
    return out


# ---- gate (same decision as tests/lib/lab-gate.sh installed_host_gate_check) --
if os.environ.get('TWEBPROXY_PRERC_REAL') != 'installed-test-host':
    not_executed('TWEBPROXY_PRERC_REAL=installed-test-host is not set')
if not Path('/etc/twebproxy/instances').is_dir():
    not_executed('no installed TWebProxy instance directory')
try:
    if Path('/etc/twebproxy-disposable-lab').read_bytes() != Path('/etc/machine-id').read_bytes():
        not_executed('lab marker does not match machine-id')
except OSError:
    not_executed('no disposable-lab marker')
if os.geteuid() != 0:
    not_executed('needs root')
if not Path('/usr/local/sbin/twebproxy').exists():
    not_executed('TWebProxy is not installed')
UNITS = backend_units()
if not UNITS:
    not_executed('no backend units')
PORTS = set()
for f in Path('/etc/twebproxy/backends').glob('*.env'):
    text = f.read_text()
    for key in ('MTPROXY_CLIENT_PORT', 'MTPROXY_STATS_PORT'):
        m = re.search(r'^' + key + r"=['\"]?(\d+)", text, re.M)
        if m:
            PORTS.add(int(m.group(1)))
PORTS = sorted(PORTS)
OUT.mkdir(parents=True, exist_ok=True)

NFT_RESTART = ('nftables-restart', ['systemctl', 'restart', 'nftables.service'])
FLUSH = ('foreign-flush', ['nft', 'flush', 'ruleset'])
BACKEND_RESTARTS = [('backend-restart-%d' % i, ['systemctl', 'restart', u]) for i, u in enumerate(UNITS)]
FW_RESTART = ('firewall-restart', ['systemctl', 'restart', 'twebproxy-firewall.service'])
DAEMON_RELOAD = ('daemon-reload', ['systemctl', 'daemon-reload'])

result = {'units': len(UNITS), 'ports': PORTS, 'control_port': CONTROL, 'quick': QUICK}
exit_code = 0
try:
    run('netns-add', ['ip', 'netns', 'add', NS])
    run('veth-add', ['ip', 'link', 'add', VH, 'type', 'veth', 'peer', 'name', VN])
    run('veth-move', ['ip', 'link', 'set', VN, 'netns', NS])
    run('host-addr', ['ip', 'addr', 'add', HOST + '/30', 'dev', VH])
    run('host-up', ['ip', 'link', 'set', VH, 'up'])
    run('peer-addr', ['ip', 'netns', 'exec', NS, 'ip', 'addr', 'add', PEER + '/30', 'dev', VN])
    run('peer-up', ['ip', 'netns', 'exec', NS, 'ip', 'link', 'set', VN, 'up'])
    run('peer-lo', ['ip', 'netns', 'exec', NS, 'ip', 'link', 'set', 'lo', 'up'])
    threading.Thread(target=control_server, daemon=True).start()
    time.sleep(0.2)
    procs.append(subprocess.Popen(['ip', 'netns', 'exec', NS, 'python3', '-I', str(HERE / 'probe_peer.py'),
                                   HOST, str(OUT / 'probe.tsv'), str(CONTROL)] + [str(p) for p in PORTS]))
    threading.Thread(target=monitor, daemon=True).start()
    threading.Thread(target=watch, daemon=True).start()
    time.sleep(2)
    s = read_probe()
    if not any(p == CONTROL and st == 'OPEN' for _, p, st in s):
        raise RuntimeError('control listener not reachable from the peer')

    rep = 1 if QUICK else 3
    # 1. ordinary transitions (owner alive)
    for verb in ('start', 'reload', 'restart', 'stop'):
        scenario('normal-nftables-' + verb, concurrent=[(verb, ['systemctl', verb, 'nftables.service'])])
    for verb in ('restart', 'reload'):
        scenario('normal-firewall-' + verb, concurrent=[(verb, ['systemctl', verb, 'twebproxy-firewall.service'])])
    scenario('normal-firewall-stop', concurrent=[('stop', ['systemctl', 'stop', 'twebproxy-firewall.service'])],
             expect=False)
    scenario('normal-firewall-start', concurrent=[('start', ['systemctl', 'start', 'twebproxy-firewall.service'])],
             pre=False)
    scenario('normal-daemon-reload', concurrent=[DAEMON_RELOAD])
    scenario('normal-backend-restarts', concurrent=BACKEND_RESTARTS)
    scenario('normal-foreign-flush', concurrent=[FLUSH])
    run('nftables-start-for-faults', ['systemctl', 'start', 'nftables.service'])
    # 2. owner-child SIGKILL + concurrent foreign flush via nftables restart
    for i in range(rep):
        scenario('child-kill+nft-restart-%d' % (i + 1), kill='child', concurrent=[NFT_RESTART])
    # 3. owner-child SIGKILL + nftables restart + backend restarts
    for i in range(rep):
        scenario('child-kill+nft-restart+backend-restarts-%d' % (i + 1), kill='child',
                 concurrent=[NFT_RESTART] + BACKEND_RESTARTS)
    # 4. owner-child SIGKILL + direct foreign "flush ruleset"
    for i in range(rep):
        scenario('child-kill+foreign-flush-%d' % (i + 1), kill='child', concurrent=[FLUSH])
    # 5. guard-shell SIGKILL + nftables restart (+ flush)
    for i in range(rep):
        scenario('shell-kill+nft-restart-%d' % (i + 1), kill='shell', concurrent=[NFT_RESTART])
    scenario('shell-kill+foreign-flush+backend-restarts', kill='shell', concurrent=[FLUSH] + BACKEND_RESTARTS)
    # 6. concurrent service transitions without kills
    for i in range(rep):
        scenario('concurrent-fw+nft+backend+daemon-reload-%d' % (i + 1),
                 concurrent=[FW_RESTART, NFT_RESTART, DAEMON_RELOAD] + BACKEND_RESTARTS)
    # 7. hung guard shell: owner killed + foreign flush, nothing reacts for 10 s;
    #    only the per-backend cgroup filter can stand between peer and backend.
    for i in range(rep):
        scenario('frozen-shell+child-kill+flush-hold10s-%d' % (i + 1), kill='freeze',
                 concurrent=[FLUSH] + BACKEND_RESTARTS, hold=10.0)
    # 8. owner-child SIGKILL during a firewall restart and a flush
    scenario('child-kill+firewall-restart+flush', kill='child', concurrent=[FW_RESTART, FLUSH])
    run('nftables-stop-final', ['systemctl', 'stop', 'nftables.service'])
    time.sleep(1)
    result['final_recovered'] = recovered()
    snap('final')
except Exception as e:  # recorded; the verdict is still derived from samples
    result['error'] = repr(e)
    exit_code = 1
finally:
    stop.set()
    time.sleep(0.3)
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
    run('netns-delete', ['ip', 'netns', 'delete', NS])
    run('veth-delete', ['ip', 'link', 'delete', VH])
    (OUT / 'commands.json').write_text(json.dumps(rows, indent=1) + '\n')
    (OUT / 'snapshots.json').write_text(json.dumps(snaps, indent=1) + '\n')

samples = read_probe()
opens = [x for x in samples if x[1] != CONTROL and x[2] == 'OPEN']
per = []
for sc in scen:
    o = [x for x in opens if sc['start_mono_ns'] <= x[0] <= sc['end_mono_ns']]
    n = [x for x in samples if x[1] != CONTROL and sc['start_mono_ns'] <= x[0] <= sc['end_mono_ns']]
    per.append(dict(sc, backend_samples=len(n), backend_open=len(o),
                    open_by_port=dict(collections.Counter(x[1] for x in o)),
                    first_open_mono_ns=min((x[0] for x in o), default=None),
                    last_open_mono_ns=max((x[0] for x in o), default=None)))
result.update({
    'sample_count': len(samples),
    'backend_sample_count': sum(1 for x in samples if x[1] != CONTROL),
    'control_open_count': sum(1 for x in samples if x[1] == CONTROL and x[2] == 'OPEN'),
    'backend_open_count': len(opens),
    'backend_status_counts': dict(collections.Counter(x[2] for x in samples if x[1] != CONTROL)),
    'scenarios': per,
    'all_recovered': all(sc['recovered'] is not False for sc in scen) and result.get('final_recovered', False),
})
if opens or not result['all_recovered'] or result['control_open_count'] == 0:
    exit_code = 1
result['verdict'] = 'GREEN' if exit_code == 0 else 'RED'
(OUT / 'analysis.json').write_text(json.dumps(result, indent=1) + '\n')
print(json.dumps({k: result[k] for k in ('verdict', 'backend_open_count', 'control_open_count',
                                          'backend_sample_count', 'all_recovered')}), flush=True)
for sc in per:
    print('  %-48s open=%-4d samples=%-5d recovered=%s' % (sc['name'], sc['backend_open'],
                                                          sc['backend_samples'], sc['recovered']))
sys.exit(exit_code)
