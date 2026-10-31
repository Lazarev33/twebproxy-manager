import json,time,subprocess
from pathlib import Path
s=json.loads(Path('/etc/twebproxy/bridge/node.json').read_text());p='twb-'+s['id'][:12];dev='twb'+s['id'][:8]
t=time.time();subprocess.run(['ip','link','set',dev,'down'],check=True);observations=[]
for i in range(18):
 r={k:subprocess.run(['systemctl','is-active',p+'-forward.'+k],text=True,capture_output=True).stdout.strip() for k in ['socket','service']};r['elapsed']=time.time()-t;observations.append(r)
 if all(r[k]=='inactive' for k in ['socket','service']):break
 time.sleep(3)
print(json.dumps({'test':'real tunnel interruption','started':t,'observations':observations,'bounded_stop':all(observations[-1][k]=='inactive' for k in ['socket','service'])},indent=2))
