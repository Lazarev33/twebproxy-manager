#!/usr/bin/env python3
"""Actual generated guard and strict verifier on the installed Bash/jq/nft.

Root required; every nft operation is confined to a fresh network namespace.
No systemd unit, host rules, backend service or network interface is changed.
Run: sudo python3 tests/final-rc/platform_firewall_compat.py [manager-script]
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def run(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, timeout=35, **kwargs)


def main():
    manager = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / 'twebproxy-manager.sh'
    if os.geteuid() != 0:
        raise SystemExit('Root and unshare network namespace capability required.')
    if os.environ.get('TWP_COMPAT_NETNS') != '1':
        env = {**os.environ, 'TWP_COMPAT_NETNS': '1'}
        p = subprocess.run(['unshare', '-n', sys.executable, str(Path(__file__).resolve()), str(manager)], env=env)
        raise SystemExit(p.returncode)
    assert os.readlink('/proc/self/ns/net') != os.readlink('/proc/1/ns/net'), 'Refusing host network namespace'
    results = []

    def check(name, passed, detail=''):
        results.append({'test': name, 'status': 'PASS' if passed else 'FAIL', 'detail': detail})

    env = {**os.environ, 'TWEBPROXY_NO_LOG': '1', 'TWEBPROXY_ERROR_SNAPSHOT': '1'}

    def bash(body, *args):
        return run(['bash', '-c', 'source "$1"; trap - ERR; set +e; shift; ' + body, '_', str(manager), *map(str, args)], env=env)

    with tempfile.TemporaryDirectory(prefix='twp-platform-compat-') as d:
        work = Path(d)
        os.chdir(work)
        generated = bash('BASE_DIR="$1/state"; BACKENDS_DIR="$BASE_DIR/backends"; LIBEXEC_DIR="$1/libexec"; '
                         'install -d -m 700 "$BASE_DIR" "$BACKENDS_DIR"; install -d -m 755 "$LIBEXEC_DIR"; '
                         'write_firewall_guard_helper', work)
        check('generated_guard_helper', generated.returncode == 0, generated.stderr)
        helper = work / 'libexec/firewall-guard'
        if generated.returncode == 0:
            with (work / 'guard.log').open('w+') as log:
                owner = subprocess.Popen([str(helper), 'hold'], stdout=log, stderr=log, cwd=work, start_new_session=True)
                try:
                    live = run([str(helper), 'wait'])
                    check('generated_guard_creates_empty_owned_table', live.returncode == 0, live.stderr)
                    if live.returncode == 0:
                        state = work / 'state/backends/test.env'
                        state.write_text('MTPROXY_CLIENT_PORT=23980\nMTPROXY_STATS_PORT=28980\n')
                        state.chmod(0o600)
                        reload = run([str(helper), 'reload', str(owner.pid)])
                        check('generated_guard_reload_populates_ports', reload.returncode == 0, reload.stderr)
                        state.unlink()
                        reload = run([str(helper), 'reload', str(owner.pid)])
                        check('generated_guard_reload_clears_ports', reload.returncode == 0, reload.stderr)
                    check('no_unintended_numeric_output_file', not any(p.name.isdigit() for p in work.iterdir()))
                finally:
                    os.killpg(owner.pid, signal.SIGTERM)
                    try:
                        owner.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(owner.pid, signal.SIGKILL)
                        owner.wait(timeout=5)
                absent = run(['nft', 'list', 'table', 'inet', 'twebproxy_guard'])
                check('owned_guard_removed_after_owner_group_exit', absent.returncode != 0)
        for ports in ['', '23980', '23980,28980']:
            run(['nft', 'delete', 'table', 'inet', 'twebproxy_backend'])
            rendered = bash('backend_fw_render "$1"', ports)
            applied = run(['nft', '-f', '-'], input=rendered.stdout)
            assert rendered.returncode == 0 and applied.returncode == 0, applied.stderr
            table = run(['nft', '-j', '-n', 'list', 'table', 'inet', 'twebproxy_backend'])
            assert table.returncode == 0, table.stderr
            file = work / 'table.json'
            file.write_text(table.stdout)
            verified = bash('backend_fw_ports_json "$1"', file)
            check('strict_verifier_' + (ports or 'empty'), verified.returncode == 0 and verified.stdout.strip() == ports,
                  verified.stderr)
            malformed = json.loads(table.stdout)
            malformed['nftables'].append({'rule': {'family': 'inet', 'table': 'twebproxy_backend', 'chain': 'input',
                                                 'expr': [{'accept': None}]}})
            file.write_text(json.dumps(malformed))
            rejected = bash('backend_fw_ports_json "$1"', file)
            check('strict_verifier_rejects_unexpected_rule_' + (ports or 'empty'), rejected.returncode != 0)
    report = {'environment': {'bash': run(['bash', '--version']).stdout.splitlines()[0],
                              'jq': run(['jq', '--version']).stdout.strip(),
                              'nft': run(['nft', '--version']).stdout.strip()},
              'isolation': 'real private network namespace; no host service changes', 'results': results}
    print(json.dumps(report, indent=2))
    return int(any(r['status'] == 'FAIL' for r in results))


if __name__ == '__main__':
    raise SystemExit(main())
