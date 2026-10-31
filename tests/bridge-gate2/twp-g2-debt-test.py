import subprocess,json,time
from pathlib import Path
root=next(p for p in Path('/var/lib/twebproxy-bridge').iterdir() if p.is_dir());c=json.loads((root/'config.json').read_text());key=Path('/etc/ssh/twebproxy-bridge')/c['id'];backup=Path('/root')/('twb-debt-fixture-'+c['id']);key.rename(backup)
cmd=['ssh','-F','/root/.ssh/twp-g2-lab-config','g2-entry','/root/twebproxy-gate2-dev/twebproxy-manager.sh foreign-node remove --approve']
try:
 p=subprocess.run(cmd,text=True,capture_output=True,timeout=80)
 raw=subprocess.check_output(['ssh','-F','/root/.ssh/twp-g2-lab-config','g2-entry','cat /etc/twebproxy/bridge/node.json'],text=True);s=json.loads(raw)
 r={'at':time.time(),'command':cmd,'rc':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'phase':s['phase'],'cleanup_debt':s.get('cleanup_debt'),'management_identity_retained':subprocess.run(['ssh','-F','/root/.ssh/twp-g2-lab-config','g2-entry','test -f /etc/twebproxy/bridge/credentials/management-key']).returncode==0,'foreign_state_retained':root.exists(),'pass':p.returncode!=0 and s['phase']=='cleanup_pending' and root.exists()}
 print(json.dumps(r,indent=2))
finally:
 if backup.exists():backup.rename(key)
