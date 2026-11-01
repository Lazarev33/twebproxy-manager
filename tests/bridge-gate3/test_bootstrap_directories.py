#!/usr/bin/env python3
"""Execute actual staged bootstrap in private chroot; no network/systemd doubles PASS.

SFTP/SSH transport and the agent body are scoped fixture doubles. The production
bootstrap byte verification and directory preparation execute unchanged with
umask077, real filesystem permissions and a real nobody UID read attempt.
Full provisioning/DynamicUser acceptance runs separately in clean KVM.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
AGENT = b'''import json,os
from pathlib import Path
os.umask(0o077)
lib=Path('/usr/local/libexec/twebproxy-bridge/owned')
lib.mkdir(parents=True,exist_ok=True,mode=0o755)
lib.chmod(0o755)
p=lib/'run-mt.py';p.write_text('public launcher');p.chmod(0o755)
private=Path('/var/lib/bridge-private');private.mkdir(parents=True,mode=0o700)
secret=private/'credential';secret.write_text('synthetic private witness')
readfd,writefd=os.pipe();pid=os.fork()
if pid==0:
 os.close(readfd);os.setgroups([]);os.setgid(65534);os.setuid(65534)
 try:p.read_text();result=b'yes'
 except OSError:result=b'no'
 os.write(writefd,result);os._exit(0)
os.close(writefd);readable=os.read(readfd,8)==b'yes';os.close(readfd);os.waitpid(pid,0)
print(json.dumps({'ok':True,'result':{'public_parent_mode':oct(Path('/usr/local/libexec').stat().st_mode&0o777),'public_readable_by_nobody':readable,'private_mode':oct(secret.stat().st_mode&0o777)}}))
'''
DRIVER = '''import os,sys,stat,hashlib,pwd,json,pathlib
code=sys.stdin.read();os.chroot(sys.argv[1]);os.chdir('/');os.umask(0o077)
exec(compile(code,'<actual-bootstrap>','exec'),{'__name__':'__main__'})
'''


@unittest.skipUnless(os.geteuid() == 0, 'root-only chroot permission fixture')
class BootstrapDirectories(unittest.TestCase):
    def run_case(self, setup=None, tamper=False):
        with tempfile.TemporaryDirectory(prefix='twp-bootstrap-dir-') as temp:
            base = Path(temp); fs = base/'fs'; fs.mkdir(mode=0o755)
            for name in ['usr', 'usr/local', 'etc', 'root', 'root/bootstrap']:
                (fs/name).mkdir(mode=0o755, parents=True, exist_ok=True)
            (fs/'etc/passwd').write_text('root:x:0:0:root:/root:/bin/sh\n')
            bundle = base/'bundle'; bundle.mkdir(); (bundle/'agent.py').write_bytes(AGENT)
            if setup: setup(fs)
            observation = {}

            class SFTP:
                def normalize(self, _): return '/root/bootstrap'
                def local(self, path): return fs/path.lstrip('/')
                def mkdir(self, path, mode): self.local(path).mkdir(mode=mode)
                def file(self, path, mode): return self.local(path).open(mode)
                def chmod(self, path, mode): self.local(path).chmod(mode)
                def remove(self, path): self.local(path).unlink()
                def rmdir(self, path): self.local(path).rmdir()
                def close(self): pass

            class SSH:
                t = object()
                def command(self, command, request, timeout):
                    args = shlex.split(command); code = args[args.index('-c')+1]
                    if tamper:
                        for f in (fs/'root/bootstrap').glob('*/agent.py'): f.write_bytes(b'raise RuntimeError("tampered")')
                    p = subprocess.run([sys.executable, '-c', DRIVER, str(fs)], input=code,
                                       text=True, capture_output=True, timeout=15)
                    observation.update(return_code=p.returncode, stdout=p.stdout, stderr=p.stderr,
                                       libexec_exists=(fs/'usr/local/libexec').exists())
                    if p.returncode: return {'failure': True}
                    return json.loads(p.stdout)['result']

            paramiko = types.ModuleType('paramiko')
            paramiko.SFTPClient = types.SimpleNamespace(from_transport=lambda _: SFTP())
            spec = importlib.util.spec_from_file_location('bootstrap_controller_fixture', ROOT/'bridge/controller.py')
            c = importlib.util.module_from_spec(spec)
            with mock.patch.dict(sys.modules, {'paramiko': paramiko}):
                with mock.patch.object(sys, 'path', [str(ROOT/'bridge'), *sys.path]):
                    spec.loader.exec_module(c)
                c.HERE = bundle
                result = c.stage_bootstrap(SSH(), {'id': 'a'*32}, 'public fixture', 'root')
            observation['result'] = result
            prefix = fs/'usr/local/libexec'
            if prefix.exists() and not prefix.is_symlink():
                observation['prefix_mode'] = prefix.stat().st_mode&0o777
            observation['private_witness_exists'] = (fs/'var/lib/bridge-private/credential').exists()
            observation['operator_target_exists'] = (fs/'operator-target/canary').exists()
            if setup:
                marker = fs/'usr/local/libexec/unrelated'
                if marker.exists(): observation['unrelated'] = (marker.read_bytes(), marker.stat().st_mode&0o777)
            return observation

    def test_missing_libexec_with_private_umask_supports_dynamic_user(self):
        r = self.run_case()
        self.assertEqual(r['return_code'], 0, r)
        self.assertEqual(r['result']['public_parent_mode'], '0o755')
        self.assertTrue(r['result']['public_readable_by_nobody'])
        self.assertEqual(r['result']['private_mode'], '0o600')

    def test_existing_public_parent_and_unrelated_file_are_preserved(self):
        def setup(fs):
            p=fs/'usr/local/libexec';p.mkdir(mode=0o755)
            f=p/'unrelated';f.write_bytes(b'operator canary');f.chmod(0o600)
        r=self.run_case(setup)
        self.assertEqual(r['return_code'],0,r)
        self.assertEqual(r['unrelated'],(b'operator canary',0o600))

    def test_tampered_payload_cannot_create_public_prefix(self):
        r=self.run_case(tamper=True)
        self.assertNotEqual(r['return_code'],0)
        self.assertFalse(r['libexec_exists'])

    def test_existing_traversable_nondefault_mode_is_preserved(self):
        r=self.run_case(lambda fs:(fs/'usr/local/libexec').mkdir(mode=0o711))
        self.assertEqual(r['return_code'],0,r)
        self.assertEqual(r['prefix_mode'],0o711)
        self.assertTrue(r['result']['public_readable_by_nobody'])

    def test_existing_private_parent_is_refused_without_chmod(self):
        r=self.run_case(lambda fs:(fs/'usr/local/libexec').mkdir(mode=0o700))
        self.assertNotEqual(r['return_code'],0)
        self.assertEqual(r['prefix_mode'],0o700)
        self.assertFalse(r['private_witness_exists'])
        self.assertIn('inspect /usr',json.loads(r['stdout'])['error'])

    def test_writable_parent_is_refused_without_chmod(self):
        def setup(fs):
            p=fs/'usr/local/libexec';p.mkdir();p.chmod(0o777)
        r=self.run_case(setup)
        self.assertNotEqual(r['return_code'],0)
        self.assertEqual(r['prefix_mode'],0o777)
        self.assertFalse(r['private_witness_exists'])

    def test_symlink_parent_is_refused_without_touching_target(self):
        def setup(fs):
            target=fs/'operator-target';target.mkdir();(target/'canary').write_text('keep')
            (fs/'usr/local/libexec').symlink_to('/operator-target',target_is_directory=True)
        r=self.run_case(setup)
        self.assertNotEqual(r['return_code'],0)
        self.assertTrue(r['operator_target_exists'])
        self.assertFalse(r['private_witness_exists'])

    def test_nonroot_owned_parent_is_refused(self):
        def setup(fs):
            p=fs/'usr/local/libexec';p.mkdir(mode=0o755);os.chown(p,65534,65534)
        r=self.run_case(setup)
        self.assertNotEqual(r['return_code'],0)
        self.assertFalse(r['private_witness_exists'])


if __name__ == '__main__': unittest.main(verbosity=2)
