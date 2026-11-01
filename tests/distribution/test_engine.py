#!/usr/bin/env python3
"""Root-only filesystem/process fixtures. Health is doubled; real KVM is separate."""
import hashlib
import importlib.util
import io
import json
import multiprocessing
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('distribution_engine', ROOT/'updater/engine.py')
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)


@unittest.skipUnless(os.geteuid() == 0, 'root-only private filesystem fixture')
class Distribution(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory(prefix='twp-dist-package-')
        cls.source = Path(cls.shared.name)/'source';cls.source.mkdir()
        names = [*json.loads((ROOT/'COMPONENTS.json').read_text()), 'COMPONENTS.json', 'DISTRIBUTION.json', 'twebproxy-manager.sh']
        for name in names:
            target=cls.source/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/name,target)
        cls.package = Path(cls.shared.name)/'distribution.tar.gz'
        subprocess.run([sys.executable, str(ROOT/'tools/build-distribution.py'), '--root', str(cls.source), '--output', str(cls.package)], check=True, capture_output=True)
        cls.raw = cls.package.read_bytes()
        cls.pin = mod.sha(cls.raw)
        cls.components = json.loads((ROOT/'COMPONENTS.json').read_text())

    @classmethod
    def tearDownClass(cls):
        cls.shared.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='twp-dist-fixture-')
        self.root = Path(self.temp.name)
        self.paths = mod.Paths(self.root)
        self.paths.primary.parent.mkdir(parents=True)
        self.paths.project.mkdir(parents=True)
        self.paths.lock.parent.mkdir(parents=True)
        self.paths.global_env.parent.mkdir(parents=True)
        text = ('#!/bin/bash\nMANAGER_VERSION="0.2.25"\nMANAGER_RELEASE_VERSION="0.2.25-beta"\n'
                'BRIDGE_MANIFEST_SHA256="'+json.loads((ROOT/'DISTRIBUTION.json').read_text())['components_sha256']+'"\n')
        # A synthetic old manager; accepted v025 execution is tested in KVM.
        bridge_pin = mod.sha((ROOT/'bridge/MANIFEST.json').read_bytes())
        text = text.replace(json.loads((ROOT/'DISTRIBUTION.json').read_text())['components_sha256'], bridge_pin)
        self.old = text.encode()
        for p in [self.paths.primary, self.paths.secondary]:
            p.write_bytes(self.old);p.chmod(0o755)
        self.global_data = b'MANAGER_VERSION=0.2.25\nCUSTOM_FLAG=retain-this-line\n'
        self.paths.global_env.write_bytes(self.global_data);self.paths.global_env.chmod(0o600)
        self.site = self.paths.at('/srv/twebproxy/custom/index.html')
        self.site.parent.mkdir(parents=True);self.site.write_text('operator modified site')
        self.engine = mod.Engine(self.paths, health=lambda data: True)

    def tearDown(self):
        self.temp.cleanup()

    def unchanged(self):
        self.assertEqual(self.paths.primary.read_bytes(), self.old)
        self.assertEqual(self.paths.secondary.read_bytes(), self.old)
        self.assertEqual(self.paths.global_env.read_bytes(), self.global_data)
        self.assertEqual(self.site.read_text(), 'operator modified site')

    def install(self, engine=None):
        return (engine or self.engine).install(self.package, self.pin)

    def mutant(self, change):
        entries=[]
        with tarfile.open(self.package,'r:gz') as t:
            for m in t:
                entries.append((m.name, t.extractfile(m).read(), m.mode, m.type, m.linkname))
        entries=change(entries)
        target=self.root/'mutant.tar.gz'
        with tarfile.open(target,'w:gz',format=tarfile.USTAR_FORMAT) as t:
            for name,raw,mode,kind,link in entries:
                m=tarfile.TarInfo(name);m.mode=mode;m.type=kind;m.linkname=link;m.size=len(raw)
                t.addfile(m,io.BytesIO(raw) if m.isfile() else None)
        return target,mod.sha(target.read_bytes())

    def active(self, digest=None, phase='active'):
        self.paths.node.parent.mkdir(parents=True,exist_ok=True)
        node={'schema':1,'phase':phase,'executor_digest':digest or self.components['bridge/agent.py']['sha256']}
        self.paths.node.write_text(json.dumps(node));self.paths.node.chmod(0o600)
        import shutil
        pin=mod.sha((ROOT/'bridge/MANIFEST.json').read_bytes())
        shutil.copytree(ROOT/'bridge',self.paths.project/('bridge-'+pin),
                        ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
        return self.paths.node.read_bytes()

    def test_complete_install_publishes_all_components_and_preserves_data(self):
        ident=self.install()
        candidate=(ROOT/'twebproxy-manager.sh').read_bytes()
        self.assertEqual(self.paths.primary.read_bytes(),candidate)
        self.assertEqual(self.paths.secondary.read_bytes(),candidate)
        version=json.loads((ROOT/'DISTRIBUTION.json').read_text())['version'].encode()
        self.assertEqual(self.paths.global_env.read_bytes(),self.global_data.replace(b'0.2.25',version))
        pin=json.loads((ROOT/'DISTRIBUTION.json').read_text())['components_sha256']
        records=mod.verify_components(self.paths.project/'distributions'/pin,pin,True)
        self.assertIn('bridge/controller.py',records)
        self.assertEqual(self.site.read_text(),'operator modified site')
        self.engine.rollback(ident)
        self.unchanged()

    def test_wrong_outer_digest_refuses_without_mutation(self):
        with self.assertRaises(mod.Fault):self.engine.install(self.package,'0'*64)
        self.unchanged()

    def test_missing_bundle_member_refuses_before_mutation(self):
        target,pin=self.mutant(lambda es:[e for e in es if e[0]!='bridge/controller.py'])
        with self.assertRaises(mod.Fault):self.engine.install(target,pin)
        self.unchanged()

    def test_component_mismatch_refuses_before_mutation(self):
        target,pin=self.mutant(lambda es:[(n,raw+b'bad' if n=='bridge/agent.py' else raw,m,k,l) for n,raw,m,k,l in es])
        with self.assertRaises(mod.Fault):self.engine.install(target,pin)
        self.unchanged()

    def test_extra_member_is_not_installed(self):
        target,pin=self.mutant(lambda es:es+[('unmanifested.py',b'raise SystemExit(0)',0o644,tarfile.REGTYPE,'')])
        with self.assertRaises(mod.Fault):self.engine.install(target,pin)
        self.unchanged()

    def test_duplicate_tar_member_is_rejected(self):
        target,pin=self.mutant(lambda es:es+[es[0]])
        with self.assertRaises(mod.Fault):self.engine.install(target,pin)
        self.unchanged()

    def test_traversal_is_rejected(self):
        target,pin=self.mutant(lambda es:es+[('../outside',b'bad',0o644,tarfile.REGTYPE,'')])
        with self.assertRaises(mod.Fault):self.engine.install(target,pin)
        self.assertFalse((self.root.parent/'outside').exists());self.unchanged()

    def test_symlink_member_is_rejected(self):
        target,pin=self.mutant(lambda es:es+[('link',b'',0o644,tarfile.SYMTYPE,'/etc/shadow')])
        with self.assertRaises(mod.Fault):self.engine.install(target,pin)
        self.unchanged()

    def test_hardlink_member_is_rejected(self):
        target,pin=self.mutant(lambda es:es+[('link',b'',0o644,tarfile.LNKTYPE,'VERSION')])
        with self.assertRaises(mod.Fault):self.engine.install(target,pin)
        self.unchanged()

    def test_health_failure_exactly_restores_previous_installation(self):
        engine=mod.Engine(self.paths,health=lambda data:data==self.old)
        with self.assertRaises(mod.Fault):self.install(engine)
        self.unchanged();self.assertFalse((self.paths.state/'pending.json').exists())

    def test_exception_between_copies_restores_previous_installation(self):
        def fail(phase):
            if phase=='primary-replaced':raise OSError('explicit test failure')
        engine=mod.Engine(self.paths,health=lambda data:True,event=fail)
        with self.assertRaises(OSError):self.install(engine)
        self.unchanged();self.assertFalse((self.paths.state/'pending.json').exists())

    def test_sigkill_between_copies_has_durable_recovery(self):
        def child():
            def kill(phase):
                if phase=='primary-replaced':os.kill(os.getpid(),signal.SIGKILL)
            self.install(mod.Engine(self.paths,health=lambda data:True,event=kill))
        p=multiprocessing.Process(target=child);p.start();p.join(20)
        self.assertEqual(p.exitcode,-signal.SIGKILL)
        self.assertNotEqual(self.paths.primary.read_bytes(),self.paths.secondary.read_bytes())
        with self.engine.locked():self.assertTrue(self.engine.recover_locked())
        self.unchanged()

    def test_concurrent_update_refuses(self):
        with self.engine.locked():
            with self.assertRaises(mod.Fault) as e:self.install()
            self.assertEqual(e.exception.code,'busy')
        self.unchanged()

    def test_pending_bridge_refuses_before_publication(self):
        before=self.active(phase='cleanup_pending')
        with self.assertRaises(mod.Fault) as e:self.install()
        self.assertEqual(e.exception.code,'bridge');self.unchanged()
        self.assertEqual(self.paths.node.read_bytes(),before)
        self.assertFalse((self.paths.project/'distributions').exists())

    def test_active_compatible_bridge_update_and_rollback_preserve_state(self):
        before=self.active();ident=self.install()
        self.assertEqual(self.paths.node.read_bytes(),before)
        self.engine.rollback(ident);self.unchanged()
        self.assertEqual(self.paths.node.read_bytes(),before)

    def test_active_agent_change_refuses(self):
        before=self.active(digest='0'*64)
        with self.assertRaises(mod.Fault) as e:self.install()
        self.assertEqual(e.exception.code,'bridge');self.unchanged()
        self.assertEqual(self.paths.node.read_bytes(),before)

    def test_corrupted_backup_cannot_replace_working_manager(self):
        ident=self.install();current=self.paths.primary.read_bytes()
        (self.paths.backups/ident/'manager.sh').write_bytes(b'corrupt')
        with self.assertRaises(mod.Fault):self.engine.rollback(ident)
        self.assertEqual(self.paths.primary.read_bytes(),current)

    def test_manual_rollback_preserves_later_nonversion_global_settings(self):
        ident=self.install()
        with self.paths.global_env.open('ab') as f:f.write(b'OPERATOR_ADDED_AFTER_UPDATE=keep\n')
        self.engine.rollback(ident)
        self.assertEqual(self.paths.global_env.read_bytes(),self.global_data+b'OPERATOR_ADDED_AFTER_UPDATE=keep\n')

    def test_unsafe_target_symlink_is_not_followed(self):
        victim=self.root/'victim';victim.write_bytes(b'keep')
        self.paths.secondary.unlink();self.paths.secondary.symlink_to(victim)
        with self.assertRaises(mod.Fault):self.install()
        self.assertEqual(victim.read_bytes(),b'keep')

    def test_installed_component_corruption_is_detected(self):
        self.install()
        pin=json.loads((ROOT/'DISTRIBUTION.json').read_text())['components_sha256']
        store=self.paths.project/'distributions'/pin
        (store/'bridge/controller.py').write_bytes(b'corrupt')
        with self.assertRaises(mod.Fault):mod.verify_components(store,pin,True)

    def test_verified_reinstall_quarantines_owned_corrupt_unused_cache(self):
        ident=self.install()
        pin=json.loads((ROOT/'DISTRIBUTION.json').read_text())['components_sha256']
        store=self.paths.project/'distributions'/pin
        (store/'bridge/controller.py').write_bytes(b'corrupt')
        self.engine.rollback(ident)
        self.install()
        mod.verify_components(store,pin,True)
        quarantined=list(store.parent.glob('.rejected-*'))
        self.assertEqual(len(quarantined),1)
        self.assertEqual((quarantined[0]/'bridge/controller.py').read_bytes(),b'corrupt')

    def test_deterministic_build(self):
        output=self.root/'second.tar.gz'
        subprocess.run([sys.executable,str(ROOT/'tools/build-distribution.py'),'--root',str(self.source),'--output',str(output)],check=True,capture_output=True)
        self.assertEqual(output.read_bytes(),self.raw)

    def test_probe_allows_large_verified_dependency_files(self):
        target=self.root/'large-library'
        code='from pathlib import Path;Path('+repr(str(target))+').write_bytes(b"x"*(6*1024*1024));print("ready")'
        self.assertEqual(self.engine.probe([sys.executable,'-c',code]),b'ready\n')
        self.assertEqual(target.stat().st_size,6*1024*1024)

    def test_probe_descendant_cannot_hold_stdout_open(self):
        start=time.monotonic()
        self.assertEqual(self.engine.probe(['bash','-c','printf ready; sleep 30 &'],timeout=2),b'ready')
        self.assertLess(time.monotonic()-start,2)

    def test_probe_timeout_is_bounded(self):
        start=time.monotonic()
        self.assertIsNone(self.engine.probe(['bash','-c','trap "" TERM; sleep 30'],timeout=0.2))
        self.assertLess(time.monotonic()-start,3)

    def test_probe_stdout_limit_is_independent_of_disk_writes(self):
        self.assertIsNone(self.engine.probe([sys.executable,'-c','print("x"*5000000)']))


if __name__=='__main__':unittest.main(verbosity=2)
