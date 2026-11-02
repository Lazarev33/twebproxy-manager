"""Execute production CLI/credential guard functions with isolated OS doubles.

The real Foreign updater RED (active swap -> help refusal -> exact rollback)
is collected separately. These tests never change the host's swap or privileges.
"""
import argparse
import ast
import contextlib
import io
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch


class GuardFault(Exception):
    pass


class HelpSwap(unittest.TestCase):
    def functions(self, active=True):
        source = Path(os.environ.get('TWP_CONTROLLER_SOURCE',
                      str(Path(__file__).resolve().parents[2] / 'bridge/controller.py')))
        tree = ast.parse(source.read_text())
        selected = [n for n in tree.body if isinstance(n, ast.FunctionDef)
                    and n.name in ('main', 'secret_process')]
        self.assertEqual(len(selected), 2)
        resource, ctypes, process_os = Mock(), Mock(), Mock()
        swap = Mock()
        swap.read_text.return_value = 'Filename Type Size Used Priority\n' + (
            '/swapfile file 524284 100000 -2\n' if active else '')
        ns = {'argparse': argparse, 'resource': resource, 'ctypes': ctypes,
              'os': process_os, 'Path': Mock(return_value=swap), 'Fault': GuardFault}
        exec(compile(ast.Module(body=selected, type_ignores=[]), str(source), 'exec'), ns)
        return ns

    def test_help_does_not_enter_credential_handling_with_active_swap(self):
        ns = self.functions()
        with patch.object(sys, 'argv', ['foreign-node', '--help']):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                with self.assertRaises(SystemExit) as done:
                    ns['main']()
        self.assertEqual(done.exception.code, 0)
        self.assertIn('diagnose', output.getvalue())
        ns['Path'].assert_not_called()
        ns['os'].geteuid.assert_not_called()
        ns['resource'].setrlimit.assert_not_called()

    def test_every_operation_still_refuses_active_swap_before_sensitive_work(self):
        for verb in ['add', 'status', 'diagnose', 'repair', 'remove']:
            with self.subTest(verb=verb):
                ns = self.functions()
                with patch.object(sys, 'argv', ['foreign-node', verb]):
                    with self.assertRaisesRegex(GuardFault, 'no active swap'):
                        ns['main']()
                ns['Path'].assert_called_once_with('/proc/swaps')
                ns['os'].geteuid.assert_not_called()
                ns['resource'].setrlimit.assert_called_once()
                ns['ctypes'].CDLL.return_value.prctl.assert_called_once_with(4, 0, 0, 0, 0)
                ns['os'].umask.assert_called_once_with(0o077)

    def test_no_swap_guard_keeps_core_dump_and_umask_protection(self):
        ns = self.functions(active=False)
        ns['secret_process']()
        ns['resource'].setrlimit.assert_called_once()
        ns['ctypes'].CDLL.return_value.prctl.assert_called_once_with(4, 0, 0, 0, 0)
        ns['os'].umask.assert_called_once_with(0o077)


if __name__ == '__main__':
    unittest.main(verbosity=2)
