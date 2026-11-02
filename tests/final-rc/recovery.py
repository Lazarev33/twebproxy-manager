#!/usr/bin/env python3
"""Real KVM tunnel/backend failure and external-to-tunnel backend isolation.
Requires provisioned marked disposable pair. No host firewall/routing mutations.
Positive SSH controls distinguish blocked ports from a broken probe network.
"""
import json,subprocess,threading,time,socket
from pathlib import Path
P=Path('/root/twp-finalrc-private');E=Path('/root/projects/twebproxy/final-rc-evidence')
events=[];samples=[];stop=threading.Event()
def ssh(role,code):
 a=['ssh','-i',str(P/'control_ed25519'),'-o','IdentitiesOnly=yes','-o','IdentityAgent=none','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(P/(role+'-known_hosts')),'-p',str(22240 if role=='entry' else 22241),'root@127.0.0.1','python3 -']
 r=subprocess.run(a,input=code,text=True,capture_output=True,timeout=30)
 if r.returncode:raise RuntimeError('SSH measurement failed '+str(r.returncode)+': '+r.stderr[-300:])
 return json.loads(r.stdout) if r.stdout.strip() else None
for role in ['entry','exit']:
 ssh(role,"from pathlib import Path\nassert Path('/etc/twebproxy-disposable-lab').read_bytes()==Path('/etc/machine-id').read_bytes()\n")
s=ssh('entry',"import json\nfrom pathlib import Path\ns=json.loads(Path('/etc/twebproxy/bridge/node.json').read_text());print(json.dumps({'prefix':'twb-'+s['id'][:12],'device':'twb'+s['id'][:8]}))")
def monitor():
 code="""import json,socket,time
r={'at_ns':time.time_ns()}
for name,port in [('SSH_control',22),('backend',24990),('stats',29990)]:
 try:
  with socket.create_connection(('192.0.2.21',port),timeout=.25):r[name]=True
 except OSError:r[name]=False
print(json.dumps(r))
"""
 while not stop.is_set():
  try:samples.append(ssh('entry',code))
  except Exception as e:samples.append({'at_ns':time.time_ns(),'SSH_control':False,'backend':False,'stats':False,'measurement_error':type(e).__name__})
  stop.wait(.15)
def observation(stage):
 code="import subprocess,json,time\nr={'stage':"+repr(stage)+",'at_ns':time.time_ns()}\n"
 code+="for suffix in ['socket','service']:\n r[suffix]=subprocess.run(['systemctl','is-active',"+repr(s['prefix']+'-forward.')+"+suffix],capture_output=True,text=True).stdout.strip()\nprint(json.dumps(r))"
 r=ssh('entry',code);events.append(r);return r
thread=threading.Thread(target=monitor,daemon=True);thread.start();down=False;recovered=False
try:
 observation('before')
 ssh('entry',"import subprocess\nsubprocess.run(['ip','link','set',"+repr(s['device'])+",'down'],check=True)")
 try:
  for _ in range(25):
   r=observation('tunnel-down')
   if r['socket']=='inactive' and r['service']=='inactive':down=True;break
   time.sleep(2)
 finally:ssh('entry',"import subprocess\nsubprocess.run(['ip','link','set',"+repr(s['device'])+",'up'],check=True)")
 for _ in range(25):
  r=observation('tunnel-restored')
  if r['socket']=='active':recovered=True;break
  time.sleep(2)
 assert down and recovered,'forwarder fail-closed/recovery not observed'
 before=ssh('exit',"import subprocess,json\nprint(json.dumps(dict(line.split('=',1) for line in subprocess.check_output(['systemctl','show',"+repr(s['prefix']+'-mt.service')+",'-p','MainPID','-p','NRestarts'],text=True).splitlines())))")
 kill_result=ssh('exit',"import subprocess,json\nr=subprocess.run(['systemctl','kill','--kill-whom=all','--signal=KILL',"+repr(s['prefix']+'-mt.service')+"],capture_output=True,text=True);print(json.dumps({'return_code':r.returncode,'stderr':r.stderr}))")
 events.append({'stage':'backend-SIGKILL-command','at_ns':time.time_ns(),**kill_result})
 after=None
 for _ in range(15):
  time.sleep(1)
  after=ssh('exit',"import subprocess,json\nr=dict(line.split('=',1) for line in subprocess.check_output(['systemctl','show',"+repr(s['prefix']+'-mt.service')+",'-p','MainPID','-p','NRestarts','-p','ActiveState'],text=True).splitlines());print(json.dumps(r))")
  if after['ActiveState']=='active' and after['MainPID']!='0' and after['MainPID']!=before['MainPID']:break
 assert after['ActiveState']=='active' and int(after['NRestarts'])>int(before['NRestarts']),'backend automatic restart failed'
 events.append({'stage':'backend-SIGKILL-recovery','at_ns':time.time_ns(),'before':before,'after':after})
 time.sleep(2)
finally:
 stop.set();thread.join(2)
 (E/'recovery-external-probes.json').write_text(json.dumps({'kind':'REAL_KVM_NETWORK; Entry192.0.2.20 to Exit192.0.2.21 outside WG, not public Internet','observations':events,'probes':samples},indent=2)+'\n')
assert samples and all(x['SSH_control'] for x in samples),'invalid external peer control'
assert not any(x['backend'] or x['stats'] for x in samples),'externally reachable backend'
print(json.dumps({'status':'PASS','kind':'REAL_KVM','samples':len(samples),'backend_reachable':0,'stats_reachable':0,'positive_control_success':len(samples),'watcher_stop':down,'automatic_tunnel_recovery':recovered,'automatic_backend_recovery':True}))
