"""Executable confirmation/ERR regressions. No host services or network access.

Paramiko is a scoped inert import double; no SSH method is exercised here.
The production verified dependency launcher is not modified or bypassed by code.
"""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(os.environ.get('TWEBPROXY_TEST_SOURCE_ROOT', Path(__file__).resolve().parents[2]))
ENV = {**os.environ, 'TWEBPROXY_NO_LOG': '1', 'TWEBPROXY_ERROR_SNAPSHOT': '1',
       'PYTHONDONTWRITEBYTECODE': '1', 'NO_COLOR': '1'}
YES = ['y', 'Y', 'yes', 'YES', 'Yes', 'д', 'Д', 'да', 'ДА', 'Да']
NO = ['n', 'N', 'no', 'NO', 'нет', 'НЕТ', 'maybe', '']


def shell(code, data='', lang='ru', args=()):
    return subprocess.run(['bash', '-c', 'source "$1"; shift; disable_colors; ' + code,
                           '_', str(ROOT / 'twebproxy-manager.sh'), *args],
                          input=data, text=True, capture_output=True,
                          env={**ENV, 'TWEBPROXY_UI_LANGUAGE': lang}, timeout=15)


class Confirmations(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, str(ROOT / 'bridge'))
        spec = importlib.util.spec_from_file_location('correction_controller', ROOT / 'bridge/controller.py')
        cls.c = importlib.util.module_from_spec(spec)
        with mock.patch.dict(sys.modules, {'paramiko': mock.Mock(name='inert_paramiko')}):
            spec.loader.exec_module(cls.c)

    def test_restore_affirmatives_ru_en(self):
        for lang in ['ru', 'en']:
            for answer in YES:
                with self.subTest(lang=lang, answer=answer):
                    p = shell('rc=0; stage4_confirm_restore test || rc=$?; printf "RC=%s" "$rc"', answer + '\n', lang)
                    self.assertEqual(p.returncode, 0, p.stderr)
                    self.assertIn('RC=0', p.stdout)
                    self.assertNotIn('ROLLBACK_NOT_PERFORMED', p.stdout)

    def test_restore_negative_and_empty_still_decline(self):
        for lang in ['ru', 'en']:
            for answer in NO:
                p = shell('rc=0; stage4_confirm_restore test || rc=$?; printf "RC=%s" "$rc"', answer + '\n', lang)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertIn('RC=1', p.stdout)
                self.assertIn('ROLLBACK_NOT_PERFORMED reason=declined', p.stdout)

    def test_restore_eof_and_incomplete_keep_130(self):
        for data in ['', 'y', 'yes', 'да']:
            p = shell('rc=0; stage4_confirm_restore test || rc=$?; printf "RC=%s" "$rc"', data)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn('RC=130', p.stdout)
            self.assertIn('ROLLBACK_NOT_PERFORMED reason=eof', p.stdout)

    def test_yesno_affirmatives_and_prompt_defaults(self):
        for lang in ['ru', 'en']:
            for answer in YES:
                p = shell('if yesno test n; then printf ACCEPT; else printf REFUSE; fi', answer + '\n', lang)
                self.assertEqual(p.stdout, 'ACCEPT', p.stderr)
            for default, data, expected in [('n', '\n', 'REFUSE'), ('y', '\n', 'ACCEPT'),
                                            ('y', '', 'REFUSE'), ('n', 'yes', 'REFUSE')]:
                p = shell(f'if yesno test {default}; then printf ACCEPT; else printf REFUSE; fi', data, lang)
                self.assertEqual(p.stdout, expected, p.stderr)

    def test_python_affirmative_tokens(self):
        for s in YES:
            self.assertTrue(self.c.confirmed(s), s)
        for s in NO:
            self.assertFalse(self.c.confirmed(s), s)

    def test_python_confirmation_refuses_eof_and_incomplete(self):
        for lang in ['ru', 'en']:
            for answer in YES + NO:
                with mock.patch.object(self.c, 'LANG', lang), mock.patch('sys.stdin', io.StringIO(answer+'\n')), mock.patch('sys.stdout', io.StringIO()):
                    self.assertEqual(self.c.confirm_prompt('Approve installation? [yes/NO]: '), answer in YES)
            for data in ['', 'y', 'yes', 'да']:
                with mock.patch('sys.stdin', io.StringIO(data)), mock.patch('sys.stdout', io.StringIO()):
                    with self.assertRaises(EOFError):
                        self.c.confirm_prompt('Approve installation? [yes/NO]: ')


class ErrorTrap(unittest.TestCase):
    def cli(self, rc, args=('foreign-node', 'add'), body=None, snapshot=False):
        with tempfile.TemporaryDirectory() as d:
            setup = 'need_root(){ :; }; '
            if snapshot:
                setup += ('unset TWEBPROXY_ERROR_SNAPSHOT; LOG_RUNTIME_DIR="$1"; shift; '
                          'collect_runtime_snapshot(){ printf FIXTURE_SNAPSHOT; return 29; }; ')
            body = body or f'printf FAILURE_FIXTURE >&2; bash -c "exit {rc}"; printf UNREACHABLE'
            return shell(setup + 'bridge_launcher(){ '+body+'; }; main "$@"; printf UNREACHABLE',
                         args=((d,)+args if snapshot else args), lang='en')

    def test_cli_failures_preserve_status_and_strictness_without_context_corruption(self):
        for rc in [1, 7, 23, 130]:
            p = self.cli(rc)
            self.assertEqual(p.returncode, rc, p.stdout + p.stderr)
            self.assertIn('FAILURE_FIXTURE', p.stderr)
            self.assertNotIn('UNREACHABLE', p.stdout)
            self.assertNotIn('pop_var_context', p.stderr)

    def test_json_raw_stdout_stays_machine_readable(self):
        for option in ['--json', '--raw']:
            payload = '{"fixture":true}' if option == '--json' else 'fixture\tok'
            p = self.cli(7, args=('foreign-node', 'status', option),
                         body="printf '%s\\n' '"+payload+"'; return 7")
            self.assertEqual(p.returncode, 7, p.stderr)
            self.assertEqual(p.stdout, payload+'\n')
            self.assertNotIn('pop_var_context', p.stderr)
            if option == '--json':
                self.assertEqual(json.loads(p.stdout), {'fixture': True})

    def test_snapshot_failure_cannot_replace_original_status(self):
        p = self.cli(17, snapshot=True)
        self.assertEqual(p.returncode, 17, p.stderr)
        self.assertNotIn('UNREACHABLE', p.stdout)
        self.assertNotIn('pop_var_context', p.stderr)

    def test_successful_cli_keeps_zero(self):
        p = shell('bridge_launcher(){ printf OK; }; main foreign-node status')
        self.assertEqual((p.returncode, p.stdout, p.stderr), (0, 'OK', ''))


if __name__ == '__main__':
    unittest.main(verbosity=2)
