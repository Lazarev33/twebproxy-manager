import subprocess,json,time
from pathlib import Path
s=json.loads(Path('/etc/twebproxy/bridge/node.json').read_text());prefix='twb-'+s['id'][:12];dev='twb'+s['id'][:8];events=[];start=time.time()
def sample(stage):
 d={'at':time.time(),'elapsed':time.time()-start,'stage':stage}
 for kind in ['socket','service']:d[kind]=subprocess.run(['systemctl','is-active',prefix+'-forward.'+kind],text=True,capture_output=True).stdout.strip()
 events.append(d);return d
sample('before');subprocess.run(['ip','link','set',dev,'down'],check=True);down=False;recovered=False
try:
 for _ in range(23):
  r=sample('down')
  if r['socket']=='inactive' and r['service']=='inactive':down=True;break
  time.sleep(2)
finally:subprocess.run(['ip','link','set',dev,'up'],check=True);restored=time.time()
for _ in range(20):
 r=sample('network-restored')
 if r['socket']=='active':recovered=True;break
 time.sleep(2)
print(json.dumps({'test':'public Bridge real link outage; restoration without Manager repair','start':start,'network_restored':restored,'watcher_stopped_forwarder':down,'automatic_recovery':recovered,'observations':events,'status':'PASS' if down and recovered else 'FAIL'},indent=2))
