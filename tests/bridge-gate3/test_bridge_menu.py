"""Local process/control-flow regression; no real nodes, services or network.

The actual Bash menu/CLI dispatch and actual controller Add guard run. The
launcher transport is substituted to inject a temporary state path and forbid
provisioning. Status/diagnose responses are fixtures, not connectivity results.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(os.environ.get('TWEBPROXY_TEST_SOURCE_ROOT', Path(__file__).resolve().parents[2]))

CONTROLLER = r'''
import os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import controller as c
c.ROOT = Path(sys.argv[2]); c.STATE = c.ROOT / 'node.json'
c.LANG = os.environ['TWEBPROXY_BRIDGE_LANG']
def forbidden(*args, **kwargs):
    (c.ROOT / 'forbidden-call').write_text('provisioning/network call attempted')
    raise AssertionError('unexpected provisioning/network call')
c.choose_instance = c.local = c.journal = c.rollback = forbidden
c.socket.create_connection = c.socket.gethostbyname = forbidden
c.subprocess.run = forbidden
try:
    c.add(None)
except Exception as e:
    c.print(str(e) if isinstance(e, c.Fault) else type(e).__name__, file=sys.stderr)
    sys.exit(1)
'''

HARNESS = r'''
source "$MANAGER_SOURCE"
disable_colors
need_root(){ :; }
need_systemd(){ :; }
core_installed(){ return 0; }
collect_overview(){ :; }
tui_render_dashboard(){ :; }
clear(){ :; }
bridge_launcher(){
  printf '%s\n' "$*" >> "$FIXTURE/calls"
  if [[ "${FAULT_RC:-0}" != 0 ]]; then
    printf 'INJECTED_OPERATION_FAILURE\n' >&2
    [[ "${FAULT_EXIT:-0}" != 1 ]] || exit "$FAULT_RC"
    return "$FAULT_RC"
  fi
  case "$1" in
    add) TWEBPROXY_BRIDGE_LANG="$UI_LANGUAGE" python3 "$FIXTURE/controller-run.py" "$BRIDGE_SOURCE" "$FIXTURE";;
    status|diagnose) printf 'FIXTURE_READ_ONLY_%s\n' "$1";;
    repair|remove) printf 'FIXTURE_CANCELLED_%s\n' "$1";;
    *) return 64;;
  esac
}
main "$@"
'''


class BridgeMenu(unittest.TestCase):
    def run_case(self, phase='active', command='menu', language='ru', fault=0, explicit_exit=False,
                 choices='9\n1\n\n2\n\n3\n\n0\n0\n'):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Path(temp)
            state = fixture / 'node.json'
            state.write_text(json.dumps({'id': 'a' * 32, 'phase': phase,
                                         'cleanup_debt': ['fixture debt'] if phase != 'active' else []}))
            state.chmod(0o600)
            credential = fixture / 'credential-fixture'
            credential.write_text('not-a-real-credential')
            credential.chmod(0o600)
            (fixture / 'controller-run.py').write_text(CONTROLLER)
            before = {p.name: (hashlib.sha256(p.read_bytes()).hexdigest(),
                               p.stat().st_mode, p.stat().st_mtime_ns, p.stat().st_ino)
                      for p in [state, credential]}
            # Trap any accidental host mutation, including from future menu changes.
            bindir = fixture / 'bin'
            bindir.mkdir()
            for name in ['systemctl', 'nft', 'ip', 'wg', 'ssh', 'curl']:
                p = bindir / name
                p.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$FIXTURE/forbidden-call"\nexit 97\n')
                p.chmod(0o700)
            env = {**os.environ, 'FIXTURE': str(fixture),
                   'MANAGER_SOURCE': str(ROOT / 'twebproxy-manager.sh'),
                   'BRIDGE_SOURCE': str(ROOT / 'bridge'), 'FAULT_RC': str(fault),
                   'FAULT_EXIT': str(int(explicit_exit)),
                   'TWEBPROXY_NO_LOG': '1', 'TWEBPROXY_ERROR_SNAPSHOT': '1',
                   'TWEBPROXY_UI_LANGUAGE': language, 'PYTHONDONTWRITEBYTECODE': '1',
                   'PATH': str(bindir) + os.pathsep + os.environ['PATH']}
            args = ['bash', '-c', HARNESS, '_', *command.split()]
            result = subprocess.run(args, input=choices, text=True, capture_output=True,
                                    env=env, timeout=15)
            after = {p.name: (hashlib.sha256(p.read_bytes()).hexdigest(),
                              p.stat().st_mode, p.stat().st_mtime_ns, p.stat().st_ino)
                     for p in [state, credential]}
            self.assertEqual(before, after, 'existing node/cleanup/credential state changed')
            self.assertFalse((fixture / 'forbidden-call').exists(),
                             'unexpected provisioning, service or network command')
            calls = (fixture / 'calls').read_text().splitlines() if (fixture / 'calls').exists() else []
            return result, result.stdout + result.stderr, calls

    def test_duplicate_add_returns_to_menu_and_other_commands_work(self):
        p, output, calls = self.run_case()
        self.assertEqual(p.returncode, 0, output)
        self.assertEqual(calls, ['add', 'status', 'diagnose'])
        self.assertGreaterEqual(output.count('Добавить зарубежный узел'), 4)
        self.assertIn('Зарубежный узел уже существует', output)
        self.assertNotIn('Ошибка на строке', output)

    def test_pending_cleanup_add_returns_without_deleting_debt(self):
        p, output, calls = self.run_case(phase='cleanup_pending')
        self.assertEqual(p.returncode, 0, output)
        self.assertEqual(calls, ['add', 'status', 'diagnose'])
        self.assertIn('очистка ещё не завершена', output)

    def test_duplicate_and_pending_cli_keep_nonzero_code(self):
        for phase in ['active', 'cleanup_pending']:
            with self.subTest(phase=phase):
                p, output, calls = self.run_case(phase, 'foreign-node add')
                self.assertEqual(p.returncode, 1, output)
                self.assertEqual(calls, ['add'])
                self.assertIn('Зарубежный узел уже существует', output)

    def test_english_refusal_and_menu_remain_english(self):
        p, output, calls = self.run_case(language='en')
        self.assertEqual(p.returncode, 0, output)
        self.assertIn('one node already exists or cleanup is pending', output)
        self.assertIn('Foreign Nodes / Bridge', output)
        self.assertEqual(calls, ['add', 'status', 'diagnose'])

    def test_real_failure_visible_and_menu_survives(self):
        p, output, calls = self.run_case(fault=7, choices='9\n1\n\n0\n0\n')
        self.assertEqual(p.returncode, 0, output)
        self.assertIn('INJECTED_OPERATION_FAILURE', output)
        self.assertIn('код 7', output)
        self.assertEqual(calls, ['add'])

    def test_cli_preserves_operational_failure_code(self):
        p, output, calls = self.run_case(command='foreign-node add', fault=7)
        self.assertEqual(p.returncode, 7, output)
        self.assertIn('INJECTED_OPERATION_FAILURE', output)

    def test_explicit_launcher_exit_cannot_exit_manager(self):
        p, output, _ = self.run_case(fault=23, explicit_exit=True,
                                     choices='9\n1\n\n0\n0\n')
        self.assertEqual(p.returncode, 0, output)
        self.assertIn('код 23', output)

    def test_successful_cli_status_keeps_zero_code(self):
        p, output, calls = self.run_case(command='foreign-node status')
        self.assertEqual(p.returncode, 0, output)
        self.assertEqual(calls, ['status'])
        self.assertIn('FIXTURE_READ_ONLY_status', output)

    def test_returns_to_main_menu_after_refusal(self):
        p, output, _ = self.run_case(choices='9\n1\n\n0\n0\n')
        self.assertEqual(p.returncode, 0, output)
        self.assertGreaterEqual(output.count('Главное меню'), 2)

    def test_each_bridge_action_handles_failure(self):
        for choice in range(1, 6):
            with self.subTest(choice=choice):
                p, output, calls = self.run_case(fault=9, choices=f'9\n{choice}\n\n0\n0\n')
                self.assertEqual(p.returncode, 0, output)
                self.assertIn('код 9', output)
                self.assertEqual(len(calls), 1)

    def test_russian_labels(self):
        p, output, _ = self.run_case(choices='9\n0\n0\n')
        self.assertEqual(p.returncode, 0, output)
        self.assertIn('Зарубежные узлы / Мост', output)
        self.assertNotIn('Foreign Nodes', output)


class BridgeLanguage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import sys
        sys.path.insert(0, str(ROOT / 'bridge'))
        spec = importlib.util.spec_from_file_location('menu_controller_test', ROOT / 'bridge/controller.py')
        cls.controller = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.controller)

    def test_confirmation_is_explicit_in_both_languages(self):
        c = self.controller
        for value in ['yes', 'YES', ' да ', 'ДА']:
            self.assertTrue(c.confirmed(value), value)
        for value in ['', 'no', 'нет', 'y', 'д', 'maybe']:
            self.assertFalse(c.confirmed(value), value)

    def test_expected_refusals_are_localized_without_changing_json(self):
        c = self.controller
        with mock.patch.object(c, 'LANG', 'ru'):
            for text in ['another node operation is in progress', 'no managed foreign node',
                         'unsupported/corrupt state; activation blocked', 'invalid SSH port',
                         'Cancelled; inspect status if an operation had started.']:
                self.assertNotEqual(c.tr(text), text)
            raw = '{"state":"NO_NODE","checks":{"bridge.web.client":"UNKNOWN"}}'
            self.assertEqual(c.tr(raw), raw)
        with mock.patch.object(c, 'LANG', 'en'):
            self.assertEqual(c.tr('invalid SSH port'), 'invalid SSH port')


if __name__ == '__main__':
    unittest.main(verbosity=2)
