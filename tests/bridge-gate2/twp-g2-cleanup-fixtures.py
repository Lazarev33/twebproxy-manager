import json,subprocess,shutil,time
from pathlib import Path
r={'at':time.time(),'removed':[]}
subprocess.run(['systemctl','stop','twb-gate2-test-https.service'],capture_output=True)
u=Path('/run/systemd/system/twb-gate2-test-https.service');u.unlink(missing_ok=True)
for p in [Path('/root/twp-gate2-test-private')]:
 if p.exists():shutil.rmtree(p);r['removed'].append(str(p))
for n in ['twb-bootstrap-exit','twb-bootstrap-exit.pub']:
 p=Path('/root/.ssh')/n;p.unlink(missing_ok=True);r['removed'].append(str(p))
subprocess.run(['systemctl','daemon-reload'],check=True)
subprocess.run(['systemctl','reset-failed','twb-*'],capture_output=True)
r['owned_keys']=[str(p) for p in Path('/etc/wireguard').glob('twb-*.key')]
r['node_exists']=Path('/etc/twebproxy/bridge/node.json').exists()
for name,cmd in {'services':['systemctl','is-active','ssh','zabbix-agent'],'listeners':['ss','-lntu'],'nft':['nft','list','tables'],'owned_units':['systemctl','list-units','--state=active,activating','twb-*','--no-pager']}.items():
 p=subprocess.run(cmd,text=True,capture_output=True);r[name]={'rc':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
r['core_paths_absent']=not Path('/etc/twebproxy').exists();r['proc_options']=subprocess.check_output(['findmnt','-n','-o','OPTIONS','/proc'],text=True).strip();r['retained']='Manager candidate, verified dependency cache, apt packages, accepted host proc policy and monitoring exemption; logs/dev source preserved'
print(json.dumps(r,indent=2))
