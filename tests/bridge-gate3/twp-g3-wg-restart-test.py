import subprocess,json,time
from pathlib import Path
c=json.loads(next(Path('/var/lib/twebproxy-bridge').glob('*/config.json')).read_text());prefix='twb-'+c['id'][:12]
def state():return {s:subprocess.run(['systemctl','is-active',prefix+'-'+s+'.service'],capture_output=True,text=True).stdout.strip() for s in ['guard','wg','mt']}
before=state();start=time.time();p=subprocess.run(['systemctl','restart',prefix+'-wg.service'],capture_output=True,text=True);obs=[]
for _ in range(8):
 obs.append({'elapsed':time.time()-start,'units':state()})
 if all(x=='active' for x in obs[-1]['units'].values()):break
 time.sleep(2)
print(json.dumps({'test':'foreign WG service restart propagates backend recovery','at':start,'command':['systemctl','restart',prefix+'-wg.service'],'rc':p.returncode,'before':before,'observations':obs,'status':'PASS' if all(v=='active' for v in obs[-1]['units'].values()) else 'FAIL'},indent=2))
