import sys,json,time,copy,socket
from pathlib import Path
sys.dont_write_bytecode=True
root=Path('/root/twebproxy-gate2-dev/bridge');manifest=__import__('hashlib').sha256((root/'MANIFEST.json').read_bytes()).hexdigest();sys.path[:0]=[str(root),'/opt/twebproxy-manager/bridge-python/'+manifest+'-cp314']
import controller as c
s=c.load();results=[]
def test(name,fn):
 start=time.time()
 try:detail=fn();results.append({'test':name,'result':'PASS','at':start,'detail':detail})
 except Exception as e:results.append({'test':name,'result':'FAIL','at':start,'detail':str(e)})
def reject(req):
 t=c.managed(s)
 try:
  try:t.command('bridge',req)
  except c.Fault as e:return str(e)
  raise AssertionError('accepted forbidden request')
 finally:t.close()
base={'op':'status','config':s['exit'],'generation':1,'digest':s['executor_digest']}
for name,change in [('unknown-verb',{'op':'shell'}),('unknown-field',{'command':'id'}),('stale-generation',{'generation':0}),('digest-mismatch',{'digest':'0'*64}),('invalid-credential',{'op':'deploy','operation':'c'*32,'credential':'not-a-secret'}),('oversized',{'digest':'x'*270000}),('deep',{'digest':[[[[[[[[[[[[[[1]]]]]]]]]]]]]]})]:
 req=copy.deepcopy(base);req.update(change);test(name,lambda req=req:reject(req))
req=copy.deepcopy(base);req['config']['id']='f'*32;test('cross-node',lambda:reject(req))
def identity():
 try:c.SSH(s['ip'],s['port'],'SHA256:wrong')
 except c.Fault as e:
  assert 'no authentication attempted' in str(e);return str(e)
 raise AssertionError('identity mismatch accepted')
test('host-mismatch-before-authentication',identity)
def no_pty():
 t=c.managed(s)
 try:
  ch=t.t.open_session()
  try:ch.get_pty()
  except Exception:return 'PTY denied'
  raise AssertionError('PTY permitted')
 finally:t.close()
test('managed-pty-denied',no_pty)
def no_forward():
 t=c.managed(s)
 try:
  try:t.t.open_channel('direct-tcpip',('127.0.0.1',22),('127.0.0.1',12345))
  except Exception:return 'direct-tcpip denied'
  raise AssertionError('forwarding permitted')
 finally:t.close()
test('managed-forwarding-denied',no_forward)
def forced():
 t=c.managed(s)
 try:r=t.command('id; touch /tmp/twb-command-injection',base);assert r['id']==s['id'];return 'original shell command ignored; typed status returned'
 finally:t.close()
test('forced-command-no-shell',forced)
def replay():
 op=s['exit_operation'];before=c.rpc(s,'opstatus',operation=op);after=c.rpc(s,'deploy',operation=op);assert before==after;return {'phase':after['phase'],'receipt_unchanged':True}
test('completed-operation-replay',replay)
print(json.dumps({'results':results,'all_pass':all(x['result']=='PASS' for x in results)},indent=2))
