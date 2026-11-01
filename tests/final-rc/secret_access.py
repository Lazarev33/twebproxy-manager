#!/usr/bin/env python3
"""Copy/run on disposable Exit only. Observes real unprivileged read denial."""
import json,subprocess
from pathlib import Path
assert Path('/etc/twebproxy-disposable-lab').read_bytes()==Path('/etc/machine-id').read_bytes()
c=json.loads(next(Path('/var/lib/twebproxy-bridge').glob('*/config.json')).read_text())
u='twb-'+c['id'][:12]+'-mt.service'
pid=subprocess.check_output(['systemctl','show',u,'-p','MainPID','--value'],text=True).strip();assert int(pid)>0
observations=[]
for path in ['/proc/'+pid+'/cmdline',str(Path('/var/lib/twebproxy-bridge')/c['id']/'client-secret')]:
 assert Path(path).exists()
 r=subprocess.run(['runuser','-u','nobody','--','test','-r',path])
 observations.append({'target':'MTProxy proc cmdline' if path.startswith('/proc') else 'client-secret file','unprivileged_read_test_rc':r.returncode})
 assert r.returncode==1
print(json.dumps({'status':'PASS','observations':observations,'unit':u,'pid':pid}))
