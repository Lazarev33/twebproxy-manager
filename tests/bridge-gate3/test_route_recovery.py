"""MODEL controls for the narrow route convergence fix; real link test separate."""
import sys,json,subprocess,base64,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'bridge'))
import agent
class Route(unittest.TestCase):
 def config(self):return {'schema':1,'id':'a'*32,'role':'entry','endpoint':'198.51.100.1','peer_endpoint':'198.51.100.2','own_ip':'10.204.1.1','peer_ip':'10.204.1.2','wg_port':51990,'client_port':24990,'stats_port':29990,'local_port':24000,'backend_id':'test.invalid--default','public_key':base64.b64encode(bytes(32)).decode(),'peer_key':'','generation':1}
 def scenario(self,guard=True,up=True,key=True,routes=None):
  c=self.config();calls=[];original=agent.run
  def run(a,check=True,**kw):
   calls.append(a)
   if a[:4]==['ip','-j','route','show']:return subprocess.CompletedProcess(a,0,json.dumps(routes if routes is not None else [{'type':'blackhole','metric':32760}]),'')
   if a[0]=='nft':return subprocess.CompletedProcess(a,0 if guard else 1,'','')
   if a[:3]==['ip','-j','link']:return subprocess.CompletedProcess(a,0,json.dumps([{'flags':['UP'] if up else []}]),'')
   if a[0]=='wg':return subprocess.CompletedProcess(a,0,c['public_key'] if key else 'other','')
   if a[:3]==['ip','route','replace']:return subprocess.CompletedProcess(a,0,'','')
   raise AssertionError(a)
  agent.run=run
  try:r=agent.restore_owned_peer_route(c)
  finally:agent.run=original
  return r,[a for a in calls if a[:3]==['ip','route','replace']]
 def test_owned_blackhole_up_verified_peer_recovers(self):
  r,calls=self.scenario();self.assertTrue(r);self.assertEqual(calls,[['ip','route','replace','10.204.1.2/32','dev','twbaaaaaaaa','metric','100']])
 def test_no_guard_no_route_mutation(self):self.assertEqual(self.scenario(guard=False),(False,[]))
 def test_admin_down_respected(self):self.assertEqual(self.scenario(up=False),(False,[]))
 def test_wrong_interface_identity_not_adopted(self):self.assertEqual(self.scenario(key=False),(False,[]))
 def test_operator_competing_route_not_overwritten(self):self.assertEqual(self.scenario(routes=[{'dev':'other','metric':100}]),(False,[]))
 def test_unknown_missing_fallback_not_adopted(self):self.assertEqual(self.scenario(routes=[]),(False,[]))
if __name__=='__main__':unittest.main(verbosity=2)
