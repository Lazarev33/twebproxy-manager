"""Focused filesystem integration tests. Actual Manager functions, no service models."""
import json,os,subprocess,tempfile,unittest,shutil,hashlib,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class DefaultSite(unittest.TestCase):
 def shell(self,code,*args):
  return subprocess.run(['bash','-c','source "$1"; trap - ERR; '+code,'_',str(ROOT/'twebproxy-manager.sh'),*map(str,args)],env={**os.environ,'TWEBPROXY_NO_LOG':'1','TWEBPROXY_ERROR_SNAPSHOT':'1'},text=True,capture_output=True)
 def test_packaged_default_complete_and_permissions(self):
  with tempfile.TemporaryDirectory() as d:
   target=Path(d)/'site';p=self.shell('default_site_action deploy "$2"',target);self.assertEqual(p.returncode,0,p.stderr)
   self.assertIn('Культурные маршруты',(target/'index.html').read_text());self.assertTrue((target/'assets/posad.svg').exists());self.assertEqual((target/'index.html').stat().st_mode&0o777,0o644);self.assertEqual(target.stat().st_mode&0o777,0o755)
 def test_default_redeployment_preserves_modified_and_added_files(self):
  with tempfile.TemporaryDirectory() as d:
   target=Path(d)/'site';self.assertEqual(self.shell('default_site_action deploy "$2"',target).returncode,0)
   (target/'index.html').write_text('operator-owned edits');(target/'custom.txt').write_text('keep');(target/'styles.css').unlink()
   p=self.shell('default_site_action deploy "$2"',target);self.assertEqual(p.returncode,0,p.stderr);self.assertEqual((target/'index.html').read_text(),'operator-owned edits');self.assertEqual((target/'custom.txt').read_text(),'keep');self.assertFalse((target/'styles.css').exists())
 def test_cache_tamper_rejected_without_overwrite(self):
  with tempfile.TemporaryDirectory() as d:
   cache=Path(d)/'cache';self.assertEqual(self.shell('default_site_action install "$2"',cache).returncode,0);(cache/'index.html').write_text('modified cached distribution')
   p=self.shell('default_site_action install "$2"',cache);self.assertNotEqual(p.returncode,0);self.assertEqual((cache/'index.html').read_text(),'modified cached distribution')
 def test_tampered_source_fails_before_target_creation(self):
  with tempfile.TemporaryDirectory() as d:
   src=Path(d)/'bundle';shutil.copytree(ROOT/'sites/podmoskovye',src);(src/'styles.css').write_text('tampered');target=Path(d)/'site'
   p=self.shell('TEST_BUNDLE="$3"; default_site_bundle_dir(){ printf "%s" "$TEST_BUNDLE"; }; default_site_action deploy "$2"',target,src);self.assertNotEqual(p.returncode,0);self.assertFalse(target.exists())
 def test_unknown_file_symlink_and_wrong_manifest_refused(self):
  for mode in ['unknown','symlink','manifest']:
   with tempfile.TemporaryDirectory() as d:
    src=Path(d)/'bundle';shutil.copytree(ROOT/'sites/podmoskovye',src);target=Path(d)/'target'
    if mode=='unknown':(src/'extra.js').write_text('extra')
    elif mode=='symlink':(src/'linked').symlink_to('/etc/passwd')
    else:(src/'MANIFEST.json').write_text('{}')
    p=self.shell('TEST_BUNDLE="$3"; default_site_bundle_dir(){ printf "%s" "$TEST_BUNDLE"; }; default_site_action deploy "$2"',target,src);self.assertNotEqual(p.returncode,0);self.assertFalse(target.exists())
 def test_custom_directory_repair_preserves_edits_and_missing_source(self):
  with tempfile.TemporaryDirectory() as d:
   sites=Path(d)/'sites';(sites/'test.invalid').mkdir(parents=True);p=sites/'test.invalid/index.html';p.write_text('edited custom site')
   r=self.shell('SITES_DIR="$2"; SITE_MODE=directory; SOURCE_SITE_DIR=/missing; prepare_site_for_instance test.invalid',sites);self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(p.read_text(),'edited custom site')
 def test_upstream_option_creates_no_static_files(self):
  with tempfile.TemporaryDirectory() as d:
   p=self.shell('SITES_DIR="$2"; SITE_MODE=upstream; SITE_UPSTREAM=http://127.0.0.1:3000; prepare_site_for_instance test.invalid',d);self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(list(Path(d).iterdir()),[])
if __name__=='__main__':unittest.main(verbosity=2)
