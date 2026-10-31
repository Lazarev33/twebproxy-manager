"""Model/unit negative controls only; real host results are collected separately."""
import importlib.util,json,sys,tempfile,unittest,base64,hashlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'bridge'))
import agent,launcher
class Safety(unittest.TestCase):
 def config(self):return {'schema':1,'id':'a'*32,'role':'exit','endpoint':'192.0.2.1','peer_endpoint':'192.0.2.2','own_ip':'10.203.78.2','peer_ip':'10.203.78.1','wg_port':51990,'client_port':24990,'stats_port':29990,'local_port':24000,'backend_id':'test.invalid--default','public_key':'','peer_key':'','generation':1}
 def test_unknown_and_injection_fields(self):
  for key,value in [('id','../escape'),('backend_id','a;touch /tmp/injected'),('role','root'),('peer_ip','0.0.0.0'),('local_port',22),('local_port',True),('peer_key','$(id)')]:
   c=self.config();c[key]=value
   with self.assertRaises(Exception):agent.validate(c)
  c=self.config();c['command']='id'
  with self.assertRaises(agent.Fault):agent.validate(c)
 def test_valid_no_secret_registry(self):
  c=self.config();agent.validate(c)
  self.assertFalse({'private_key','secret','password'}&set(c))
  for k in ['private_key','secret','password']:
   c=self.config();c[k]='seed-secret'
   with self.assertRaises(agent.Fault):agent.validate(c)
 def test_atomic_and_symlink_refusal(self):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'state';agent.atomic(p,'one');self.assertEqual(p.stat().st_mode&0o777,0o600);agent.atomic(p,'two');self.assertEqual(p.read_text(),'two')
   p.unlink();p.symlink_to(Path(d)/'target')
   with self.assertRaises(agent.Fault):agent.atomic(p,'bad')
 def test_private_lock_refuses_symlink(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);victim=root/'victim';victim.write_text('canary');(root/'agent.lock').symlink_to(victim)
   with self.assertRaises(agent.Fault):agent.private_lock('agent.lock',root)
   self.assertEqual(victim.read_text(),'canary')
 def test_unmanifested_component_rejected(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);(root/'a.py').write_text('pass');raw=json.dumps({'a.py':hashlib.sha256(b'pass').hexdigest()}).encode();(root/'MANIFEST.json').write_bytes(raw);(root/'agent.pyc').write_bytes(b'untrusted')
   with self.assertRaises(RuntimeError):launcher.verify(root,hashlib.sha256(raw).hexdigest())
 def test_generation_bool_rejected(self):
  c=self.config();c['generation']=True
  with self.assertRaises(agent.Fault):agent.validate(c)
 def test_bundle_digest_tamper(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);(root/'a.py').write_text('pass');manifest={'a.py':hashlib.sha256(b'pass').hexdigest()};raw=json.dumps(manifest).encode();(root/'MANIFEST.json').write_bytes(raw);digest=hashlib.sha256(raw).hexdigest();launcher.verify(root,digest)
   (root/'a.py').write_text('raise RuntimeError()')
   with self.assertRaises(RuntimeError):launcher.verify(root,digest)
 def test_manifest_traversal_even_if_hash_approved(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);raw=json.dumps({'../bad':'a'*64}).encode();(root/'MANIFEST.json').write_bytes(raw)
   with self.assertRaises(RuntimeError):launcher.verify(root,hashlib.sha256(raw).hexdigest())
if __name__=='__main__':unittest.main(verbosity=2)
